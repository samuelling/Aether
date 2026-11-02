import SwiftUI
import Combine
import CoreMotion

let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

extension Layer {
    var name: String {
        switch self {
        case .aether: return "Aether"
        case .bell: return "Bellweathered"
        case .motif: return "Leitmotif"
        case .orbit: return "Orbitakt"
        }
    }

    /// Periodic-table tile, matching the app icons.
    var symbol: String {
        switch self {
        case .aether: return "Ae"
        case .bell: return "Bw"
        case .motif: return "Lm"
        case .orbit: return "Ot"
        }
    }

    var number: Int {
        switch self {
        case .aether: return 119
        case .bell: return 120
        case .motif: return 121
        case .orbit: return 121
        }
    }

    var color: Color {
        switch self {
        case .aether: return Color(red: 0.47, green: 0.82, blue: 1.0)
        case .bell: return Color(red: 1.0, green: 0.74, blue: 0.47)
        case .motif: return Color(red: 1.0, green: 0.43, blue: 0.67)
        case .orbit: return Color(red: 0.55, green: 0.67, blue: 1.0)
        }
    }

    /// Where it sits on the mix pad, as a unit vector in screen coordinates (y down):
    /// space above, land below; the melody to the right, the radio room to the left.
    var direction: CGVector {
        switch self {
        case .orbit: return CGVector(dx: 0, dy: -1)
        case .motif: return CGVector(dx: 1, dy: 0)
        case .bell: return CGVector(dx: 0, dy: 1)
        case .aether: return CGVector(dx: -1, dy: 0)
        }
    }

    /// Its page slides in from the opposite edge, travelling toward the instrument.
    var entryEdge: Edge {
        switch self {
        case .orbit: return .bottom
        case .motif: return .leading
        case .bell: return .top
        case .aether: return .trailing
        }
    }

    /// The way back to the pad, for the page's back button.
    var backIcon: String {
        switch self {
        case .orbit: return "chevron.down"
        case .motif: return "chevron.left"
        case .bell: return "chevron.up"
        case .aether: return "chevron.right"
        }
    }
}

/// Tilt the phone to move the mix pad's puck, as if the pad were a tray with a marble on it.
///
/// Whatever angle the phone is held at when tilt is switched on (or "Set neutral" is pressed)
/// is the middle of the pad; tilting from there pushes the puck, a 30 degree lean reaching the
/// rim. The axes come from gravity alone, measured against that neutral pose, so it works the
/// same held upright, propped at an angle or lying flat, and turning the phone about the
/// vertical does nothing. Gravity-only device motion needs no permission.
@MainActor
final class TiltMixer {
    private let motion = CMMotionManager()
    private var neutral: (x: Double, y: Double, z: Double)?
    private var smoothed = CGPoint.zero
    private var last = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)   // forces the first reading out
    private(set) var running = false
    var onPuck: ((CGPoint) -> Void)?

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    /// A tilt this large (the sine of 30 degrees) reaches the rim of the pad.
    private let fullScale = 0.5
    /// Ignore the first couple of degrees, so a phone resting in the hand doesn't wander.
    private let deadZone = 0.06

    func start() {
        guard !running, motion.isDeviceMotionAvailable else { return }
        running = true
        neutral = nil
        smoothed = .zero
        last = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            MainActor.assumeIsolated { self?.handle(g.x, g.y, g.z) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
    }

    /// Take the way the phone is held right now as the middle of the pad.
    func setNeutral() {
        neutral = nil
        smoothed = .zero
        last = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    }

    private func handle(_ gx: Double, _ gy: Double, _ gz: Double) {
        let len = (gx * gx + gy * gy + gz * gz).squareRoot()
        guard len > 0.5 else { return }
        let g = (x: gx / len, y: gy / len, z: gz / len)
        if neutral == nil { neutral = g }
        guard let n = neutral else { return }

        // Two axes at right angles to the neutral gravity direction: u is the phone's own
        // left-right axis flattened against it (its short axis, if the phone is neutral on its
        // side), and w = n x u is the third, which is the phone's front-to-back lean.
        var ax = (x: 1.0, y: 0.0, z: 0.0)
        var d = n.x
        if abs(d) > 0.9 { ax = (x: 0.0, y: 1.0, z: 0.0); d = n.y }
        var u = (x: ax.x - d * n.x, y: ax.y - d * n.y, z: ax.z - d * n.z)
        let ul = (u.x * u.x + u.y * u.y + u.z * u.z).squareRoot()
        guard ul > 1e-6 else { return }
        u = (x: u.x / ul, y: u.y / ul, z: u.z / ul)
        let w = (x: n.y * u.z - n.z * u.y, y: n.z * u.x - n.x * u.z, z: n.x * u.y - n.y * u.x)

        // Gravity's lean along each axis: the right edge dropping pushes the puck right (toward
        // Leitmotif); the top edge tipping away pushes it up (toward Orbitakt).
        let rawX = (g.x * u.x + g.y * u.y + g.z * u.z) / fullScale
        let rawY = (g.x * w.x + g.y * w.y + g.z * w.z) / fullScale

        // Dead zone, then a light smoothing so it glides rather than jitters.
        var p = CGPoint(x: rawX, y: rawY)
        let r = (p.x * p.x + p.y * p.y).squareRoot()
        if r < deadZone {
            p = .zero
        } else {
            let k = (r - deadZone) / (1 - deadZone) / r
            p = CGPoint(x: p.x * k, y: p.y * k)
        }
        let a = 0.25
        smoothed = CGPoint(x: smoothed.x + (p.x - smoothed.x) * a, y: smoothed.y + (p.y - smoothed.y) * a)
        var q = smoothed
        let qr = (q.x * q.x + q.y * q.y).squareRoot()
        if qr > 1 { q = CGPoint(x: q.x / qr, y: q.y / qr) }

        if abs(q.x - last.x) > 0.003 || abs(q.y - last.y) > 0.003 {
            last = q
            onPuck?(q)
        }
    }
}

