import Foundation
import NetworkExtension

/// Leitmotif Name: your phone's own chatter, sung as a solo line over the Aether + Bellweathered duo.
/// The personal edition: it hears the names your phone looks up, through an on-device DNS tunnel.
///
/// Two senses, like reading a house from the street:
///  • the address book: every name the phone looks up (who it's talking to), heard by the
///    LeitmotifNameTunnel extension, becomes a leitmotif, so each service always sounds like itself;
///  • the water meter: total bytes flowing in and out (how hard it's talking), which sets
///    how hard and bright the piano is played, and how much tape dust rides along.
///
/// The duo leads; Leitmotif follows. It takes key and scale from Bellweathered (or Aether),
/// tempo and the current chord from Aether. Inside Ambit they share one process, so it stays
/// in step with them in the background too; it still remembers what it last heard if a lead
/// ever goes quiet.
@MainActor
final class LeitmotifModel: ObservableObject {
    // What the screen shows
    @Published private(set) var lookups: [Lookup] = []           // newest first
    @Published private(set) var isPlaying = false
    @Published private(set) var status = "Tap Listen to begin"
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var meterWorks = false
    @Published private(set) var perMinute = 0
    @Published private(set) var voice: Double = 0              // the soloist's loudness, 0…1
    @Published private(set) var whisper: Double = 0
    @Published private(set) var harmonyLine = ""
    @Published private(set) var partnerName: String?

    // Settings (persisted)
    @Published var followDuo: Bool { didSet { save("followDuo", followDuo) } }
    @Published var rootPC: Int { didSet { save("rootPC", rootPC) } }
    @Published var scaleIndex: Int { didSet { save("scaleIndex", scaleIndex) } }
    @Published var bpm: Double { didSet { save("bpm", bpm) } }
    @Published var octave: Int { didSet { save("octave", octave) } }
    @Published var whisperTrackers: Bool { didSet { save("whisperTrackers", whisperTrackers) } }
    @Published var showNames: Bool { didSet { save("showNames", showNames) } }
    @Published var upstream: WireUpstream { didSet { upstreamChanged(oldValue) } }

    let tunnel = Tunnel()
    let duo = DuoLink(role: "leitmotif")
    private let engine: MotifEngine
    private var meter = Meter()
    private var timer: Timer?
    private var tickCount = 0
    private var lastTunnelStatus: NEVPNStatus = .invalid

    // The score
    private var pending: [Lookup] = []          // motifs waiting for the soloist
    private var whispers: [Lookup] = []         // tracker blips waiting
    private var leadFree: Double = 0          // beat at which the soloist is next free
    private var lastSung: Double = -100
    private var nextHum: Double = 0
    private var lastWhisper: Double = -100
    private var heardTimes: [Date] = []

    // What the duo last told us (kept after they go quiet)
    private struct Latch<T> { var value: T; var at: Date }
    private var bellKey: Latch<(Int, [Int])>?
    private var aetherKey: Latch<(Int, [Int])>?
    private var aetherBPM: Latch<Double>?
    private var aetherChord: Latch<Int>?

    init(audio: AmbitAudio) {
        engine = MotifEngine(host: audio)
        let d = UserDefaults.standard
        followDuo = d.object(forKey: "followDuo") as? Bool ?? true
        rootPC = d.object(forKey: "rootPC") as? Int ?? 2
        scaleIndex = d.object(forKey: "scaleIndex") as? Int ?? 0
        bpm = d.object(forKey: "bpm") as? Double ?? 72
        octave = d.object(forKey: "octave") as? Int ?? 0
        whisperTrackers = d.object(forKey: "whisperTrackers") as? Bool ?? true
        showNames = d.object(forKey: "showNames") as? Bool ?? true
        upstream = WireUpstream(rawValue: d.string(forKey: "upstream") ?? "") ?? .cloudflare

        tunnel.onEvents = { [weak self] events in MainActor.assumeIsolated { self?.ingest(events) } }
        duo.onState = { [weak self] s in MainActor.assumeIsolated { self?.receiveDuo(s) } }
        duo.onLost = { [weak self] in MainActor.assumeIsolated { self?.refreshHarmonyLine() } }
        duo.start()

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refreshHarmonyLine()
    }

    // MARK: Transport

    /// Listen = open the tunnel and start singing. Stop = both off, and the phone's DNS
    /// goes straight back to normal.
    func togglePlay() {
        if isPlaying {
            engine.stop()
            tunnel.stop()
            isPlaying = false
        } else {
            do {
                try engine.start()
                isPlaying = true
                leadFree = engine.params.nowBeat
                if !tunnel.isOn {
                    let u = upstream
                    Task { await tunnel.start(upstream: u) }
                }
            } catch {
                status = "Audio failed to start: \(error.localizedDescription)"
            }
        }
        updateStatus()
    }


