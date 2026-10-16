import Foundation
import CoreBluetooth
import SwiftUI

// MARK: - A single radio emitter heard over Bluetooth LE

struct RadioSource: Identifiable {
    let id: UUID
    let seed: UInt32          // stable hash → phrase, loop length, bearing, pan
    var name: String?
    var vendor: String?
    var raw: Double           // last RSSI (dBm)
    var fast: Double          // quick EMA of RSSI
    var slow: Double          // slow EMA of RSSI (the "mean field")
    var jitter: Double        // EMA of |raw − slow| in dB (how disturbed this path is)
    var lastFast: Double
    var lastSeen: TimeInterval
    var firstSeen: TimeInterval
    var samples = 1
    var level: Double = 0     // 0…1 perceived strength (smoothed for sound + radar)
    var voice: Int? = nil
    var midi: Int = 60        // first note of its phrase (for color / display)
    var lastNote: TimeInterval = -100
    var lastSign = 0          // side of its mean it was last on (for fluctuation rate)
    var levelRef: Double = 0  // ~0.6 s baseline of level, for detecting a sudden approach
    var lastPluck: TimeInterval = -100
    var pulled: Double = -1   // loop offset of a note pulled forward by an approach

    var label: String {
        if let name, !name.isEmpty { return name }
        if let vendor { return "\(vendor) device" }
        return "Unknown emitter"
    }
    var jitterNorm: Double { min(1, jitter / 6) }
}

// MARK: - Musical scales and their slow chord cycles

enum DroneScale: String, CaseIterable, Identifiable {
    case pentatonic = "Major pentatonic"
    case minorPentatonic = "Minor pentatonic"
    case major = "Major (Ionian)"
    case lydian = "Lydian"
    case mixolydian = "Mixolydian"
    case dorian = "Dorian"
    case aeolian = "Natural minor (Aeolian)"
    case phrygian = "Phrygian"
    case wholeTone = "Whole tone"
    case hirajoshi = "Hirajoshi"
    case insen = "In-sen"
    case open = "Open (sus2)"

