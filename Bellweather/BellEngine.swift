import AVFoundation

/// AVAudioEngine graph (mirrors the web version's routing):
///
///   BellDSP ── delay (beat-synced, LPF in the loop) ─┬────────────────────────── main out
///                                                    └─ reverb (100% wet) ─ LPF ─┘
///
/// The reverb return is lowpassed by humidity and its level follows cloud cover.
final class BellEngine {
    let params = BellParams()

    private let engine = AVAudioEngine()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private let reverbLP = AVAudioUnitEQ(numberOfBands: 1)
    private var source: AVAudioSourceNode?
    private var dsp: BellDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var observers: [NSObjectProtocol] = []
    private var lastDelay = 0.0, lastRevGain = -1.0, lastRevLP = -1.0

    init() {
        delay.delayTime = 1.25
        delay.feedback = 50
        delay.lowPassCutoff = 3200
        delay.wetDryMix = 16
        reverb.loadFactoryPreset(.cathedral)
        reverb.wetDryMix = 100
        let band = reverbLP.bands[0]
        band.filterType = .lowPass
        band.frequency = 6000
        band.bypass = false
        reverbLP.globalGain = -4
        [delay, reverb, reverbLP].forEach { engine.attach($0) }

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

    var isRunning: Bool { engine.isRunning }

    /// Delay on 1.5 beats (the web default), kept inside AVAudioUnitDelay's 2 s limit.
    func setTempo(_ bpm: Double) {
        let t = min(2.0, max(0.02, 60 / max(20, bpm) * 1.5))
        if abs(t - lastDelay) > 0.01 { lastDelay = t; delay.delayTime = t }
    }

    /// Reverb return level (linear) and its post-reverb lowpass (Hz).
    func setReverb(gain: Double, lowpass: Double) {
        if abs(gain - lastRevGain) > 0.01 {
            lastRevGain = gain
            reverbLP.globalGain = Float(20 * log10(max(0.01, gain)))
        }
        if abs(lowpass - lastRevLP) > 50 {
            lastRevLP = lowpass
            reverbLP.bands[0].frequency = Float(lowpass)
        }
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        if source == nil { buildGraph() }
        wantsRunning = true
        stopToken += 1
        params[.master] = 0.63
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
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
        let dsp = BellDSP(sampleRate: Float(sampleRate), params: params)
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
            let buffers = UnsafeMutableAudioBufferListPointer(ablPointer)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        let mixer = engine.mainMixerNode
        engine.connect(node, to: delay, format: format)
        engine.connect(delay,
                       to: [AVAudioConnectionPoint(node: mixer, bus: mixer.nextAvailableInputBus),
                            AVAudioConnectionPoint(node: reverb, bus: 0)],
                       fromBus: 0, format: format)
        engine.connect(reverb, to: reverbLP, format: format)
        engine.connect(reverbLP, to: mixer, format: format)
        mixer.outputVolume = 0.9
        engine.prepare()
        source = node
        self.dsp = dsp
    }
}
