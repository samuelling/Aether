import Foundation
import CoreLocation
import SwiftUI

enum MelodyVoice: String, CaseIterable, Identifiable {
    case glass = "Glass bell"
    case string = "String"
    case kalimba = "Kalimba"
    var id: String { rawValue }
    var code: Float { self == .glass ? 0 : (self == .string ? 1 : 2) }
    /// Relative loudness, as in the web version's VOICE_GAIN (kalimba retuned for this engine).
    var gain: Double { self == .glass ? 0.9 : (self == .string ? 4.5 : 1.2) }
}

struct Ripple {
    let x: Double         // 0…1 across the view
    let t: TimeInterval   // uptime when it began
    let snow: Bool
}

@inline(__always) private func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

/// Bellweathered's brain: reads the sky (live or simulated), works out the sun and moon,
/// maps everything onto the drone, wind, rain and melody, and talks to Aether.
@MainActor
final class SkyModel: NSObject, ObservableObject {
    // What the sky is doing
    @Published private(set) var weather = Weather()
    @Published private(set) var live = false
    @Published private(set) var place = "Watertown, MA"
    @Published private(set) var sunAlt = 0.0
    @Published private(set) var sunHA = 0.0
    @Published private(set) var moonAlt = 0.0
    @Published private(set) var moonHA = 0.0
    @Published private(set) var moonPhase = 0.0
    @Published private(set) var day = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var status = ""

    // Settings
    @Published var useLiveWeather = true { didSet { if useLiveWeather { fetchWeather() } } }
    @Published var scaleIndex = 0 { didSet { resetLoops() } }
    @Published var rootPC = 0 { didSet { rootChanged() } }      // drone root C2…B2
    @Published var octave = 0                                   // melody, −1…+2
    @Published var bpm: Double = 72
    @Published var voice: MelodyVoice = .glass
    @Published var melodyOn = true
    @Published var hourlyBell = true
    @Published var driftOn = true

    // Duo
    let duo = DuoLink(role: "bellweather")
    @Published private(set) var partnerName: String?
    @Published private(set) var partnerSummary: String?
    @Published var followTempo = true
    @Published var followChords = true
    private var partnerBPM: Double?
    private var partnerDevices: Int?
    private var lastPartnerChord = -1

    /// Visual events read by the sky view each frame (not published: the view redraws anyway).
    private(set) var ripples: [Ripple] = []
    private(set) var bellRingAt: TimeInterval = -100
    private(set) var gustNow = 0.0

    var effectiveBPM: Double { (followTempo ? partnerBPM : nil) ?? bpm }
    var steps: [Int] { DuoScales.all[max(0, min(DuoScales.all.count - 1, scaleIndex))].steps }
    var isSnow: Bool { weather.temp <= 32 }

    private let engine = BellEngine()
    private let locator = CLLocationManager()
    private var lat = 42.37083, lon = -71.18333
    private var timer: Timer?
    private var tickCount = 0
    private var sim = SimulatedSky()
    private var lastSim = Date()
    private var lastFetch = Date.distantPast
    private var fetching = false
    private var lastDuoSend: TimeInterval = 0
    private var asked = false

    // Drone pitch drift (the web version's slow portamento)
    private var droneDeg = 0
    private var glideFrom = 65.41, glideTarget = 65.41, glideStart: TimeInterval = 0, glideDur = 1.0
    private var nextDrift: TimeInterval = 0

    // Envelopes
    private var gustStart: TimeInterval = -100
    private var throbStart: TimeInterval = -100
    private var lastHour = -1

    // Airports-style loops: seven single notes on long, unequal periods
    private struct Loop { var period: Double; var home: Int; var deg: Int; var next: TimeInterval }
    private var loops: [Loop] = []
    private var voiceRR = 0
    private var pendingBell = false
    private var pendingTriggers: [Int] = []

