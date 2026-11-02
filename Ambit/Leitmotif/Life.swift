import UIKit
import AVFoundation
import CoreMotion
import Network

// MARK: - What the phone's life is made of

/// A thing that happened to the phone: the charger going in, headphones coming out, a walk
/// starting. Each kind has a fixed leitmotif, so it always sounds like itself; its opposite
/// (unplugging, taking the headphones off) is the same tune played backwards.
struct LifeEvent {
    let key: String             // seeds the motif: "power", "headphones", "walk"…
    let reversed: Bool          // the opposite event plays the motif backwards
    let title: String           // "Charger connected"
    let detail: String          // "battery 63%"
    var register = 0            // −1 low and soft … 0 middle
    var gain = 1.0
}

enum Activity: String {
    case still, handling, walking, running

    var label: String {
        switch self {
        case .still: return "resting"
        case .handling: return "in hand"
        case .walking: return "walking"
        case .running: return "running"
        }
    }
}

extension Score {
    /// A life event as an utterance: its motif comes from its key alone (so the charger always
    /// has the same tune), played backwards for the opposite event, panned by where it
    /// naturally sits.
    static func life(_ e: LifeEvent, id: Int, pan: Float) -> Utterance {
        var notes = motif("life " + e.key)
        if e.reversed {
            let degrees = notes.map(\.degree).reversed()
            notes = zip(notes, degrees).map { MotifNote(degree: $1, eighths: $0.eighths) }
        }
        var u = Utterance(id: id, time: Date(), word: e.title, kind: .life, motif: notes, pan: pan, detail: e.detail)
        u.register = e.register
        u.gain = e.gain
        return u
    }
}

// MARK: - The sensor

/// Listens to the phone's own life, all on the phone and with no permission prompts:
///  • motion: footsteps, whether it is resting, in the hand, walking or running, and how it
///    is held (Core Motion's device motion, gravity and acceleration only);
///  • power: battery level, the charger, low power mode, heat;
///  • connections: headphones and other audio routes, Wi-Fi, cellular or offline;
///  • the screen's brightness.
/// Nothing leaves the phone and none of it is recorded.
@MainActor
final class LifeSensor {
    var onEvent: ((LifeEvent) -> Void)?
    /// A footstep, with how hard (0…1).
    var onStep: ((Double) -> Void)?

    // The state, for the music and the screen
    private(set) var activity: Activity = .still
    private(set) var intensity = 0.0        // how much the phone is moving, 0…1
    private(set) var cadence = 0.0          // steps per second while walking or running
    private(set) var roll = 0.0             // tilt left (−1) to right (+1)
    private(set) var flat = false           // lying face up or down
    private(set) var battery = -1.0         // 0…1, −1 if unknown
    private(set) var charging = false
    private(set) var route = "speaker"
    private(set) var net = "other"
    private(set) var lowPower = false
    private(set) var thermal = 0            // 0 nominal … 3 critical
    private(set) var brightness = 0.5

    private var eventsOn = true
    private var movementOn = true
    private var running = false

    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var netPrimed = false
    private var lastEmit: [String: TimeInterval] = [:]
    private var lastAnyEmit: TimeInterval = 0
    private var lastBatteryBand = 3

