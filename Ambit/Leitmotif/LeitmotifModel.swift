import Foundation

/// Leitmotif: your phone's own life, sung as a solo line over the Aether + Bellweathered duo.
///
/// It listens to the phone itself, on the phone, with no permission prompts:
///  • events: the charger, headphones, Wi-Fi or cellular, Low Power Mode, heat, a flat
///    battery, being picked up or set down, a walk starting. Each kind has its own fixed motif,
///    and the opposite event is the same tune backwards (see `LifeSensor`);
///  • footsteps: while you walk or run, each step is a soft high note;
///  • the gait of its network traffic: each burst becomes a letter, and each three-letter word
///    a motif, so a habit (streaming, messaging, scrolling) always sounds like itself;
///  • the water meter and the body: how hard the phone is talking, how much it's moving and how
///    bright the screen is set how firmly and brightly the piano is played; a low battery tires
///    it, resting flat hushes it, and tilting it leans the sound left or right.
///
/// The duo leads; Leitmotif follows. It takes key and scale from Bellweathered (or Aether),
/// tempo and the current chord from Aether. Inside Ambit they share one process, so it stays
/// in step with them in the background too; it still remembers what it last heard if a lead
/// ever goes quiet.
@MainActor
final class LeitmotifModel: ObservableObject {
    // What the screen shows
    @Published private(set) var utterances: [Utterance] = []     // newest first
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
    @Published var whisperChatter: Bool { didSet { save("whisperChatter", whisperChatter) } }
    /// Charger, headphones, connections, battery, heat: events with their own motifs.
    @Published var lifeEvents: Bool { didSet { save("lifeEvents", lifeEvents); configureLife() } }
    /// Footsteps, being picked up, and how the phone is held.
    @Published var lifeMovement: Bool { didSet { save("lifeMovement", lifeMovement); configureLife() } }
    @Published private(set) var lifeLine = ""
    /// Write every raw counter sample to a CSV (Files › On My iPhone › Leitmotif).
    @Published var recording = false { didSet { recordingChanged() } }
    @Published private(set) var logURL: URL?
    @Published private(set) var bursts = 0

    let duo = DuoLink(role: "leitmotif")
    private let engine: MotifEngine
    private var meter = Meter()
    private let gait = GaitSensor()
    private let life = LifeSensor()
    private var stepsPending: [Double] = []     // footsteps waiting for their sixteenth
    private var stepFigure = 0
    private var gaitWord: [GaitSymbol] = []
    private var gaitSeq = 0
    private var trafficLog: TrafficLog?
    private var timer: Timer?
    private var tickCount = 0

    // The score
    private var pending: [Utterance] = []       // motifs waiting for the soloist
    private var whispers: [Utterance] = []      // chatter blips waiting
    private var leadFree: Double = 0          // beat at which the soloist is next free
    private var lastSung: Double = -100
    private var nextHum: Double = 0
    private var lastWhisper: Double = -100
    private var heardTimes: [Date] = []
    private var lifeTired = 0.0                 // 0…1: how flat the battery is

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
        whisperChatter = d.object(forKey: "whisperChatter") as? Bool ?? true
        lifeEvents = d.object(forKey: "lifeEvents") as? Bool ?? true
        lifeMovement = d.object(forKey: "lifeMovement") as? Bool ?? true

        gait.onBurst = { [weak self] b in MainActor.assumeIsolated { self?.heard(b) } }
        gait.onSample = { [weak self] t, w, m, p in MainActor.assumeIsolated { self?.trafficLog?.write(t, w, m, p) } }
        life.onEvent = { [weak self] e in MainActor.assumeIsolated { self?.lifted(e) } }
        life.onStep = { [weak self] s in MainActor.assumeIsolated { self?.stepped(s) } }
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

    func togglePlay() {
        if isPlaying {
            engine.stop()
            isPlaying = false
            life.stop()
            stepsPending.removeAll()
            lifeLine = ""
        } else {
            do {
                try engine.start()
                isPlaying = true
                leadFree = engine.params.nowBeat
                gait.reset()
                gaitWord.removeAll()
                life.start(events: lifeEvents, movement: lifeMovement)
            } catch {
                status = "Audio failed to start: \(error.localizedDescription)"
            }
        }
        updateStatus()
    }


    func clearLedger() { utterances.removeAll() }