    func clearLedger() { lookups.removeAll() }

    // MARK: The clock

    private func tick() {
        let p = engine.params
        p.publish()
        tickCount += 1
        let now = ProcessInfo.processInfo.systemUptime

        if tickCount % 8 == 0 { tunnel.poll() }
        if tickCount % 15 == 0 {
            meter.sample(now: now)
            down = meter.down
            up = meter.up
            meterWorks = meter.works
            let cutoff = Date().addingTimeInterval(-60)
            heardTimes.removeAll { $0 < cutoff }
            perMinute = heardTimes.count
            if tunnel.status != lastTunnelStatus {
                lastTunnelStatus = tunnel.status
                updateStatus()
            }
            if tickCount % 90 == 0 { refreshHarmonyLine() }
        }

        let level = meterWorks ? meter.downLevel : 0.35
        p[.bpm] = Float(effectiveBPM)
        p[.bright] = Float(level)
        p[.breath] = Float(meterWorks ? meter.upLevel : 0.2)
        p[.whisperGain] = whisperTrackers ? 1 : 0
        engine.setSpace(bpm: effectiveBPM, busy: min(1, Double(perMinute) / 120))

        if isPlaying { schedule(level: level) }

        if tickCount % 3 == 0 {
            voice = min(1, p.clock[1] * 1.6)
            whisper = min(1, p.clock[2] * 2)
        }
    }

    // MARK: Ingest

    private func ingest(_ events: [WireEvent]) {
        for e in events {
            var t = Score.lookup(e)
            heardTimes.append(t.time)
            switch t.kind {
            case .tracker:
                if whisperTrackers && isPlaying {
                    if whispers.count < 6 { whispers.append(t); t.fate = .whispered } else { t.fate = .dropped }
                } else {
                    t.fate = .dropped
                }
            case .app, .system:
                if !isPlaying {
                    t.fate = .dropped
                } else if pending.contains(where: { $0.domain == t.domain }) {
                    t.fate = .merged                 // already waiting to be sung
                } else {
                    pending.append(t)
                    if pending.count > 6 {
                        let gone = pending.removeFirst()
                        setFate(gone.id, .dropped)
                    }
                }
            }
            lookups.insert(t, at: 0)
        }
        if lookups.count > 120 { lookups.removeLast(lookups.count - 120) }
    }

    private func setFate(_ id: Int, _ fate: Lookup.Fate) {
        if let i = lookups.firstIndex(where: { $0.id == id }) { lookups[i].fate = fate }
    }

    // MARK: Scheduling onto the grid

    private func schedule(level: Double) {
        let p = engine.params
        let now = p.nowBeat
        if leadFree < now { leadFree = now }
        let velBase = 0.42 + 0.4 * level

        // The soloist: one motif at a time, starting on the next eighth.
        if leadFree - now < 1, !pending.isEmpty {
            let t = pending.removeFirst()
            let busy = pending.count >= 3              // a backlog: talk faster, say less
            let notes = busy ? Array(t.motif.prefix(2)).map { MotifNote(degree: $0.degree, eighths: 1) } : t.motif
            var b = max(leadFree, ((now + 0.35) * 2).rounded(.up) / 2)
            let kindGain = t.kind == .system ? 0.7 : 1.0
            for (i, n) in notes.enumerated() {
                let beats = Double(n.eighths) * 0.5
                let accent = i == 0 ? 1.0 : 0.85
                p.stageLead(beat: b, freq: pitch(n.degree, register: t.kind == .system ? -1 : 0),
                            vel: velBase * kindGain * accent, beats: beats, pan: t.pan)
                b += beats
            }
            leadFree = b + 0.5                           // a breath between phrases
            lastSung = b
            setFate(t.id, .sung)
        } else if pending.isEmpty, level > 0.4, now - lastSung > 8, now >= nextHum, leadFree - now < 1 {
            // Heavy traffic but nothing new to name (a stream, a download): hum the chord root.
            let b = max(leadFree, now.rounded(.up))
            p.stageLead(beat: b, freq: pitch(0, register: -1), vel: 0.25 + 0.2 * level, beats: 4, pan: 0)
            leadFree = b + 4
            nextHum = b + 8
        }

        // Whispers: tracker blips on the off-sixteenths, never more than two a beat.
        if !whispers.isEmpty, lastWhisper - now < 1.5 {
            let t = whispers.removeFirst()
            var b = max(lastWhisper + 0.5, ((now + 0.2) * 4).rounded(.up) / 4)
            if b.truncatingRemainder(dividingBy: 0.5) == 0 { b += 0.25 }
            var r = Score.Mix(Score.fnv(t.domain))
            p.stageWhisper(beat: b, freq: pitch(r.int(7), register: 2), vel: 0.5 + 0.4 * Double(r.int(3)) / 2, pan: t.pan)
            lastWhisper = b
        }
    }

