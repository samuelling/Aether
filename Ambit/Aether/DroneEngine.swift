import AVFoundation

/// Aether's corner of Ambit's audio graph:
///
///   DroneDSP ─┬─ long delay ── cathedral reverb ─────────────────┬─ Aether's layer bus
///             └─ +1 octave pitch ── hall (100% wet) ── halo bus ─┘
///
/// The octave-up, fully wet branch is the "halo" — a cheap cousin of a shimmer reverb.
/// The session, interruptions and the engine itself belong to `AmbitAudio`.
final class DroneEngine {
    let params = DroneParams()

    private let host: AmbitAudio
    private let gate = RenderGate()
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private let octave = AVAudioUnitTimePitch()
    private let haloVerb = AVAudioUnitReverb()
    private let haloBus = AVAudioMixerNode()
    private var dsp: DroneDSP?
    private var wantsRunning = false
    private var stopToken = 0

    init(host: AmbitAudio) {
        self.host = host
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
        host.register(.aether, gate: gate, effects: [delay, reverb, octave, haloVerb]) { [weak self] engine, format, out in
            self?.build(engine, format, out)
        }
    }

    /// 0…1 — how bright the octave-up halo is.
    func setHalo(_ amount: Double) {
        haloBus.outputVolume = Float(0.08 + 0.5 * max(0, min(1, amount)))
    }

    func start() throws {
        wantsRunning = true
        stopToken += 1
        params[.master] = 1
        gate.open = true
        try host.layerStarted(.aether)
    }

    /// Fade out, let the reverb tails ring, then close the gate.
    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.gate.open = false
            self.host.layerStopped(.aether)
        }
    }

    private func build(_ engine: AVAudioEngine, _ format: AVAudioFormat, _ out: AVAudioMixerNode) {
        let dsp = DroneDSP(sampleRate: Float(format.sampleRate), params: params)
        let node = AVAudioSourceNode(format: format, renderBlock: gatedRender(gate) { n, l, r in
            dsp.render(frames: n, left: l, right: r)
        })
        [node, delay, reverb, octave, haloVerb, haloBus].forEach { engine.attach($0) }
        engine.connect(node,
                       to: [AVAudioConnectionPoint(node: delay, bus: 0),
                            AVAudioConnectionPoint(node: octave, bus: 0)],
                       fromBus: 0, format: format)
        engine.connect(delay, to: reverb, format: format)
        engine.connect(reverb, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        engine.connect(octave, to: haloVerb, format: format)
        engine.connect(haloVerb, to: haloBus, format: format)
        engine.connect(haloBus, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        self.dsp = dsp
    }
}
