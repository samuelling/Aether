import AVFoundation

/// AVAudioEngine graph:
///
///   DroneDSP ─┬─ long delay ── cathedral reverb ─────────────────┬─ main out
///             └─ +1 octave pitch ── hall (100% wet) ── halo bus ─┘
///
/// The octave-up, fully wet branch is the "halo" — a cheap cousin of a shimmer reverb.
final class DroneEngine {
    let params = DroneParams()

    private let engine = AVAudioEngine()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private let octave = AVAudioUnitTimePitch()
    private let haloVerb = AVAudioUnitReverb()
    private let haloBus = AVAudioMixerNode()
    private var source: AVAudioSourceNode?
    private var dsp: DroneDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        delay.delayTime = 1.35
        delay.feedback = 45
        delay.lowPassCutoff = 1800
        delay.wetDryMix = 28
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 62
        octave.pitch = 1200
        haloVerb.loadFactoryPreset(.largeHall2)
        haloVerb.wetDryMix = 100
        haloBus.outputVolume = 0.25
        [delay, reverb, octave, haloVerb, haloBus].forEach { engine.attach($0) }

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

    /// 0…1 — how bright the octave-up halo is.
    func setHalo(_ amount: Double) {
        haloBus.outputVolume = Float(0.08 + 0.5 * max(0, min(1, amount)))
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        if source == nil { buildGraph() }
        wantsRunning = true
        stopToken += 1
        params[.master] = 1
        if !engine.isRunning { try engine.start() }
    }

    /// Fade out, let the reverb tails ring, then pause the engine.
    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.engine.pause()
        }
    }

    private func resumeIfNeeded() {
        guard wantsRunning, !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    private func buildGraph() {
        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let dsp = DroneDSP(sampleRate: Float(sampleRate), params: params)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }

        engine.attach(node)
        engine.connect(node,
                       to: [AVAudioConnectionPoint(node: delay, bus: 0),
                            AVAudioConnectionPoint(node: octave, bus: 0)],
                       fromBus: 0, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(octave, to: haloVerb, format: format)
        engine.connect(haloVerb, to: haloBus, format: format)
        engine.connect(haloBus, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.9
        engine.prepare()
        source = node
        self.dsp = dsp
    }
}
