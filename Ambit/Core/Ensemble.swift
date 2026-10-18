import SwiftUI
import Combine

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
    /// Each instrument's synth render time as a share of the real-time budget, refreshed
    /// once a second while Settings is open.
    @Published private(set) var loads: [Double] = Layer.allCases.map { _ in 0 }

    /// Which instruments Play all brings in: the ones that were on when last switched.
    private var chosen: Set<Layer>
    private var bag: Set<AnyCancellable> = []
    private var lastPuckSave = Date.distantPast

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
    }

    private func updateIdle() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && anyPlaying
    }

    // MARK: Persistence

    private func save() {
        let d = UserDefaults.standard
        d.set(trims, forKey: "ambit.trims")
        d.set(keepAwake, forKey: "ambit.keepAwake")
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