    private func configureLife() {
        if isPlaying { life.configure(events: lifeEvents, movement: lifeMovement) }
        if !lifeMovement { stepsPending.removeAll() }
    }

    // MARK: The clock

    private func tick() {
        let p = engine.params
        p.publish()
        tickCount += 1
        let now = ProcessInfo.processInfo.systemUptime

        // ~15 samples a second for the gait (and the traffic log, if it's recording)
        if tickCount % 2 == 0 && (isPlaying || recording) { gait.sample(now: now) }
        if tickCount % 15 == 0 {
            meter.sample(now: now)
            down = meter.down
            up = meter.up
            meterWorks = meter.works
            let cutoff = Date().addingTimeInterval(-60)
            heardTimes.removeAll { $0 < cutoff }
            perMinute = heardTimes.count
            if tickCount % 90 == 0 { refreshHarmonyLine() }
            life.poll()
            lifeLine = isPlaying ? life.summary : ""
        }

        // The traffic sets the touch; the body and the screen colour it.
        let traffic = meterWorks ? meter.downLevel : 0.35
        let body = lifeMovement ? life.intensity : 0
        let screen = isPlaying ? life.brightness : 0.5
        let tired = (life.battery >= 0 && !life.charging) ? max(0, (0.2 - life.battery) / 0.2) : 0
        let level = max(0, min(1, (0.7 * traffic + 0.3 * body) * (0.7 + 0.3 * screen)))
        p[.bpm] = Float(effectiveBPM)
        p[.bright] = Float(level)
        let heat = life.thermal >= 3 ? 0.9 : (life.thermal == 2 ? 0.6 : (life.thermal == 1 ? 0.25 : 0))
        p[.breath] = Float(max(meterWorks ? meter.upLevel : 0.2, heat))
        p[.whisperGain] = (whisperChatter || (lifeMovement && isPlaying)) ? 1 : 0
        lifeTired = tired
        engine.setSpace(bpm: effectiveBPM, busy: min(1, Double(perMinute) / 120))

        if isPlaying { schedule(level: level) }

        if tickCount % 3 == 0 {
            voice = min(1, p.clock[1] * 1.6)
            whisper = min(1, p.clock[2] * 2)
        }
    }

    // MARK: Ingest

    /// A finished burst of traffic: the newest letter of the gait word.
    private func heard(_ b: Burst) {
        guard isPlaying else { return }
        gaitWord.append(GaitSymbol(b))
        if gaitWord.count > 3 { gaitWord.removeFirst(gaitWord.count - 3) }
        gaitSeq += 1
        bursts += 1
        accept(Score.utterance(b, word: gaitWord, id: gaitSeq))
    }

    /// Something happened to the phone: sing its motif.
    private func lifted(_ e: LifeEvent) {
        guard isPlaying else { return }
        gaitSeq += 1
        let h = Score.fnv(e.key)
        let pan = Float(Double((h >> 40) & 0xFF) / 255 - 0.5) * 0.8
        accept(Score.life(e, id: gaitSeq, pan: pan))
    }

    /// A footstep: a soft high note on the next sixteenth.
    private func stepped(_ strength: Double) {
        guard isPlaying, lifeMovement else { return }
        if stepsPending.count < 4 { stepsPending.append(strength) }
    }

    /// A pan position leaned toward the side the phone is tilted to.
    private func lean(_ pan: Float) -> Float {
        let tilt = lifeMovement ? life.roll * 0.5 : 0
        return Float(max(-0.95, min(0.95, Double(pan) * 0.6 + tilt)))
    }

    private func accept(_ incoming: Utterance) {
        var t = incoming
        heardTimes.append(t.time)
        switch t.kind {
        case .chatter:
            if whisperChatter && isPlaying {
                if whispers.count < 6 { whispers.append(t); t.fate = .whispered } else { t.fate = .dropped }
            } else {
                t.fate = .dropped
            }
        case .life:
            // Something happened to the phone: it goes to the front of the queue
            if !isPlaying {
                t.fate = .dropped
            } else {
                pending.insert(t, at: 0)
                if pending.count > 6 {
                    let gone = pending.removeLast()
                    setFate(gone.id, .dropped)
                }
            }
        case .burst, .bulk:
            if !isPlaying {
                t.fate = .dropped
            } else if pending.contains(where: { $0.word == t.word }) {
                t.fate = .merged                 // already waiting to be sung
            } else {
                pending.append(t)
                if pending.count > 6 {
                    let gone = pending.removeFirst()
                    setFate(gone.id, .dropped)
                }
            }
        }
        utterances.insert(t, at: 0)
        if utterances.count > 120 { utterances.removeLast(utterances.count - 120) }
    }

