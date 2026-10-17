import AVFoundation

/// Leitmotif's corner of Ambit's audio graph:
///
///   MotifDSP ── dotted-eighth delay ── hall ── Leitmotif's layer bus
///
/// Ambit's session mixes with other audio and keeps running in the background, so Leitmotif
/// can keep singing quietly under whatever you're doing.
final class MotifEngine {
    let params = MotifParams()

    private let host: AmbitAudio
    private let gate = RenderGate()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private var dsp: MotifDSP?
    private var piano: PianoSampler?
    private var wantsRunning = false
    private var stopToken = 0
    private var lastDelay = 0.0
    private var lastWet = -1.0

    init(host: AmbitAudio) {
        self.host = host
        delay.delayTime = 0.625
        delay.feedback = 32
        delay.lowPassCutoff = 2600
        delay.wetDryMix = 18
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 30

        // Synthesize the piano off the main thread (a fraction of a second of work).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = PianoSampler()
            DispatchQueue.main.async {
                guard let self else { return }
                self.piano = s
                self.dsp?.install(s)
            }
        }
        host.register(.motif) { [weak self] engine, format, out in self?.build(engine, format, out) }
    }

    /// Echo on a dotted eighth of the tempo; the busier the phone, the wetter the room.
    func setSpace(bpm: Double, busy: Double) {
        let t = 45 / max(30, bpm)
        if abs(t - lastDelay) > 0.01 {
            lastDelay = t
            delay.delayTime = t
        }
        let wet = 14 + 16 * max(0, min(1, busy))
        if abs(wet - lastWet) > 0.5 {
            lastWet = wet
            delay.wetDryMix = Float(wet)
            reverb.wetDryMix = Float(28 + 14 * max(0, min(1, busy)))
        }
    }

    func start() throws {
        wantsRunning = true
        stopToken += 1
        params[.master] = 1
        gate.open = true
        try host.layerStarted(.motif)
    }

    /// Fade out, let the hall ring, then close the gate.
    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.gate.open = false
            self.host.layerStopped(.motif)
        }
    }

    private func build(_ engine: AVAudioEngine, _ format: AVAudioFormat, _ out: AVAudioMixerNode) {
        let dsp = MotifDSP(sampleRate: Float(format.sampleRate), params: params)
        if let piano { dsp.install(piano) }
        let node = AVAudioSourceNode(format: format, renderBlock: gatedRender(gate) { n, l, r in
            dsp.render(frames: n, left: l, right: r)
        })
        [node, delay, reverb].forEach { engine.attach($0) }
        engine.connect(node, to: delay, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        self.dsp = dsp
    }
}