    // Motion bookkeeping
    private var lastT: TimeInterval = 0
    private var meanSquare = 0.0
    private var peakEnvelope = 0.3
    private var aboveThreshold = false
    private var lastStepT: TimeInterval = -10
    private var stepTimes: [TimeInterval] = []
    private var stillFor = 0.0

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }

    // MARK: Life cycle

    func start(events: Bool, movement: Bool) {
        guard !running else { configure(events: events, movement: movement); return }
        running = true
        eventsOn = events
        movementOn = movement
        netPrimed = false
        readBaseline()
        watchPower()
        watchRoute()
        watchNetwork()
        if movementOn { startMotion() }
    }

    func configure(events: Bool, movement: Bool) {
        eventsOn = events
        if movement != movementOn {
            movementOn = movement
            if running {
                if movement { startMotion() } else { stopMotion() }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        stopMotion()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        activity = .still
        intensity = 0
        cadence = 0
    }

    /// Slow-changing things, read a couple of times a second.
    func poll() {
        guard running else { return }
        brightness = Double(UIScreen.main.brightness)
        let level = UIDevice.current.batteryLevel
        if level >= 0 { battery = Double(level) }
    }

    // MARK: Baseline (what's true when we start listening, which isn't an event)

    private func readBaseline() {
        let d = UIDevice.current
        d.isBatteryMonitoringEnabled = true
        battery = d.batteryLevel >= 0 ? Double(d.batteryLevel) : -1
        charging = d.batteryState == .charging || d.batteryState == .full
        lastBatteryBand = Self.band(battery)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        thermal = Self.heat(ProcessInfo.processInfo.thermalState)
        route = Self.routeKind(AVAudioSession.sharedInstance().currentRoute)
        brightness = Double(UIScreen.main.brightness)
    }

    // MARK: Power

    private func watchPower() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.batteryStateChanged() }
        })
        observers.append(nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.batteryLevelChanged() }
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerChanged() }
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        })
    }

    private func batteryText() -> String {
        battery >= 0 ? "battery \(Int((battery * 100).rounded()))%" : "battery level unknown"
    }

    private func batteryStateChanged() {
        let state = UIDevice.current.batteryState
        let nowCharging = state == .charging || state == .full
        let wasCharging = charging
        charging = nowCharging
        if nowCharging != wasCharging {
            emit(LifeEvent(key: "power", reversed: !nowCharging,
                           title: nowCharging ? "Charger connected" : "Charger unplugged", detail: batteryText()))
        }
        if state == .full {
            emit(LifeEvent(key: "full", reversed: false, title: "Battery full", detail: batteryText(), gain: 0.9))
        }
    }

    /// 0 full-ish … 3 low (under 20%) … 5 nearly dead (under 5%).
    private static func band(_ level: Double) -> Int {
        guard level >= 0 else { return 0 }
        if level < 0.05 { return 5 }
        if level < 0.10 { return 4 }
        if level < 0.20 { return 3 }
        return 0
    }

    private func batteryLevelChanged() {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return }
        battery = Double(level)
        let b = Self.band(battery)
        defer { lastBatteryBand = b }
        // Going down into a worse band: the phone is getting tired
        if b > lastBatteryBand && !charging {
            let title = b >= 5 ? "Battery nearly flat" : (b == 4 ? "Battery under 10%" : "Battery under 20%")
            emit(LifeEvent(key: "tired", reversed: false, title: title, detail: batteryText(), register: -1, gain: 0.85))
        }
    }

    private func lowPowerChanged() {
        let on = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard on != lowPower else { return }
        lowPower = on
        emit(LifeEvent(key: "lowpower", reversed: !on, title: on ? "Low Power Mode on" : "Low Power Mode off",
                       detail: batteryText(), register: -1, gain: 0.8))
    }

    private static func heat(_ s: ProcessInfo.ThermalState) -> Int {
        switch s {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private func thermalChanged() {
        let h = Self.heat(ProcessInfo.processInfo.thermalState)
        let was = thermal
        thermal = h
        if h >= 2 && was < 2 {
            emit(LifeEvent(key: "hot", reversed: false, title: "Phone running hot", detail: "thermal state \(h >= 3 ? "critical" : "serious")", register: -1, gain: 0.9))
        } else if h < 2 && was >= 2 {
            emit(LifeEvent(key: "hot", reversed: true, title: "Phone cooled down", detail: "thermal state back to normal", gain: 0.8))
        }
    }

    // MARK: Headphones and audio routes

    private func watchRoute() {
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        })
    }

    private static func routeKind(_ r: AVAudioSessionRouteDescription) -> String {
        guard let port = r.outputs.first?.portType else { return "speaker" }
        switch port {
        case .headphones, .usbAudio, .lineOut: return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "bluetooth"
        case .airPlay: return "airplay"
        case .carAudio: return "car"
        case .HDMI: return "hdmi"
        default: return "speaker"       // the built-in speaker or receiver
        }
    }

    private func routeChanged() {
        let kind = Self.routeKind(AVAudioSession.sharedInstance().currentRoute)
        guard kind != route else { return }
        let old = route
        route = kind
        let names = ["headphones": "Headphones", "bluetooth": "Bluetooth audio", "airplay": "AirPlay",
                     "car": "Car audio", "hdmi": "HDMI"]
        if kind == "speaker" {
            emit(LifeEvent(key: old, reversed: true, title: "\(names[old] ?? "Audio") disconnected", detail: "back to the phone's speaker"))
        } else {
            emit(LifeEvent(key: kind, reversed: false, title: "\(names[kind] ?? "Audio") connected", detail: "audio now goes there"))
        }
    }

    // MARK: Wi-Fi, cellular, offline

    private func watchNetwork() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let kind: String
            if path.status != .satisfied { kind = "offline" }
            else if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cell" }
            else { kind = "other" }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.netChanged(kind) } }
        }
        m.start(queue: DispatchQueue(label: "ambit.life.net"))
        pathMonitor = m
    }

    private func netChanged(_ kind: String) {
        guard running else { return }
        let old = net
        net = kind
        guard netPrimed else { netPrimed = true; return }       // the first report is the starting point
        guard kind != old else { return }
        switch kind {
        case "wifi": emit(LifeEvent(key: "wifi", reversed: false, title: "Joined Wi-Fi", detail: old == "offline" ? "back online" : "off cellular"))
        case "cell": emit(LifeEvent(key: "cell", reversed: false, title: "On cellular", detail: old == "offline" ? "back online" : "left Wi-Fi"))
        case "offline": emit(LifeEvent(key: "offline", reversed: false, title: "Went offline", detail: "no connection", register: -1, gain: 0.85))
        default: break
        }
    }

    // MARK: Events

    /// One event at a time, and the same kind not twice within a few seconds.
    private func emit(_ e: LifeEvent) {
        guard running, eventsOn || e.key == "walk" || e.key == "run" || e.key == "pickup" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastAnyEmit < 1.2 { return }
        if let t = lastEmit[e.key], now - t < 6 { return }
        lastEmit[e.key] = now
        lastAnyEmit = now
        onEvent?(e)
    }

    // MARK: Motion

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        lastT = 0
        meanSquare = 0
        stepTimes.removeAll()
        stillFor = 0
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let m else { return }
            let a = m.userAcceleration, g = m.gravity, t = m.timestamp
            MainActor.assumeIsolated { self?.motionSample(a.x, a.y, a.z, g.x, g.z, t) }
        }
    }

    private func stopMotion() {
        motion.stopDeviceMotionUpdates()
    }

    private func motionSample(_ ax: Double, _ ay: Double, _ az: Double, _ gx: Double, _ gz: Double, _ t: TimeInterval) {
        guard running, movementOn else { return }
        defer { lastT = t }
        guard lastT > 0 else { return }
        let dt = max(0.005, min(0.2, t - lastT))
        let mag = (ax * ax + ay * ay + az * az).squareRoot()      // in g, gravity already removed

        // How much it's moving: a smoothed RMS over about a second
        meanSquare += (mag * mag - meanSquare) * (1 - exp(-dt / 1.0))
        let rms = meanSquare.squareRoot()
        intensity += (min(1, rms / 0.5) - intensity) * (1 - exp(-dt / 0.6))

        // How it's held
        roll = max(-1, min(1, gx * 1.2))
        flat = abs(gz) > 0.92

        // Footsteps: peaks in the acceleration, above a threshold that follows the recent peaks
        peakEnvelope = max(mag, peakEnvelope * exp(-dt / 4.0))
        let threshold = max(0.10, 0.45 * peakEnvelope)
        var stepped = false
        if !aboveThreshold && mag > threshold && t - lastStepT > 0.25 {
            aboveThreshold = true
            lastStepT = t
            stepTimes.append(t)
            stepTimes.removeAll { t - $0 > 4.0 }
            stepped = true
        } else if aboveThreshold && mag < threshold * 0.6 {
            aboveThreshold = false
        }

        // A walk is four or more steps in the last few seconds, evenly spaced
        var regular = false
        if stepTimes.count >= 4 {
            let gaps = zip(stepTimes.dropFirst(), stepTimes).map { $0 - $1 }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let spread = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
            if mean > 0.25 && mean < 0.85 && spread < 0.18 {
                regular = true
                cadence = 1 / mean
            }
        }
        let walkingNow = regular && t - lastStepT < 1.8

        var next = activity
        if walkingNow {
            next = (cadence > 2.6 || rms > 0.45) ? .running : .walking
        } else if activity == .walking || activity == .running {
            next = rms > 0.05 ? .handling : .still
            cadence = 0
        } else if rms > 0.05 {
            next = .handling
            stillFor = 0
        } else if rms < 0.015 {
            stillFor += dt
            if stillFor > 2.5 { next = .still }
        } else {
            stillFor = 0
        }
        if next != activity { transition(from: activity, to: next) }

        if stepped && (activity == .walking || activity == .running) {
            onStep?(min(1, mag / 0.8))
        }
    }

    private func transition(from old: Activity, to new: Activity) {
        activity = new
        switch (old, new) {
        case (.still, .handling):
            emit(LifeEvent(key: "pickup", reversed: false, title: "Picked up", detail: "the phone started moving", gain: 0.85))
        case (.handling, .still):
            emit(LifeEvent(key: "pickup", reversed: true, title: "Set down", detail: "the phone came to rest", gain: 0.8))
        case (.walking, .running):
            break
        case (.running, .walking):
            break
        case (_, .walking):
            emit(LifeEvent(key: "walk", reversed: false, title: "Started walking", detail: String(format: "%.0f steps a minute", cadence * 60)))
        case (_, .running):
            emit(LifeEvent(key: "run", reversed: false, title: "Started running", detail: String(format: "%.0f steps a minute", cadence * 60)))
        case (.walking, _):
            emit(LifeEvent(key: "walk", reversed: true, title: "Stopped walking", detail: "the phone settled"))
        case (.running, _):
            emit(LifeEvent(key: "run", reversed: true, title: "Stopped running", detail: "the phone settled"))
        default:
            break
        }
    }

    // MARK: For the screen

    /// A one-line reading of the phone right now.
    var summary: String {
        var parts = [activity.label]
        if activity == .walking || activity == .running { parts[0] += String(format: " · %.0f steps/min", cadence * 60) }
        if battery >= 0 { parts.append("battery \(Int((battery * 100).rounded()))%" + (charging ? " ⚡" : "")) }
        switch route {
        case "headphones": parts.append("headphones")
        case "bluetooth": parts.append("Bluetooth audio")
        case "airplay": parts.append("AirPlay")
        case "car": parts.append("car audio")
        default: break
        }
        switch net {
        case "wifi": parts.append("Wi-Fi")
        case "cell": parts.append("cellular")
        case "offline": parts.append("offline")
        default: break
        }
        if lowPower { parts.append("low power") }
        if thermal >= 2 { parts.append("hot") }
        return parts.joined(separator: " · ")
    }
}