    private func setFate(_ id: Int, _ fate: Utterance.Fate) {
        if let i = utterances.firstIndex(where: { $0.id == id }) { utterances[i].fate = fate }
    }

    // MARK: Scheduling onto the grid

    private func schedule(level: Double) {
        let p = engine.params
        let now = p.nowBeat
        if leadFree < now { leadFree = now }
        let resting = lifeMovement && life.flat && life.activity == .still     // lying on a table
        let velBase = (0.42 + 0.4 * level) * (1 - 0.35 * lifeTired) * (resting ? 0.8 : 1)

        // The soloist: one motif at a time, starting on the next eighth.
        if leadFree - now < 1, !pending.isEmpty {
            let t = pending.removeFirst()
            let busy = pending.count >= 3 || lifeTired > 0.6     // a backlog or a flat battery: say less
            let notes = busy ? Array(t.motif.prefix(2)).map { MotifNote(degree: $0.degree, eighths: 1) } : t.motif
            var b = max(leadFree, ((now + 0.35) * 2).rounded(.up) / 2)
            let kindGain = (t.kind == .bulk ? 0.7 : 1.0) * t.gain
            for (i, n) in notes.enumerated() {
                let beats = Double(n.eighths) * 0.5
                let accent = i == 0 ? 1.0 : 0.85
                p.stageLead(beat: b, freq: pitch(n.degree, register: t.kind == .bulk ? -1 : t.register),
                            vel: velBase * kindGain * accent, beats: beats, pan: lean(t.pan))
                b += beats
            }
            leadFree = b + 0.5                           // a breath between phrases
            lastSung = b
            setFate(t.id, .sung)
        } else if pending.isEmpty, level > 0.4, now - lastSung > 8, now >= nextHum, leadFree - now < 1 {
            // Heavy traffic but no new bursts (one long stream or download): hold the chord root.
            let b = max(leadFree, now.rounded(.up))
            p.stageLead(beat: b, freq: pitch(0, register: -1), vel: 0.25 + 0.2 * level, beats: 4, pan: 0)
            leadFree = b + 4
            nextHum = b + 8
        }

        // Whispers: chatter blips on the off-sixteenths, never more than two a beat.
        if !whispers.isEmpty, lastWhisper - now < 1.5 {
            let t = whispers.removeFirst()
            var b = max(lastWhisper + 0.5, ((now + 0.2) * 4).rounded(.up) / 4)
            if b.truncatingRemainder(dividingBy: 0.5) == 0 { b += 0.25 }
            var r = Score.Mix(Score.fnv(t.word))
            p.stageWhisper(beat: b, freq: pitch(r.int(7), register: 2), vel: 0.5 + 0.4 * Double(r.int(3)) / 2, pan: lean(t.pan))
            lastWhisper = b
        }

        // Footsteps: a soft high note on the next sixteenth, cycling a little figure of chord
        // tones. They share the whisper ring, which is played in order, so they follow the same
        // cursor as the chatter whispers.
        if !stepsPending.isEmpty {
            let strength = stepsPending.removeFirst()
            if lifeMovement, !resting, lastWhisper - now < 1.0 {
                let b = max(lastWhisper + 0.25, ((now + 0.1) * 4).rounded(.up) / 4)
                let figure = [0, 2, 4, 2]
                let degree = figure[stepFigure % figure.count]
                stepFigure += 1
                p.stageWhisper(beat: b, freq: pitch(degree, register: 1), vel: 0.2 + 0.3 * strength, pan: lean(0))
                lastWhisper = b
            }
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

    private func recordingChanged() {
        if recording {
            gait.reset()
            trafficLog = TrafficLog(now: ProcessInfo.processInfo.systemUptime)
            logURL = trafficLog?.url
            if trafficLog == nil { recording = false }
        } else {
            trafficLog?.close()
            trafficLog = nil
        }
    }

    private func updateStatus() {
        status = isPlaying ? "Listening to your phone’s life" : "Tap Listen to begin"
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        refreshHarmonyLine()
    }
}