/// The four instruments in one process, one audio engine and one mix.
///
/// The models are the apps' own, unchanged in what they hear and how they play; they talk
/// to each other through the in-process `DuoLink` exactly as they do across phones, so
/// Bellweathered's sky leads the key and Aether's radio room leads time for everyone.
///
/// The mix: each instrument has a trim, and the pad's puck biases the four against each
/// other. In the middle all four are equal; pushed all the way toward one, only that one
/// plays; along the rim between two neighbours, it crossfades between just those two.
/// The total loudness stays the same everywhere on the pad (an equal-power law).
@MainActor
final class Ensemble: ObservableObject {
    let audio: AmbitAudio
    let field: FieldModel
    let sky: SkyModel
    let motif: LeitmotifModel
    let orbit: RhythmModel

    @Published private(set) var playing: [Bool] = Layer.allCases.map { _ in false }
    @Published private(set) var inBackground = false
    /// Per-instrument level, 0…1.
    @Published var trims: [Double] { didSet { applyGains(); save() } }
    /// The pad's puck, inside the unit disc, y down. (0, 0) is an even mix.
    @Published var puck: CGPoint { didSet { applyGains(); savePuck() } }
    @Published var keepAwake: Bool { didSet { save(); updateIdle() } }
    /// Tilt the phone to move the puck (off unless you switch it on).
    @Published var tiltMix: Bool { didSet { save(); updateTilt() } }
    /// Each instrument's synth render time as a share of the real-time budget, refreshed
    /// once a second while Settings is open.
    @Published private(set) var loads: [Double] = Layer.allCases.map { _ in 0 }

    /// Which instruments Play all brings in: the ones that were on when last switched.
    private var chosen: Set<Layer>
    private var bag: Set<AnyCancellable> = []
    private var lastPuckSave = Date.distantPast
    private let tilt = TiltMixer()

    var anyPlaying: Bool { playing.contains(true) }

    init() {
        let a = AmbitAudio()
        audio = a
        field = FieldModel(audio: a)
        sky = SkyModel(audio: a)
        motif = LeitmotifModel(audio: a)
        orbit = RhythmModel(audio: a)

        let d = UserDefaults.standard
        if let t = d.array(forKey: "ambit.trims") as? [Double], t.count == Layer.allCases.count {
            trims = t.map { max(0, min(1, $0)) }
        } else {
            trims = [0.85, 0.8, 0.9, 0.85]
        }
        puck = CGPoint(x: d.double(forKey: "ambit.puck.x"), y: d.double(forKey: "ambit.puck.y"))
        keepAwake = d.object(forKey: "ambit.keepAwake") as? Bool ?? false
        tiltMix = d.bool(forKey: "ambit.tilt")
        if let c = d.array(forKey: "ambit.chosen") as? [Int] {
            chosen = Set(c.compactMap(Layer.init(rawValue:)))
        } else {
            chosen = Set(Layer.allCases)
        }

        Publishers.CombineLatest4(field.$isPlaying, sky.$isPlaying, motif.$isPlaying, orbit.$isPlaying)
            .sink { [weak self] v in
                MainActor.assumeIsolated {
                    self?.playing = [v.0, v.1, v.2, v.3]
                    self?.updateIdle()
                }
            }
            .store(in: &bag)
        applyGains()
        tilt.onPuck = { [weak self] p in self?.puck = p }
        updateTilt()
    }

