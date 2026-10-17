import AVFoundation
import AudioToolbox

/// The four instruments Ambit plays.
enum Layer: Int, CaseIterable, Identifiable {
    case aether, bell, motif, orbit
    var id: Int { rawValue }
}

/// A flag the audio thread reads before rendering a layer. Closed, the layer renders
/// silence and costs almost nothing, so a stopped instrument doesn't spend the battery.
/// (A plain Bool, written on main and read on the audio thread: the same benign-race scheme
/// as the DSPs' parameter blocks.)
final class RenderGate {
    var open = false
}

/// One AVAudioEngine for the whole ensemble:
///
///   Aether's graph        ─┐
///   Bellweathered's graph ─┼─ layer bus (trim × pad) ─ main mixer ─ peak limiter ─ out
///   Leitmotif's graph     ─┤
///   Orbitakt's graph      ─┘
///
/// Each instrument's engine registers a builder that wires its own DSP and effects into its
/// layer bus. The graph is built once, on the first play; after that a layer starts and
/// stops by fading its DSP and opening or closing its render gate, so the engine itself
/// only pauses when every layer has gone quiet.
///
/// The session mixes with other audio and the "audio" background mode keeps it running in
/// other apps and on the lock screen: Leitmotif's natural habitat.
final class AmbitAudio {
    typealias Builder = (AVAudioEngine, AVAudioFormat, AVAudioMixerNode) -> Void

    private let engine = AVAudioEngine()
    private var buses: [AVAudioMixerNode] = Layer.allCases.map { _ in AVAudioMixerNode() }
    private let limiter: AVAudioUnitEffect
    private var builders: [Layer: Builder] = [:]
    private var built = false
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

    /// Called once by each instrument's engine, at init.
    func register(_ layer: Layer, build: @escaping Builder) {
        builders[layer] = build
    }

    /// The layer bus's gain (its trim times the pad's bias).
    func setGain(_ gain: Double, for layer: Layer) {
        buses[layer.rawValue].outputVolume = Float(max(0, min(1, gain)))
    }

    /// A layer wants to sound: make sure the session, graph and engine are up.
    func layerStarted(_ layer: Layer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if !built { buildGraph() }
        running.insert(layer)
        pauseToken += 1
        if !engine.isRunning { try engine.start() }
    }

    /// A layer has faded out and its tails have rung. When the last one goes, pause.
    func layerStopped(_ layer: Layer) {
        running.remove(layer)
        guard running.isEmpty else { return }
        pauseToken += 1
        let token = pauseToken
        // A moment's grace for the shared reverbs, and in case another layer starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, token == self.pauseToken, self.running.isEmpty else { return }
            self.engine.pause()
        }
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
        main.outputVolume = 0.85
        for layer in Layer.allCases {
            let bus = buses[layer.rawValue]
            engine.attach(bus)
            engine.connect(bus, to: main, fromBus: 0, toBus: main.nextAvailableInputBus, format: format)
            builders[layer]?(engine, format, bus)
        }
        engine.prepare()
    }
}

/// The render block every instrument hands to its AVAudioSourceNode: silence (flagged as
/// such) while the gate is closed, otherwise the DSP.
func gatedRender(_ gate: RenderGate,
                 _ render: @escaping (Int, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Void)
    -> AVAudioSourceNodeRenderBlock {
    return { silence, _, frameCount, ablPointer in
        let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
        guard buffers.count >= 2,
              let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let n = Int(frameCount)
        if !gate.open {
            l.update(repeating: 0, count: n)
            r.update(repeating: 0, count: n)
            silence.pointee = true
            return noErr
        }
        render(n, l, r)
        return noErr
    }
}