    /// A scale degree above the current chord root, in a register (−1 low, 0 mid, 2 high).
    private func pitch(_ degree: Int, register: Int) -> Double {
        let steps = effectiveKey.steps
        let n = max(1, steps.count)
        let d = degree + effectiveChord
        let oct = Int((Double(d) / Double(n)).rounded(.down))
        let idx = ((d % n) + n) % n
        var midi = 60 + effectiveKey.root + 12 * (octave + register + oct) + steps[idx]
        while midi > 100 { midi -= 12 }
        while midi < 36 { midi += 12 }
        return 440 * pow(2, Double(midi - 69) / 12)
    }

    // MARK: Duo

    private func receiveDuo(_ s: DuoState) {
        let now = Date()
        partnerName = duo.partnerName
        if let pc = s.rootPC, let steps = s.scaleSteps, (0..<12).contains(pc), !steps.isEmpty {
            if s.role == "bellweather" { bellKey = Latch(value: (pc, steps), at: now) }
            if s.role == "aether" { aetherKey = Latch(value: (pc, steps), at: now) }
        }
        if s.role == "aether" {
            if let b = s.bpm, b > 20 { aetherBPM = Latch(value: b, at: now) }
            if let c = s.chordDegree { aetherChord = Latch(value: c, at: now) }
        }
        refreshHarmonyLine()
    }

    var manualSteps: [Int] { DuoScales.all[max(0, min(DuoScales.all.count - 1, scaleIndex))].steps }

    private var effectiveKey: (root: Int, steps: [Int]) {
        if followDuo, let k = bellKey ?? aetherKey { return (k.value.0, k.value.1) }
        return (rootPC, manualSteps)
    }

    var effectiveBPM: Double {
        if followDuo, let b = aetherBPM { return b.value }
        return bpm
    }

    /// Aether's chord, while it's fresh; once we've lost touch, home on the tonic.
    private var effectiveChord: Int {
        guard followDuo, let c = aetherChord, Date().timeIntervalSince(c.at) < 15 else { return 0 }
        return c.value
    }

    var followingTempo: Bool { followDuo && aetherBPM != nil }
    var followingKey: Bool { followDuo && (bellKey ?? aetherKey) != nil }

    private func refreshHarmonyLine() {
        partnerName = duo.partnerName
        let k = effectiveKey
        let scale = DuoScales.all.first(where: { $0.steps == k.steps })?.name ?? "\(k.steps.count)-note scale"
        var line = "\(pitchNames[k.root]) \(scale.lowercased()) · \(Int(effectiveBPM.rounded())) BPM"
        if followDuo {
            if let b = bellKey ?? aetherKey {
                let who = bellKey != nil ? "Bellweathered" : "Aether"
                line += " · key from \(who) \(ago(b.at))"
            }
        }
        harmonyLine = line
    }

    private func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 15 { return "(live)" }
        if s < 90 { return "(\(Int(s)) s ago)" }
        if s < 5400 { return "(\(Int(s / 60)) min ago)" }
        return "(\(Int(s / 3600)) h ago)"
    }

    // MARK: Status and settings

    private func updateStatus() {
        switch tunnel.status {
        case .connected:
            status = isPlaying ? "Listening to your phone's lookups" : "Tunnel open, sound off"
        case .connecting, .reasserting:
            status = "Opening the tunnel…"
        case .disconnecting:
            status = "Closing the tunnel…"
        case .disconnected:
            status = isPlaying ? "Tunnel closed — tap Stop, then Listen" : "Tap Listen to begin"
        case .invalid:
            status = isPlaying ? "Allow the VPN prompt to let Leitmotif listen" : "Tap Listen to begin"
        @unknown default:
            status = ""
        }
        if let e = tunnel.lastError { status = "Tunnel: \(e)" }
    }

    private func upstreamChanged(_ old: WireUpstream) {
        UserDefaults.standard.set(upstream.rawValue, forKey: "upstream")
        guard upstream != old, tunnel.isOn else { return }
        let u = upstream
        Task { await tunnel.start(upstream: u) }
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        refreshHarmonyLine()
    }
}