    /// Whether this phone has the motion sensors tilt needs (the Simulator doesn't).
    var tiltAvailable: Bool { tilt.isAvailable }

    /// Take the way the phone is held now as the middle of the pad.
    func setTiltNeutral() { tilt.setNeutral() }

    /// Tilt runs only while it's switched on and Ambit is in front.
    private func updateTilt() {
        if tiltMix && !inBackground { tilt.start() } else { tilt.stop() }
    }

    func isPlaying(_ l: Layer) -> Bool { playing[l.rawValue] }

    /// Bring one instrument in or out, and remember the choice for Play all.
    func setLayer(_ l: Layer, on: Bool) {
        if on != isPlaying(l) { togglePlay(l) }
        if on { chosen.insert(l) } else { chosen.remove(l) }
        save()
    }

    func playAll() {
        let set = chosen.isEmpty ? Set(Layer.allCases) : chosen
        for l in Layer.allCases where set.contains(l) && !isPlaying(l) { togglePlay(l) }
    }

    func stopAll() {
        for l in Layer.allCases where isPlaying(l) { togglePlay(l) }
    }

    private func togglePlay(_ l: Layer) {
        switch l {
        case .aether: field.togglePlay()
        case .bell: sky.togglePlay()
        case .motif: motif.togglePlay()
        case .orbit: orbit.togglePlay()
        }
    }

    // MARK: The mix

    /// The pad's bias for each instrument: 1 + (puck · its direction), so pushed all the way
    /// to one it's 2, the two beside it 1 and the one opposite 0. Partly normalized (by the
    /// square root of the largest), so the favourite swells about 3 dB as the others fall.
    /// The pad's bias for each instrument, 0…1.
    ///
    /// In the middle all four sit at half amplitude (a quarter of the power each). As the puck
    /// moves out, everyone's share of that even mix fades as (1 − r)², which is close to a
    /// steady number of decibels per step of travel: about −2.5 dB a quarter of the way out,
    /// −12 dB halfway, −24 dB at three quarters, and silence only at the rim. What it gives
    /// up goes to the instruments the puck points at, split by cos of the angle, so between
    /// two neighbours it crossfades between them. The four are then normalised to constant
    /// total power, so the overall loudness never changes as you move.
    var biases: [Double] {
        let x = Double(puck.x), y = Double(puck.y)
        let r = min(1, sqrt(x * x + y * y))
        let even = (1 - r) * (1 - r)
        let raw = Layer.allCases.map { l -> Double in
            let along = r > 1e-6 ? (x * Double(l.direction.dx) + y * Double(l.direction.dy)) / r : 0
            return 0.5 * even + max(0, along) * (1 - even)
        }
        let power = raw.reduce(0) { $0 + $1 * $1 }
        guard power > 1e-9 else { return raw }
        return raw.map { $0 / sqrt(power) }
    }

    /// What each instrument's bus is actually set to. Exactly zero parks the instrument.
    var gains: [Double] {
        zip(trims, biases).map { t, b in b < 1e-4 ? 0 : min(1, t * b) }
    }

    /// Read the audio thread's load meters (Settings polls this while it's open).
    func refreshLoads() {
        let l = audio.loads
        if l != loads { loads = l }
    }

    private func applyGains() {
        for (l, g) in zip(Layer.allCases, gains) { audio.setGain(g, for: l) }
    }

    // MARK: Life cycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            inBackground = true
            field.setHeld(true)
        case .active:
            inBackground = false
            field.setHeld(false)
        default:
            break
        }
        updateIdle()
        updateTilt()
    }

    private func updateIdle() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && anyPlaying
    }

    // MARK: Persistence

    private func save() {
        let d = UserDefaults.standard
        d.set(trims, forKey: "ambit.trims")
        d.set(keepAwake, forKey: "ambit.keepAwake")
        d.set(tiltMix, forKey: "ambit.tilt")
        d.set(chosen.map(\.rawValue), forKey: "ambit.chosen")
    }

    /// The puck moves at drag rate; write it down a few times a second at most.
    private func savePuck() {
        let now = Date()
        guard now.timeIntervalSince(lastPuckSave) > 0.3 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, Date().timeIntervalSince(self.lastPuckSave) > 0.3 else { return }
                self.writePuck()
            }
            return
        }
        writePuck()
    }

    private func writePuck() {
        lastPuckSave = Date()
        UserDefaults.standard.set(Double(puck.x), forKey: "ambit.puck.x")
        UserDefaults.standard.set(Double(puck.y), forKey: "ambit.puck.y")
    }
}
