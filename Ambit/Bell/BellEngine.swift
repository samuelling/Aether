import AVFoundation

/// Bellweathered's corner of Ambit's audio graph (mirrors the web version's routing):
///
///   BellDSP ── delay (beat-synced, LPF in the loop) ─┬──────────────────── Bellweathered's bus
///                                                    └─ reverb (100% wet) ─ LPF ─┘
///
/// The reverb return is lowpassed by humidity and its level follows cloud cover.
final class BellEngine {
    let params = BellParams()

    private let host: AmbitAudio
    private let gate = RenderGate()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private let reverbLP = AVAudioUnitEQ(numberOfBands: 1)
    private var dsp: BellDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var lastDelay = 0.0, lastRevGain = -1.0, lastRevLP = -1.0

    init(host: AmbitAudio) {
        self.host = host
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
        host.register(.bell, gate: gate, effects: [delay, reverb, reverbLP]) { [weak self] engine, format, out in
            self?.build(engine, format, out)
        }
    }

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
        wantsRunning = true
        stopToken += 1
        params[.master] = 0.63
        gate.open = true
        try host.layerStarted(.bell)
    }

    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.gate.open = false
            self.host.layerStopped(.bell)
        }
    }

    private func build(_ engine: AVAudioEngine, _ format: AVAudioFormat, _ out: AVAudioMixerNode) {
        let dsp = BellDSP(sampleRate: Float(format.sampleRate), params: params)
        let node = AVAudioSourceNode(format: format, renderBlock: gatedRender(gate) { n, l, r in
            dsp.render(frames: n, left: l, right: r)
        })
        [node, delay, reverb, reverbLP].forEach { engine.attach($0) }
        engine.connect(node, to: delay, format: format)
        engine.connect(delay,
                       to: [AVAudioConnectionPoint(node: out, bus: out.nextAvailableInputBus),
                            AVAudioConnectionPoint(node: reverb, bus: 0)],
                       fromBus: 0, format: format)
        engine.connect(reverb, to: reverbLP, format: format)
        engine.connect(reverbLP, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        self.dsp = dsp
    }
}