    override init() {
        super.init()
        let now = ProcessInfo.processInfo.systemUptime
        glideFrom = rootHz; glideTarget = rootHz
        nextDrift = now + 25
        resetLoops()
        updateSky(Date())

        locator.delegate = self
        locator.desiredAccuracy = kCLLocationAccuracyKilometer
        if [.authorizedWhenInUse, .authorizedAlways].contains(locator.authorizationStatus) {
            locator.requestLocation()
        }
        fetchWeather()

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        duo.onState = { [weak self] s in MainActor.assumeIsolated { self?.receiveDuo(s) } }
        duo.onLost = { [weak self] in MainActor.assumeIsolated { self?.partnerLost() } }
        duo.start()
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            engine.stop()
            isPlaying = false
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            if !asked {
                asked = true
                if locator.authorizationStatus == .notDetermined { locator.requestWhenInUseAuthorization() }
            }
            do {
                try engine.start()
                resetLoops()
                isPlaying = true
                UIApplication.shared.isIdleTimerDisabled = true
            } catch {
                status = "Audio failed to start: \(error.localizedDescription)"
            }
        }
    }

    func strikeBell() {
        let p = engine.params
        p[.bellF] = Float(rootHz * 2)
        p[.bellDay] = Float(day)
        pendingBell = true                     // trigger next tick, after pitch has landed
        bellRingAt = ProcessInfo.processInfo.systemUptime
    }

    // MARK: Weather

    func fetchWeather() {
        guard useLiveWeather, !fetching else { return }
        fetching = true
        lastFetch = Date()
        let la = lat, lo = lon
        Task { [weak self] in
            do {
                let w = try await WeatherService.fetch(lat: la, lon: lo)
                self?.weather = w
                self?.live = true
            } catch {
                self?.live = false
            }
            self?.fetching = false
        }
    }

    // MARK: Control loop (30 Hz; heavier work at 5 Hz)

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let date = Date()
        let p = engine.params
        for v in pendingTriggers { p.nTrig[v] += 1 }
        pendingTriggers.removeAll(keepingCapacity: true)
        if pendingBell { pendingBell = false; p[.bellTrig] += 1 }
        tickCount += 1

        // Weather: live every 10 min; otherwise (or on failure) the simulated sky runs
        if useLiveWeather && date.timeIntervalSince(lastFetch) > 600 { fetchWeather() }
        let dtSim = date.timeIntervalSince(lastSim)
        if (!useLiveWeather || !live) && dtSim >= 0.5 {
            lastSim = date
            var w = weather
            sim.step(&w, dt: min(dtSim, 5), date: date, lat: lat, lon: lon)
            weather = w
        }

        if tickCount % 6 == 0 { slowTick(now: now, date: date) }

        // Drone glide
        let x = glideDur > 0 ? min(1, max(0, (now - glideStart) / glideDur)) : 1
        let hz = glideFrom * pow(glideTarget / glideFrom, 0.5 - 0.5 * cos(Double.pi * x))
        p[.droneHz] = Float(hz)

        // Gust envelope (0.7 s rise, 1.3 s fall) and wind band
        let ga = now - gustStart
        gustNow = ga < 0 ? 0 : (ga < 0.7 ? ga / 0.7 : exp(-(ga - 0.7) / 1.3))
        let w = weather
        let wf = w.wind / 50
        let drift = 300 * sin(0.07 * now + 1) * sin(0.031 * now + 2)
        p[.windBP] = Float(min(5000, max(120, 250 + 900 * wf + drift + 2200 * gustNow)))
        p[.windGust] = Float(gustNow)

        if isPlaying { scheduleMelody(now: now) }
        let cutoffT = now - 6
        if ripples.first.map({ $0.t < cutoffT }) == true { ripples.removeAll { $0.t < cutoffT } }

        if now - lastDuoSend > 2 { publishDuo(now: now) }
    }

    private func slowTick(now: TimeInterval, date: Date) {
        updateSky(date)
        let w = weather
        let p = engine.params
        let precip = w.precip / 100
        let snow = isSnow

        // Random one-shots
        if w.wind > 1 && Double.random(in: 0..<1) < (0.015 + 0.08 * w.wind / 50) * 0.2 { gustStart = now }
        let moon = min(1.4, (1 - cos(2 * .pi * moonPhase)) / 2)
        if Double.random(in: 0..<1) < (0.0015 + min(1, moon) * 0.012) * 0.2 { throbStart = now }
        let ta = now - throbStart
        let throbEnv = ta < 0 ? 0 : (ta < 20 ? smoothstep(ta / 20) : max(0, 1 - (ta - 20) / 35))
        let throb = throbEnv * min(1, moon) * 0.25

        // Drone colour
        p[.cutoff] = Float(min(7000, max(100, 1400 * lin(w.temp, -10, 105, 0.7, 1.35)
                                   * lin(w.cloud, 0, 100, 1.15, 0.72) * (0.85 + 0.3 * day))))
        p[.q] = Float(0.5 + lin(w.humidity, 0, 100, 0.03, 0.12) * 9)
        p[.flfoRate] = Float(lin(w.wind, 0, 50, 0.006, 0.05) * 0.6)
        p[.flfoDepth] = 400
        p[.swellMult] = Float(lin(w.wind, 0, 50, 0.6, 1.7))
        p[.spread] = Float(lin(w.pressure, 980, 1040, 1.7, 0.5))
        p[.timbreA] = 0.25
        p[.timbreB] = 0.35
        p[.lvl0] = Float((0.16 + (1 - day) * 0.12) * (1 + throb))
        p[.lvl1] = Float((0.30 + (1 - day) * 0.12) * (1 + throb))
        p[.lvl2] = 0.42
        p[.lvl3] = Float(0.10 + day * 0.30)
        p[.lvl4] = Float(0.03 + day * day * 0.20)
        p[.lvl5] = Float(0.05 + day * 0.08)

        // Air
        let wf = w.wind / 50
        p[.windGain] = Float((0.12 + 0.6 * wf) * wf * 0.8 * 0.9 + 0.03 * wf * 0.8)
        let amt = precip * 0.3 * 0.8
        p[.rainGain] = snow ? 0 : Float(amt * 0.4)
        p[.snowGain] = snow ? Float(amt * 0.7) : 0

        // Space
        engine.setReverb(gain: 0.5 * lin(w.cloud, 0, 100, 0.85, 1.25) * 1.1,
                         lowpass: lin(w.humidity, 0, 100, 9000, 3500))
        engine.setTempo(effectiveBPM)

        // Drift: wander the drone by scale degrees (unless following Aether's chords)
        let partnerLeads = followChords && partnerName != nil && lastPartnerChord >= 0
        if driftOn && !partnerLeads && now >= nextDrift {
            let n = steps.count
            let r = Double.random(in: 0..<1)
            let size = r < 0.55 ? 1 : (r < 0.87 ? 2 : n)
            let lim = n
            droneDeg = max(-lim, min(lim, droneDeg + (Bool.random() ? size : -size)))
            let rest = max(20, lin(w.humidity, 0, 100, 150, 60) * Double.random(in: 0.75...1.3))
            let glide = min(rest * 0.8, lin(w.humidity, 0, 100, 16, 42))
            glideTo(degree: droneDeg, seconds: glide, now: now)
            nextDrift = now + rest
        }

        // Hourly bell on the solar hour
        let hour = Int(Astro.solarHour(date, lon: lon))
        if lastHour >= 0 && hour != lastHour && hourlyBell && isPlaying { strikeBell() }
        lastHour = hour
    }

    private func updateSky(_ date: Date) {
        let s = Astro.sun(date, lat: lat, lon: lon)
        let m = Astro.moon(date, lat: lat, lon: lon)
        sunAlt = s.alt; sunHA = s.ha
        moonAlt = m.alt; moonHA = m.ha
        moonPhase = Astro.moonPhase(date)
        day = smoothstep((sunAlt + 8) / 36)
        status = (useLiveWeather && live) ? "Live · \(place)" : (useLiveWeather ? "Simulated sky (no connection)" : "Simulated sky")
    }

    // MARK: Pitch

    private var rootHz: Double { mtof(Double(36 + rootPC)) }

    private func semis(_ d: Int) -> Int {
        let n = steps.count
        let q = Int(floor(Double(d) / Double(n)))
        let r = d - q * n
        return steps[r] + 12 * q
    }

    private func glideTo(degree: Int, seconds: Double, now: TimeInterval) {
        let x = glideDur > 0 ? min(1, max(0, (now - glideStart) / glideDur)) : 1
        glideFrom = glideFrom * pow(glideTarget / glideFrom, 0.5 - 0.5 * cos(Double.pi * x))
        glideTarget = rootHz * pow(2, Double(semis(degree)) / 12)
        glideStart = now
        glideDur = max(0.5, seconds)
    }

    private func rootChanged() {
        glideTo(degree: droneDeg, seconds: 3, now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: Melody (Airports loops)

    private func resetLoops() {
        let n = steps.count
        let periods = [17.8, 20.1, 23.4, 26.6, 31.9, 36.3, 41.7]
        let homes = [-n + 2, 0, 2, min(4, n - 1), n, n + 1, n + 3]
        let now = ProcessInfo.processInfo.systemUptime
        loops = zip(periods, homes).map { per, home in
            let P = per * Double.random(in: 0.97...1.03)
            return Loop(period: P, home: home, deg: home, next: now + Double.random(in: 0.5...(0.6 * P)))
        }
    }

    private func scheduleMelody(now: TimeInterval) {
        let w = weather
        let precip = w.precip / 100
        var act = melodyOn ? max(precip, 0.12 * (0.4 + 0.6 * w.cloud / 100)) : 0
        // With Aether nearby, a crowded radio room livens the melody a little.
        if melodyOn, let d = partnerDevices { act = max(act, min(0.45, Double(d) / 50)) }
        let density = 0.85
        let n = steps.count
        for i in loops.indices where now >= loops[i].next {
            if act > 0 && Double.random(in: 0..<1) > (1 - act) * 0.3 {
                if Double.random(in: 0..<1) < 0.05 * 0.8 {
                    loops[i].deg = max(-n, min(2 * n, loops[i].deg + (Bool.random() ? 1 : -1)))
                } else if loops[i].deg != loops[i].home && Double.random(in: 0..<1) < 0.08 {
                    loops[i].deg += loops[i].home > loops[i].deg ? 1 : -1
                }
                play(degree: loops[i].deg, now: now, precip: precip)
            }
            loops[i].next += loops[i].period * lin(act, 0, 1, 1.25, 0.5) / min(2, max(0.2, density))
            if loops[i].next < now - 1 { loops[i].next = now + Double.random(in: 0.2...2) }
        }
    }

    private func play(degree: Int, now: TimeInterval, precip: Double) {
        let p = engine.params
        let snow = isSnow
        let v = voiceRR
        voiceRR = (voiceRR + 1) % BellParams.voices
        let f = rootHz * 4 * pow(2, Double(octave)) * pow(2, Double(semis(degree)) / 12)
        let pan = Double.random(in: -0.4...0.4)
        p.nType[v] = voice.code
        p.nFreq[v] = Float(f)
        p.nAmp[v] = Float(0.3 * lin(precip, 0, 1, 0.5, 1) * Double.random(in: 0.85...1.15) * voice.gain)
        p.nPan[v] = Float(pan)
        p.nDecay[v] = Float((snow ? 2.8 : 0.9) * 1.8)
        p.nAtk[v] = snow ? 0.09 : 0.002
        p.nCoef[v] = snow ? 0.22 : 0.1
        p.nBright[v] = Float(min(1, max(0.06, 0.6 * (snow ? 0.3 : 1))))
        pendingTriggers.append(v)
        ripples.append(Ripple(x: 0.5 + pan, t: now, snow: snow))
    }

    // MARK: Duo

    private func publishDuo(now: TimeInterval) {
        lastDuoSend = now
        var s = DuoState(role: "bellweather")
        s.rootPC = rootPC
        s.scaleSteps = steps
        s.day = day
        s.cloud = weather.cloud
        s.precip = weather.precip / 100
        s.wind = weather.wind
        s.tempF = weather.temp
        s.place = (useLiveWeather && live) ? place : "simulated sky"
        duo.send(s)
    }

    private func receiveDuo(_ s: DuoState) {
        guard s.role == "aether" else { return }
        partnerName = "Aether"
        partnerBPM = s.bpm
        partnerDevices = s.devices
        if let serial = s.chordSerial, let deg = s.chordDegree, serial != lastPartnerChord {
            lastPartnerChord = serial
            // A chord degree only means something in a shared key: follow only when Aether is in ours.
            let sameKey = s.rootPC == rootPC && s.scaleSteps == steps
            if followChords && sameKey {
                // Glide the drone to the new chord root, in the octave nearest where it is now.
                let n = steps.count
                var best = deg, dist = Int.max
                for k in -2...1 {
                    let c = deg + k * n
                    if abs(c - droneDeg) < dist { dist = abs(c - droneDeg); best = c }
                }
                droneDeg = best
                let chordLen = s.chordSeconds ?? 32
                glideTo(degree: droneDeg, seconds: min(0.6 * chordLen, lin(weather.humidity, 0, 100, 16, 42)),
                        now: ProcessInfo.processInfo.systemUptime)
            }
        }
        var bits: [String] = []
        if let d = s.devices { bits.append("\(d) devices") }
        if let b = s.bpm { bits.append("\(Int(b.rounded())) BPM") }
        if let a = s.air { bits.append("air \(Int((a * 100).rounded()))%") }
        partnerSummary = bits.isEmpty ? nil : bits.joined(separator: " · ")
        publishDuo(now: ProcessInfo.processInfo.systemUptime)
    }

    private func partnerLost() {
        partnerName = nil
        partnerSummary = nil
        partnerBPM = nil
        partnerDevices = nil
        lastPartnerChord = -1
    }
}

// MARK: - Location

extension SkyModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        MainActor.assumeIsolated {
            if st == .authorizedWhenInUse || st == .authorizedAlways { self.locator.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let la = (loc.coordinate.latitude * 100).rounded() / 100
        let lo = (loc.coordinate.longitude * 100).rounded() / 100
        MainActor.assumeIsolated {
            self.lat = la
            self.lon = lo
            self.lastFetch = .distantPast     // refetch here as soon as any in-flight request ends
            self.fetchWeather()
            Task { [weak self] in
                guard let marks = try? await CLGeocoder().reverseGeocodeLocation(loc),
                      let m = marks.first else { return }
                let name = [m.locality, m.administrativeArea].compactMap { $0 }.joined(separator: ", ")
                if !name.isEmpty { self?.place = name }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
