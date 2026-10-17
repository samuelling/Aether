import AVFoundation
import AudioToolbox

/// The four instruments Ambit plays.
enum Layer: Int, CaseIterable, Identifiable {
    case aether, bell, motif, orbit
    var id: Int { rawValue }
}

/// What the audio thread checks before rendering a layer, and where it reports its cost.
/// Plain stores written on one thread and read on the other: the same benign-race scheme as
/// the DSPs' parameter blocks.
///
/// - `open`: the instrument is playing (or its tails are still ringing).
/// - `parked`: the pad has it at exactly zero, so there's nothing to hear.
/// Either way the layer renders flagged silence, costs almost nothing, and its effects are
/// bypassed. A parked instrument's synth holds still and picks up where it was when it
/// comes back.
final class RenderGate {
    var open = false
    var parked = false
    var active: Bool { open && !parked }

    /// Time spent rendering this layer's synth, as a fraction of the buffer's duration
    /// (smoothed). Written on the audio thread, read on main.
    var load: Double = 0
    var sampleRate: Double = 48_000
}

/// One AVAudioEngine for the whole ensemble:
///
///   Aether's graph        ─┐
///   Bellweathered's graph ─┼─ layer bus (trim × pad) ─ main mixer ─ peak limiter ─ out
///   Leitmotif's graph     ─┤
///   Orbitakt's graph      ─┘
///
/// Everything renders on one real-time thread, so idle work is kept off it: a layer that is
/// stopped or parked renders nothing and its effects (reverbs, delays, the pitch shifter) are
/// bypassed. The audio session is set up once, with roomy buffers (ambient music has no use
/// for low latency, and the headroom is what keeps four synths from crackling).
final class AmbitAudio {
    typealias Builder = (AVAudioEngine, AVAudioFormat, AVAudioMixerNode) -> Void

    private struct Entry {
        var gate: RenderGate
        var effects: [AVAudioNode]
        var build: Builder
    }

    private let engine = AVAudioEngine()
    private var buses: [AVAudioMixerNode] = Layer.allCases.map { _ in AVAudioMixerNode() }
    private let limiter: AVAudioUnitEffect
    private var entries: [Layer: Entry] = [:]
    private var built = false
    private var sessionReady = false
    private var running: Set<Layer> = []
    private var observers: [NSObjectProtocol] = []
    private var pauseToken = 0

    init() {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_PeakLimiter,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: desc)

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.resumeIfNeeded()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: .main) { [weak self] _ in
            self?.resumeIfNeeded()
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Called once by each instrument's engine, at init: its render gate, the effect nodes to
    /// bypass while it's silent, and the builder that wires it into its layer bus.
    func register(_ layer: Layer, gate: RenderGate, effects: [AVAudioNode], build: @escaping Builder) {
        entries[layer] = Entry(gate: gate, effects: effects, build: build)
    }

    /// The layer bus's gain (its trim times the pad's bias). At zero the layer is parked.
    func setGain(_ gain: Double, for layer: Layer) {
        let g = max(0, min(1, gain))
        buses[layer.rawValue].outputVolume = Float(g)
        guard let e = entries[layer] else { return }
        let parked = g < 0.0005
        if parked != e.gate.parked {
            e.gate.parked = parked
            refresh(layer)
        }
    }

    /// Synth render load per layer (0…1 of the real-time budget), for Settings.
    var loads: [Double] { Layer.allCases.map { entries[$0]?.gate.load ?? 0 } }

    /// A layer wants to sound: make sure the session, graph and engine are up.
    func layerStarted(_ layer: Layer) throws {
        try prepareSession()
        if !built { buildGraph() }
        running.insert(layer)
        refresh(layer)
        pauseToken += 1
        if !engine.isRunning { try engine.start() }
    }

    /// A layer has faded out and its tails have rung. When the last one goes, pause.
    func layerStopped(_ layer: Layer) {
        running.remove(layer)
        refresh(layer)
        guard running.isEmpty else { return }
        pauseToken += 1
        let token = pauseToken
        // A moment's grace in case another layer starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, token == self.pauseToken, self.running.isEmpty else { return }
            self.engine.pause()
        }
    }

    /// Effects run only while their layer can be heard.
    private func refresh(_ layer: Layer) {
        guard let e = entries[layer] else { return }
        let off = !e.gate.active
        for node in e.effects {
            if let fx = node as? AVAudioUnitEffect, fx.bypass != off { fx.bypass = off }
            if let fx = node as? AVAudioUnitTimeEffect, fx.bypass != off { fx.bypass = off }
        }
    }

    /// Once per launch (it can stall the main thread, so not on every Play).
    private func prepareSession() throws {
        guard !sessionReady else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // ~1024 frames at 44.1/48 kHz: latency doesn't matter here, headroom does.
        try? session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
        sessionReady = true
    }

    private func resumeIfNeeded() {
        guard !running.isEmpty, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    private func buildGraph() {
        built = true
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let main = engine.mainMixerNode
        engine.attach(limiter)
        engine.connect(main, to: limiter, format: format)
        // No fixed format into the output node, so it re-negotiates with the hardware after a
        // route change (AirPlay, Bluetooth headphones at 44.1 kHz).
        engine.connect(limiter, to: engine.outputNode, format: nil)
        // A safety net, not a sound: slow enough to release that it never chews on the kick
        // or the drone, and the mix is staged to stay under it.
        if let au = limiter.audioUnit {
            AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.008, 0)
            AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.15, 0)
            AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        }
        main.outputVolume = 0.8
        for layer in Layer.allCases {
            let bus = buses[layer.rawValue]
            engine.attach(bus)
            engine.connect(bus, to: main, fromBus: 0, toBus: main.nextAvailableInputBus, format: format)
            entries[layer]?.gate.sampleRate = sampleRate
            entries[layer]?.build(engine, format, bus)
            refresh(layer)
        }
        engine.prepare()
    }
}

private let hostTicksToSeconds: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom) / 1e9
}()

/// The render block every instrument hands to its AVAudioSourceNode: flagged silence while
/// the gate is closed or parked, otherwise the DSP. With `meter`, it also measures how much
/// of the buffer's time the DSP took.
func gatedRender(_ gate: RenderGate, meter: Bool = true,
                 _ render: @escaping (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void)
    -> AVAudioSourceNodeRenderBlock {
    let tick = hostTicksToSeconds
    return { silence, _, frameCount, ablPointer in
        let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
        guard buffers.count >= 2,
              let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let n = Int(frameCount)
        if !gate.active {
            l.update(repeating: 0, count: n)
            r.update(repeating: 0, count: n)
            silence.pointee = true
            if meter { gate.load *= 0.9 }
            return noErr
        }
        let t0 = mach_absolute_time()
        render(n, l, r)
        if meter, n > 0 {
            let spent = Double(mach_absolute_time() - t0) * tick
            let budget = Double(n) / gate.sampleRate
            gate.load += (spent / budget - gate.load) * 0.05
        }
        return noErr
    }
}