    var id: String { rawValue }
    var steps: [Int] {
        switch self {
        case .pentatonic:      return [0, 2, 4, 7, 9]
        case .minorPentatonic: return [0, 3, 5, 7, 10]
        case .major:           return [0, 2, 4, 5, 7, 9, 11]
        case .lydian:          return [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian:      return [0, 2, 4, 5, 7, 9, 10]
        case .dorian:          return [0, 2, 3, 5, 7, 9, 10]
        case .aeolian:         return [0, 2, 3, 5, 7, 8, 10]
        case .phrygian:        return [0, 1, 3, 5, 7, 8, 10]
        case .wholeTone:       return [0, 2, 4, 6, 8, 10]
        case .hirajoshi:       return [0, 2, 3, 7, 8]
        case .insen:           return [0, 1, 5, 7, 10]
        case .open:            return [0, 2, 7]
        }
    }
    /// Chord roots, as scale degrees, that the pad bed (and the arpeggio) drift through.
    var progression: [Int] {
        switch self {
        case .pentatonic:      return [0, 4, 1, 3]   // I6 · vi · IIsus · V
        case .minorPentatonic: return [0, 2, 4, 1]   // i · iv · ♭VII · ♭III
        case .major:           return [0, 5, 3, 4]   // I · vi · IV · V
        case .lydian:          return [0, 1, 5, 1]   // I · II · vi · II
        case .mixolydian:      return [0, 6, 3, 0]   // I · ♭VII · IV · I
        case .dorian:          return [0, 3, 6, 3]   // i · IV · ♭VII · IV
        case .aeolian:         return [0, 5, 2, 6]   // i · ♭VI · ♭III · ♭VII
        case .phrygian:        return [0, 1, 0, 6]   // i · ♭II · i · ♭vii
        case .wholeTone:       return [0, 1, 0, 2]
        case .hirajoshi:       return [0, 3, 1, 4]
        case .insen:           return [0, 2, 3, 1]
        case .open:            return [0, 1, 2, 1]
        }
    }
    /// MIDI note for a scale-degree index (indices past the scale wrap into higher octaves).
    func midi(base: Int, degree: Int) -> Int {
        let n = steps.count
        let d = max(0, degree)
        return base + 12 * (d / n) + steps[d % n]
    }
}

let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

@inline(__always) func mtof(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

/// A device's tape loop: a short melodic phrase repeating on its own period.
/// Like Eno's Music for Airports, the periods don't divide into each other, so
/// the phrases drift in and out of alignment and the melody never repeats.
struct Phrase {
    var degrees: [Int]
    var offsets: [Double]   // seconds into the loop
    var durations: [Double]
    var period: Double
    var phase: Double       // 0…1, where this loop sits on the shared clock

    init(seed: UInt32, scaleSize: Int) {
        var x = seed | 1
        func next() -> UInt32 { x = x &* 1_664_525 &+ 1_013_904_223; return x >> 8 }
        func unit() -> Double { Double(next() % 10_000) / 10_000 }

        let length = 1 + Int(next() % 3)                  // 1–3 notes
        let span = max(1, scaleSize * 2)
        var d = Int(next() % UInt32(span))
        let moves = [-2, -1, 1, 2, 3]                      // mostly stepwise: sings, doesn't leap
        var degs = [d]
        while degs.count < length {
            d = max(0, min(span + 1, d + moves[Int(next() % 5)]))
            degs.append(d)
        }
        let per = 14 + 16 * unit()                         // 14–30 s
        let gap = per / Double(length)
        var offs: [Double] = []
        var durs: [Double] = []
        for k in 0..<length {
            offs.append(Double(k) * gap + 1.2 * unit())
            durs.append(2.5 + 3.5 * unit())
        }
        degrees = degs
        offsets = offs
        durations = durs
        period = per
        phase = unit()
    }
}

// MARK: - The field: scanner + mapping from radio to music

@MainActor
final class FieldModel: NSObject, ObservableObject {
    @Published private(set) var sources: [RadioSource] = []
    @Published private(set) var status: String = "Waking the radio…"
    @Published private(set) var isPlaying = false
    @Published private(set) var air: Double = 0
    @Published private(set) var voicedCount = 0
    @Published private(set) var chordName = ""
    /// Arpeggio tempo: the field's average fluctuation rate, folded by octaves into 44–104.
    @Published private(set) var bpm: Double = 66

    @Published var scale: DroneScale = .pentatonic
    @Published var rootNote: Int = 2            // pitch class, D
    @Published var octave: Int = 0              // transpose, −2…+2 octaves
    @Published var arpOn = false                // stochastic piano arpeggio
    @Published var voiceLimit: Int = 10
    @Published var floorDBm: Double = -95       // weakest signal that still sings
    @Published var chordSeconds: Double = 32
    /// 1 = slow drift (default); toward 0.03 = snap, the sound follows your hands.
    @Published var response: Double = 1.0

    /// Rough end-to-end lag from a change in the field to a change in the sound.
    var approxLagSeconds: Double { 0.12 + 1.9 * response }
    nonisolated static let snapResponse = 0.03

    let ceilingDBm = -35.0

    private var central: CBCentralManager!
    private var store: [UUID: RadioSource] = [:]
    private var owners: [UUID?] = Array(repeating: nil, count: DroneParams.voiceCount)
    private var loopPos: [Double] = Array(repeating: -1, count: DroneParams.voiceCount)
    /// Which device each pooled note voice last played for, and when (for LRU reuse).
    private var poolOwner: [UUID?] = Array(repeating: nil, count: DroneParams.noteVoices)
    private var poolLastTrig: [Double] = Array(repeating: -1e9, count: DroneParams.noteVoices)
    /// Note-ons are written one tick, then released the next, so the audio thread never
    /// sees a trigger before the note's pitch and level have landed.
    private var pendingTriggers: [Int] = []
    private let engine = DroneEngine()
    private var timer: Timer?
    private var fluxFast = 0.0
    private var crossings = 0                   // mean-crossings since the last tick
    private var fluctRate = 1.1                 // per-device crossings per second (~20 s average)
    private var fluxSlow = 0.3

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
        // .common mode so the field keeps updating while the user scrolls
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying {
            engine.stop()
            isPlaying = false
        } else {
            do {
                try engine.start()
                isPlaying = true
            } catch {
                status = "Audio failed to start: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Ingest

    fileprivate func handleState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            status = "Listening on 2.4 GHz"
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .poweredOff:   status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth permission denied — Settings › Aether"
        case .unsupported:  status = "Bluetooth LE unsupported on this device"
        case .resetting:    status = "Radio resetting…"
        default:            status = "Waking the radio…"
        }
    }

    fileprivate func ingest(id: UUID, name: String?, company: UInt16?, rssi: Double) {
        guard rssi < 0, rssi > -127 else { return }   // 127 = "not available"
        let now = ProcessInfo.processInfo.systemUptime
        if var s = store[id] {
            s.raw = rssi
            s.fast += (rssi - s.fast) * alpha(1.7)
            // The mean and jitter are measurements, not expression: fixed time constants,
            // or a fast Response would make jitter (wow) and the field's tempo collapse.
            s.slow += (rssi - s.slow) * (1 - exp(-1 / 7.8))
            s.jitter += (abs(rssi - s.slow) - s.jitter) * (1 - exp(-1 / 6.2))
            // Fluctuation rate: count crossings of the device's own mean (±1.5 dB dead band)
            let dev = rssi - s.slow
            let sign = dev > 1.5 ? 1 : (dev < -1.5 ? -1 : 0)
            if sign != 0 {
                if s.lastSign != 0 && sign != s.lastSign { crossings += 1 }
                s.lastSign = sign
            }
            s.lastSeen = now
            s.samples += 1
            if s.name == nil { s.name = name }
            store[id] = s
        } else {
            store[id] = RadioSource(id: id, seed: Self.seed(for: id), name: name,
                                    vendor: company.flatMap { Self.vendors[$0] },
                                    raw: rssi, fast: rssi, slow: rssi, jitter: 0, lastFast: rssi,
                                    lastSeen: now, firstSeen: now)
        }
    }

    // MARK: Control loop (30 Hz)

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        for v in pendingTriggers { engine.params.nTrig[v] += 1 }
        pendingTriggers.removeAll(keepingCapacity: true)
        let span = ceilingDBm - floorDBm
        let melodyBase = 60 + rootNote + 12 * octave // C4…B4, transposed
        var flux = 0.0
        var heard = 0

        for (id, var s) in store {
            let age = now - s.lastSeen
            if age > 12 { store[id] = nil; continue }
            let fade = age < 2.5 ? 1.0 : max(0, 1 - (age - 2.5) / 6)
            let target = min(1, max(0, (s.fast - floorDBm) / span)) * fade
            s.level += (target - s.level) * alpha(7.8)
            s.levelRef += (s.level - s.levelRef) * (1 - exp(-1 / 18.0))
            flux += abs(s.fast - s.lastFast)
            s.lastFast = s.fast
            let phrase = Phrase(seed: s.seed, scaleSize: scale.steps.count)
            s.midi = scale.midi(base: melodyBase, degree: phrase.degrees[0])
            s.voice = nil
            if s.level > 0.03 { heard += 1 }
            store[id] = s
        }

        // Tempo from how restless the field is
        let rateNow = Double(crossings) * 30 / Double(max(1, store.count))
        crossings = 0
        fluctRate += (rateNow - fluctRate) * (1 - exp(-1.0 / (30 * 20)))
        updateTempo()

        // Air: how much the whole field is moving, relative to its own baseline.
        let meanFlux = flux / Double(max(1, store.count))
        fluxFast += (meanFlux - fluxFast) * alpha(6.2)
        fluxSlow += (meanFlux - fluxSlow) * 0.004
        let gust = fluxFast / (fluxSlow + 0.05) - 1
        air += (min(1, max(0, gust / 1.5)) - air) * alpha(19.5)

        allocateVoices()
        playLoops(now: now, melodyBase: melodyBase)
        driveBed(now: now, heard: heard)

        sources = store.values.sorted { $0.level > $1.level }
    }

    /// Fold the fluctuation rate (crossings per minute) by octaves — halving or doubling —
    /// choosing whichever fold sits closest to the current tempo, so it never lurches
    /// across an octave boundary. Then glide there over ~12 s.
    private func updateTempo() {
        let raw = fluctRate * 60
        guard raw > 1 else { return }
        var target = bpm
        var bestDistance = Double.infinity
        for k in -4...7 {
            let c = raw / pow(2, Double(k))
            guard c >= 44 && c <= 104 else { continue }
            let d = abs(log2(c / bpm))
            if d < bestDistance { bestDistance = d; target = c }
        }
        // If the nearest fold is in a different octave, switch octave at once (half- or
        // double-time keeps the pulse coherent) and glide only within it.
        let octaves = (log2(target / bpm)).rounded()
        if octaves != 0 { bpm *= pow(2, octaves) }
        bpm += (target - bpm) * (1 - exp(-1.0 / (30 * 12)))
    }

    /// Sticky allocation: a source keeps its voice while it stays in the top N,
    /// with a small incumbency bonus so voices don't flap between near-equals.
    private func allocateVoices() {
        let limit = max(1, min(voiceLimit, DroneParams.voiceCount))
        let ranked = store.values
            .filter { $0.level > 0.03 }
            .sorted { a, b in
                let sa = a.level + (owners.contains(a.id) ? 0.06 : 0)
                let sb = b.level + (owners.contains(b.id) ? 0.06 : 0)
                return sa > sb
            }
            .prefix(limit)
            .map(\.id)
        let chosen = Set(ranked)
        for slot in 0..<owners.count {
            if let o = owners[slot], slot >= limit || !chosen.contains(o) {
                owners[slot] = nil
                loopPos[slot] = -1
            }
        }
        for id in ranked where !owners.contains(id) {
            if let free = (0..<limit).first(where: { owners[$0] == nil }) {
                owners[free] = id
                loopPos[free] = -1
            }
        }
    }

    /// Each voiced device's loop runs on the shared clock whether or not you can hear it;
    /// owning a voice just lets it be heard. Faint devices only sing the first note of
    /// their phrase — move closer and the rest of the phrase unfolds.
    private func playLoops(now: TimeInterval, melodyBase: Int) {
        let p = engine.params
        var voiced = 0
        // More singers → each one a little softer, so 30 voices stay a haze, not a wall.
        let active = owners.compactMap { $0 }.count
        let densityGain = 1 / sqrt(max(1, Double(active) / 6))
        for slot in 0..<owners.count {
            guard let id = owners[slot], var s = store[id] else { continue }
            voiced += 1
            s.voice = slot
            let phrase = Phrase(seed: s.seed, scaleSize: scale.steps.count)
            let pan = Float(Double(s.seed % 1000) / 1000 * 1.6 - 0.8)

            let pos = (now / phrase.period + phrase.phase).truncatingRemainder(dividingBy: 1) * phrase.period
            let last = loopPos[slot]
            loopPos[slot] = pos
            if last >= 0 && isPlaying {
                let audible = min(phrase.degrees.count,
                                  max(1, Int((s.level * Double(phrase.degrees.count)).rounded(.up))))
                for k in 0..<audible {
                    let on = phrase.offsets[k]
                    let crossed = last <= pos ? (on > last && on <= pos) : (on > last || on <= pos)
                    guard crossed else { continue }
                    if on == s.pulled { s.pulled = -1; continue }   // already played early
                    fire(id, &s, degree: phrase.degrees[k], dur: phrase.durations[k], pan: pan,
                         gain: densityGain, melodyBase: melodyBase, now: now)
                }

                // Snap: toward the fast end of Response, a sudden approach (≈ +8 dB within
                // ~0.6 s) pulls the device's next note forward, so it sings the moment you
                // move to it instead of waiting for its loop.
                let rise = s.level - s.levelRef
                if snapAmount > 0 && rise > 0.14 - 0.04 * snapAmount && now - s.lastPluck > 0.8 {
                    var k = 0
                    var soonest = Double.infinity
                    for j in 0..<audible {
                        var ahead = phrase.offsets[j] - pos
                        if ahead <= 0 { ahead += phrase.period }
                        if ahead < soonest { soonest = ahead; k = j }
                    }
                    fire(id, &s, degree: phrase.degrees[k], dur: phrase.durations[k], pan: pan,
                         gain: densityGain, melodyBase: melodyBase, now: now)
                    s.pulled = phrase.offsets[k]
                    s.lastPluck = now
                }
            }
            store[id] = s
        }
        voicedCount = voiced

        // Live expression on every sounding note, following the device that played it.
        for v in 0..<poolOwner.count {
            guard let id = poolOwner[v], let s = store[id] else { continue }
            p.nLive[v] = Float((1 - liveDepth) + liveDepth * s.level)
            p.nWow[v] = Float(s.jitterNorm * 28)           // a disturbed path = warped tape
        }
    }

    /// The pad bed: a stacked chord that glides to the next root every `chordSeconds`.
    private func driveBed(now: TimeInterval, heard: Int) {
        let p = engine.params
        let prog = scale.progression
        let r = prog[Int(now / chordSeconds) % prog.count]
        let base = 48 + rootNote + 12 * max(octave, -1)   // C3…B3; never below C2 for the bass
        let notes = [scale.midi(base: base, degree: r) - 12,
                     scale.midi(base: base, degree: r + 2),
                     scale.midi(base: base, degree: r + 4),
                     scale.midi(base: base, degree: r) + 12]
        for (i, m) in notes.enumerated() { p.bFreq[i] = Float(mtof(m)) }
        let rootPC = scale.midi(base: base, degree: r) % 12
        chordName = noteNames[rootPC]

        let density = min(1, Double(heard) / 20)
        p[.bedAmp] = Float(0.3 + 0.5 * density)
        p[.bedCut] = Float(0.15 + 0.25 * density + 0.6 * air)
        p[.response] = Float(response)
        engine.setHalo(0.2 + 0.8 * air)

        // Arpeggio: chord tones over two octaves, plus scale tones for passing notes
        let ap = engine.arpParams
        let arpBase = 48 + rootNote + 12 * octave
        let n = scale.steps.count
        let chordDegrees = n >= 7 ? [r, r + 2, r + 4, r + 6] : [r, r + 2, r + 4]
        var chordNotes = Set<Int>()
        for o in 0..<2 { for d in chordDegrees { chordNotes.insert(scale.midi(base: arpBase, degree: d) + 12 * o) } }
        let chordSorted = Array(chordNotes.sorted().prefix(ArpParams.maxChord))
        let scaleSorted = Array(Set((r...(r + 2 * n)).map { scale.midi(base: arpBase, degree: $0) })
            .sorted().prefix(ArpParams.maxScale))
        // Keep the piano inside its sampled range (C2–C6, plus a little headroom)
        func fold(_ m: Int) -> Int {
            var x = m
            while x > 96 { x -= 12 }
            while x < 36 { x += 12 }
            return x
        }
        let chordFolded = Array(Set(chordSorted.map(fold)).sorted())
        let scaleFolded = Array(Set(scaleSorted.map(fold)).sorted())
        for (i, m) in chordFolded.enumerated() { ap.chord[i] = Float(mtof(m)) }
        for (i, m) in scaleFolded.enumerated() { ap.scale[i] = Float(mtof(m)) }
        ap[.chordCount] = Float(chordFolded.count)
        ap[.scaleCount] = Float(scaleFolded.count)
        ap[.enabled] = (arpOn && isPlaying) ? 1 : 0
        ap[.bpm] = Float(bpm)
        ap[.density] = Float(density)
        engine.setArpSpace(density: density, bpm: bpm)
    }

    /// Start one note of a device's phrase on the least-recently-used pool voice
    /// (the one deepest into its tail).
    private func fire(_ id: UUID, _ s: inout RadioSource, degree: Int, dur: Double, pan: Float,
                      gain: Double, melodyBase: Int, now: TimeInterval) {
        let p = engine.params
        var v = 0
        for i in 1..<poolLastTrig.count where poolLastTrig[i] < poolLastTrig[v] { v = i }
        poolLastTrig[v] = now
        poolOwner[v] = id
        let midi = scale.midi(base: melodyBase, degree: degree)
        p.nFreq[v] = Float(mtof(midi))
        p.nVel[v] = Float((0.35 + 0.65 * s.level) * gain)
        p.nBright[v] = Float(0.2 + 0.8 * s.level)
        p.nDur[v] = Float(dur)
        p.nPan[v] = pan
        pendingTriggers.append(v)
        s.lastNote = now
    }

    // MARK: Helpers

    /// 0 across most of the range, rising to 1 at the snap end of Response.
    private var snapAmount: Double {
        min(1, max(0, (0.3 - response) / (0.3 - FieldModel.snapResponse)))
    }

    /// One-pole smoothing coefficient for a time constant given in updates
    /// (RSSI reports or 30 Hz ticks), scaled by the Response control.
    private func alpha(_ tau: Double) -> Double {
        1 - exp(-1 / max(0.3, tau * response))
    }

    /// How hard live strength pushes on notes already sounding: gentle at drift, total at
    /// snap, so a cupped hand silences what's ringing rather than just dimming it.
    private var liveDepth: Double {
        let lo = FieldModel.snapResponse
        let tight = 1 - (response - lo) / (1 - lo)
        return 0.55 + 0.45 * min(1, max(0, tight))
    }

    private static func seed(for id: UUID) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { h ^= UInt32(b); h = h &* 16_777_619 }
        }
        return h
    }

    /// Bluetooth SIG company identifiers for common manufacturers.
    private static let vendors: [UInt16: String] = [
        0x004C: "Apple", 0x0006: "Microsoft", 0x0075: "Samsung", 0x00E0: "Google",
        0x0087: "Garmin", 0x012D: "Sony", 0x009E: "Bose", 0x0171: "Amazon",
        0x0059: "Nordic", 0x02E5: "Espressif", 0x038F: "Xiaomi",
    ]
}

// MARK: - CoreBluetooth delegate (callbacks arrive on the main queue)

extension FieldModel: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { self.handleState(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        var company: UInt16? = nil
        if let d = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, d.count >= 2 {
            let i = d.startIndex
            company = UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
        }
        let rssi = RSSI.doubleValue
        MainActor.assumeIsolated { self.ingest(id: id, name: name, company: company, rssi: rssi) }
    }
}
