import AVFoundation

/// Orbitakt's corner of Ambit's audio graph:
///
///   OrbitDSP dry bus (drums + dub echoes) ─────────────── Orbitakt's layer bus
///   OrbitDSP plate send ────────── plate reverb ── EQ ───┘
///
/// The dub delay runs inside OrbitDSP (it needs feedback filtering, saturation and wow that
/// AVAudioUnitDelay can't do). The two buses come from one DSP through two source nodes; the
/// dry node renders both and the send node hands over what it rendered. Both sit behind the
/// same render gate, so a stopped Orbitakt never replays a stale send. The plate return is
/// high-passed so the kick's tail never muddies it.
final class OrbitEngine {
    let params = OrbitParams()

    private let host: AmbitAudio
    private let gate = RenderGate()
    private let reverb = AVAudioUnitReverb()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private var dsp: OrbitDSP?
    private var wantsRunning = false
    private var stopToken = 0
    private var lastSpace = -1.0

    init(host: AmbitAudio) {
        self.host = host
        reverb.loadFactoryPreset(.plate)
        reverb.wetDryMix = 100
        let hp = eq.bands[0]
        hp.filterType = .highPass
        hp.frequency = 320
        hp.bypass = false
        let lp = eq.bands[1]
        lp.filterType = .lowPass
        lp.frequency = 6000
        lp.bypass = false
        eq.globalGain = 0
        host.register(.orbit, gate: gate, effects: [reverb, eq]) { [weak self] engine, format, out in
            self?.build(engine, format, out)
        }
    }

    /// 0…1: how much plate.
    func setSpace(_ x: Double) {
        guard abs(x - lastSpace) > 0.01 else { return }
        lastSpace = x
        params[.reverbSend] = Float(0.2 + 0.8 * x)
        eq.globalGain = Float(20 * log10(max(0.05, 0.5 + 0.7 * x)))
    }

    func start() throws {
        wantsRunning = true
        stopToken += 1
        params[.master] = 0.85
        gate.open = true
        try host.layerStarted(.orbit)
    }

    func stop() {
        wantsRunning = false
        params[.master] = 0
        stopToken += 1
        let token = stopToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, token == self.stopToken, !self.wantsRunning else { return }
            self.gate.open = false
            self.host.layerStopped(.orbit)
        }
    }

    private func build(_ engine: AVAudioEngine, _ format: AVAudioFormat, _ out: AVAudioMixerNode) {
        let dsp = OrbitDSP(sampleRate: Float(format.sampleRate), params: params)
        let dry = AVAudioSourceNode(format: format, renderBlock: gatedRender(gate) { n, l, r in
            dsp.render(frames: n, left: l, right: r)
        })
        let send = AVAudioSourceNode(format: format, renderBlock: gatedRender(gate, meter: false) { n, l, r in
            dsp.copySend(frames: n, left: l, right: r)
        })
        [dry, send, reverb, eq].forEach { engine.attach($0) }
        engine.connect(dry, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        engine.connect(send, to: reverb, format: format)
        engine.connect(reverb, to: eq, format: format)
        engine.connect(eq, to: out, fromBus: 0, toBus: out.nextAvailableInputBus, format: format)
        self.dsp = dsp
    }
}
