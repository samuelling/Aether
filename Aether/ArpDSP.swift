import Foundation

// MARK: - Control surface

/// Arpeggiator controls (main thread writes, audio thread reads). Plain aligned Float
/// stores, same contract as DroneParams: no locks, no allocation on the audio thread.
final class ArpParams {
    static let maxChord = 12
    static let maxScale = 20

    enum G: Int, CaseIterable {
        case enabled, bpm, density, level, dust, chordCount, scaleCount
    }

    /// Chord tones and scale tones (Hz, ascending) the walk can land on.
    let chord: UnsafeMutablePointer<Float>
    let scale: UnsafeMutablePointer<Float>
    private let g: UnsafeMutablePointer<Float>

    init() {
        chord = UnsafeMutablePointer<Float>.allocate(capacity: ArpParams.maxChord)
        chord.initialize(repeating: 220, count: ArpParams.maxChord)
        scale = UnsafeMutablePointer<Float>.allocate(capacity: ArpParams.maxScale)
        scale.initialize(repeating: 220, count: ArpParams.maxScale)
        g = UnsafeMutablePointer<Float>.allocate(capacity: G.allCases.count)
        g.initialize(repeating: 0, count: G.allCases.count)
        g[G.bpm.rawValue] = 66
        g[G.level.rawValue] = 0.8
        g[G.dust.rawValue] = 0.6
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    deinit {
        chord.deallocate()
        scale.deallocate()
        g.deallocate()
    }
}

// MARK: - Dusty upright, synthesized once

/// A small multisampled "dusty upright", synthesized from scratch at startup (no recordings):
/// stiff-string partials (slightly sharp overtones), two detuned strings per note for beating,
/// two-stage decay (quick prompt sound, long aftersound), soft felt hammer, a short thump,
/// a felt-ish lowpass and gentle tape saturation. One sample per octave, C2–C6.
final class PianoSampler {
    static let rootMidis = [36, 48, 60, 72, 84]
    let sampleRate: Double
    let length: Int
    let count: Int
    /// Raw pointers so the audio thread never touches Swift arrays (no ARC traffic).
    let buffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let rootFreqs: UnsafeMutablePointer<Float>

    init(sampleRate: Double = 48_000, seconds: Double = 4.0) {
        self.sampleRate = sampleRate
        length = Int(sampleRate * seconds)
        count = PianoSampler.rootMidis.count
        buffers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: count)
        rootFreqs = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for (i, m) in PianoSampler.rootMidis.enumerated() {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: length + 2)
            buf.initialize(repeating: 0, count: length + 2)
            PianoSampler.render(into: buf, count: length, midi: m, sr: sampleRate)
            buffers.advanced(by: i).initialize(to: buf)
            rootFreqs[i] = Float(440 * pow(2, Double(m - 69) / 12))
        }
    }

    deinit {
        for i in 0..<count { buffers[i].deallocate() }
        buffers.deallocate()
        rootFreqs.deallocate()
    }

    private static func render(into buf: UnsafeMutablePointer<Float>, count: Int, midi: Int, sr: Double) {
        let f0 = 440 * pow(2, Double(midi - 69) / 12)
        let B = 0.00022 * pow(2, Double(midi - 60) / 24)          // stiffer strings up high
        let T0 = 3.0 * pow(261.6 / f0, 0.45)                       // low notes ring longer
        let strings: [Double] = [pow(2, -0.7 / 1200), pow(2, 0.9 / 1200)]

        var n = 1
        while true {
            let fn = Double(n) * f0 * sqrt(1 + B * Double(n * n))
            if fn > 7_000 || n > 24 { break }
            // Felt hammer: overtones fall off, and faster for higher notes
            let amp = pow(Double(n), -1.15) * exp(-Double(n - 1) * f0 / 2_400)
            let tauFast = 0.35 * T0 / (1 + 0.9 * Double(n - 1))
            let tauSlow = 1.6 * T0 / (1 + 0.5 * Double(n - 1))
            let dF = exp(-1 / (tauFast * sr)), dS = exp(-1 / (tauSlow * sr))
            for ratio in strings {
                let w = 2 * Double.pi * fn * ratio / sr
                let c2 = 2 * cos(w)
                var y1 = 0.0, y2 = -sin(w)                         // y[n] = 2cos(w)y[n-1] − y[n-2]
                var eF = 0.65 * amp * 0.5, eS = 0.35 * amp * 0.5
                for i in 0..<count {
                    let y = c2 * y1 - y2
                    y2 = y1; y1 = y
                    buf[i] += Float(y * (eF + eS))
                    eF *= dF; eS *= dS
                    if eF + eS < 1e-6 { break }
                }
            }
            n += 1
        }

        // Hammer thump: a few ms of low, damped noise
        var seed: UInt32 = UInt32(truncatingIfNeeded: midi &* 2_654_435_761)
        var lp = 0.0
        let thumpLen = Int(0.04 * sr)
        for i in 0..<min(thumpLen, count) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let white = Double(seed) / Double(UInt32.max) * 2 - 1
            lp += (white - lp) * 0.08
            buf[i] += Float(lp * 0.25 * exp(-Double(i) / (0.006 * sr)))
        }

        // 3 ms attack ramp and felt lowpass (two one-poles ≈ 3.2 kHz)
        let attack = Int(0.003 * sr)
        let a = 1 - exp(-2 * Double.pi * 3_200 / sr)
        var l1 = 0.0, l2 = 0.0, peak = 0.0
        for i in 0..<count {
            var x = Double(buf[i])
            if i < attack { x *= Double(i) / Double(attack) }
            l1 += (x - l1) * a
            l2 += (l1 - l2) * a
            buf[i] = Float(l2)
            peak = max(peak, abs(l2))
        }
        // Gentle tape saturation: drive the attack peak to ~0.6 so tanh only rounds it off
        guard peak > 0 else { return }
        let drive = 0.6 / peak
        var peak2 = 0.0
        for i in 0..<count {
            let sat = tanh(1.6 * Double(buf[i]) * drive) / tanh(1.6)
            buf[i] = Float(sat)
            peak2 = max(peak2, abs(sat))
        }
        if peak2 > 0 {
            let g = Float(0.9 / peak2)
            for i in 0..<count { buf[i] *= g }
        }
        // Fade the last 300 ms so a sample never ends with a click
        let fade = Int(0.3 * sr)
        for i in max(0, count - fade)..<count { buf[i] *= Float(count - i) / Float(fade) }
    }
}

// MARK: - The arpeggiator

/// A stochastic arpeggio "dancing" over the current chord:
///  • a sample-accurate 8th-note clock with gentle swing and humanized timing,
///  • a random walk over the chord tones (mostly steps, sometimes leaps, repeats or rests),
///  • occasional passing tones from the scale and occasional two-note dyads,
///  • played on the dusty upright with tape wow, plus a faint bed of hiss and crackle.
final class ArpDSP {
    private let sr: Float
    private let p: ArpParams

    // Sample bank (installed once the background render finishes)
    private var bank: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var bankFreqs: UnsafeMutablePointer<Float>?
    private var bankCount = 0
    private var bankLength = 0
    private var bankRateScale: Float = 1
    private var ready = false

    // Voices
    private static let poly = 20
    private let vPos: UnsafeMutablePointer<Double>
    private let vRate: UnsafeMutablePointer<Float>
    private let vGain: UnsafeMutablePointer<Float>
    private let vGL: UnsafeMutablePointer<Float>
    private let vGR: UnsafeMutablePointer<Float>
    private let vBuf: UnsafeMutablePointer<Int>
    private let vOn: UnsafeMutablePointer<Bool>
    /// Stealing a sounding voice: fade it out over a few ms, then start the parked note.
    private let vFade: UnsafeMutablePointer<Float>
    private let vPendRate: UnsafeMutablePointer<Float>
    private let vPendGain: UnsafeMutablePointer<Float>
    private let vPendGL: UnsafeMutablePointer<Float>
    private let vPendGR: UnsafeMutablePointer<Float>
    private let vPendBuf: UnsafeMutablePointer<Int>
    private let vPending: UnsafeMutablePointer<Bool>

    // Clock and walk
    private var samplesToNext: Double = 0
    private var step = 0
    private var walk = 0
    private var rng: UInt32 = 0x2545_F491

    // Tape and dust
    private var wowPh: Float = 0, flutPh: Float = 0
    private var level: Float = 0, dust: Float = 0
    private var hissL: Float = 0, hissR: Float = 0
    private var crackle: Float = 0, crackleLP: Float = 0
    private let crackleDecay: Float
    private let stealDecay: Float

    init(sampleRate: Float, params: ArpParams) {
        sr = sampleRate
        p = params
        let n = ArpDSP.poly
        vPos = UnsafeMutablePointer<Double>.allocate(capacity: n); vPos.initialize(repeating: 0, count: n)
        vRate = UnsafeMutablePointer<Float>.allocate(capacity: n); vRate.initialize(repeating: 1, count: n)
        vGain = UnsafeMutablePointer<Float>.allocate(capacity: n); vGain.initialize(repeating: 0, count: n)
        vGL = UnsafeMutablePointer<Float>.allocate(capacity: n); vGL.initialize(repeating: 0.7, count: n)
        vGR = UnsafeMutablePointer<Float>.allocate(capacity: n); vGR.initialize(repeating: 0.7, count: n)
        vBuf = UnsafeMutablePointer<Int>.allocate(capacity: n); vBuf.initialize(repeating: 0, count: n)
        vOn = UnsafeMutablePointer<Bool>.allocate(capacity: n); vOn.initialize(repeating: false, count: n)
        vFade = UnsafeMutablePointer<Float>.allocate(capacity: n); vFade.initialize(repeating: 1, count: n)
        vPendRate = UnsafeMutablePointer<Float>.allocate(capacity: n); vPendRate.initialize(repeating: 1, count: n)
        vPendGain = UnsafeMutablePointer<Float>.allocate(capacity: n); vPendGain.initialize(repeating: 0, count: n)
        vPendGL = UnsafeMutablePointer<Float>.allocate(capacity: n); vPendGL.initialize(repeating: 0.7, count: n)
        vPendGR = UnsafeMutablePointer<Float>.allocate(capacity: n); vPendGR.initialize(repeating: 0.7, count: n)
        vPendBuf = UnsafeMutablePointer<Int>.allocate(capacity: n); vPendBuf.initialize(repeating: 0, count: n)
        vPending = UnsafeMutablePointer<Bool>.allocate(capacity: n); vPending.initialize(repeating: false, count: n)
        crackleDecay = expf(-1 / (0.0008 * sampleRate))
        stealDecay = expf(-1 / (0.0015 * sampleRate))      // ~1.5 ms τ, silent within ~10 ms
    }

    deinit {
        vPos.deallocate(); vRate.deallocate(); vGain.deallocate()
        vGL.deallocate(); vGR.deallocate(); vBuf.deallocate(); vOn.deallocate()
        vFade.deallocate(); vPendRate.deallocate(); vPendGain.deallocate()
        vPendGL.deallocate(); vPendGR.deallocate(); vPendBuf.deallocate(); vPending.deallocate()
    }

    /// Main thread, once. The sampler must outlive this object (DroneEngine holds it).
    func install(_ s: PianoSampler) {
        bank = s.buffers
        bankFreqs = s.rootFreqs
        bankCount = s.count
        bankLength = s.length
        bankRateScale = Float(s.sampleRate) / sr
        ready = true
    }

    @inline(__always) private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng >> 8) / 16_777_216
    }

    private func trigger(_ freq: Float, _ vel: Float) {
        guard let freqs = bankFreqs, bankCount > 0 else { return }
        // Nearest sample by pitch distance
        var bi = 0
        var best = Float.greatestFiniteMagnitude
        for i in 0..<bankCount {
            let d = abs(log2f(freq / freqs[i]))
            if d < best { best = d; bi = i }
        }
        // Free voice, else the one furthest into its decay (quietest)
        var v = -1
        var furthest = -1.0
        for i in 0..<ArpDSP.poly {
            if !vOn[i] { v = i; break }
            if vPos[i] > furthest { furthest = vPos[i]; v = i }
        }
        let pan = (rand() - 0.5) * 0.6
        let ang = (pan + 1) * Float.pi / 4
        let rate = freq / freqs[bi] * bankRateScale
        if vOn[v] {
            // Still sounding: park the new note and fade this one out first
            vPendRate[v] = rate; vPendGain[v] = vel
            vPendGL[v] = cosf(ang); vPendGR[v] = sinf(ang)
            vPendBuf[v] = bi
            vPending[v] = true
            return
        }
        vPos[v] = 0
        vRate[v] = rate
        vGain[v] = vel
        vGL[v] = cosf(ang); vGR[v] = sinf(ang)
        vBuf[v] = bi
        vFade[v] = 1
        vOn[v] = true
    }

    private func playStep() {
        let nChord = min(Int(p[.chordCount]), ArpParams.maxChord)
        guard nChord > 0 else { return }
        let nScale = min(Int(p[.scaleCount]), ArpParams.maxScale)
        let density = max(0, min(1, p[.density]))

        // Rests: more space when the field is sparse; phrases anchor on the bar line
        var restP = 0.5 - 0.3 * density
        if step % 8 == 0 { restP *= 0.4 }
        if rand() < restP { return }

        // Random walk over chord tones, reflecting at the edges
        let r = rand()
        if r < 0.10 { walk -= 2 }
        else if r < 0.38 { walk -= 1 }
        else if r < 0.48 { }                         // repeat
        else if r < 0.80 { walk += 1 }
        else if r < 0.92 { walk += 2 }
        else { walk = Int(rand() * Float(nChord)) }  // leap
        if walk < 0 { walk = -walk }
        if walk >= nChord { walk = 2 * (nChord - 1) - walk }
        walk = max(0, min(nChord - 1, walk))

        var f = p.chord[walk]
        // Passing tone: step to a neighbouring scale tone
        if nScale > 1 && rand() < 0.15 {
            var nearest = 0
            var best = Float.greatestFiniteMagnitude
            for i in 0..<nScale {
                let d = abs(p.scale[i] - f)
                if d < best { best = d; nearest = i }
            }
            let j = rand() < 0.5 ? nearest - 1 : nearest + 1
            if j >= 0 && j < nScale { f = p.scale[j] }
        }

        var vel = 0.45 + 0.3 * rand()
        if step % 4 == 0 { vel += 0.12 }
        trigger(f, vel)
        // Occasional dyad: add the chord tone two above
        if rand() < 0.08 && walk + 2 < nChord { trigger(p.chord[walk + 2], vel * 0.7) }
    }

    func render(frames: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        L.update(repeating: 0, count: frames)
        R.update(repeating: 0, count: frames)
        guard ready, let bank else { return }

        let enabled = p[.enabled] > 0.5
        let bpm = max(30, min(140, p[.bpm]))
        let stepSamples = Double(sr) * 60 / Double(bpm) / 2   // 8th notes
        let blockT = Float(frames) / sr
        let k = 1 - expf(-blockT / 0.8)
        let level0 = level, dust0 = dust
        level += ((enabled ? p[.level] : 0) - level) * k
        dust += ((enabled ? p[.dust] : 0) - dust) * k
        let lvlInc = (level - level0) / Float(frames)
        let dustInc = (dust - dust0) / Float(frames)
        var lvl = level0, dst = dust0

        let anyVoice = (0..<ArpDSP.poly).contains { vOn[$0] }
        if !enabled && !anyVoice && level < 1e-4 { samplesToNext = 0; return }

        let len = bankLength
        let twoPi = 2 * Float.pi
        let wowInc: Float = 0.33 / sr, flutInc: Float = 5.7 / sr
        let crackleChance = 2.5 / sr                       // ~2.5 crackles per second

        for i in 0..<frames {
            if enabled {
                samplesToNext -= 1
                if samplesToNext <= 0 {
                    let swing = step % 2 == 0 ? 1.12 : 0.88    // long–short, a lazy 56/44
                    let human = 1 + Double(rand() - 0.5) * 0.06
                    samplesToNext += stepSamples * swing * human
                    playStep()
                    step += 1
                }
            }

            // Tape: slow wow plus a little flutter on the playback speed
            let tape = 1 + 0.0012 * sinf(twoPi * wowPh) + 0.0003 * sinf(twoPi * flutPh)
            wowPh += wowInc; if wowPh >= 1 { wowPh -= 1 }
            flutPh += flutInc; if flutPh >= 1 { flutPh -= 1 }

            var outL: Float = 0, outR: Float = 0
            for v in 0..<ArpDSP.poly where vOn[v] {
                if vPending[v] {
                    vFade[v] *= stealDecay
                    if vFade[v] < 1e-3 {
                        // Old note gone: start the parked one
                        vPos[v] = 0
                        vRate[v] = vPendRate[v]; vGain[v] = vPendGain[v]
                        vGL[v] = vPendGL[v]; vGR[v] = vPendGR[v]
                        vBuf[v] = vPendBuf[v]
                        vFade[v] = 1
                        vPending[v] = false
                    }
                }
                let pos = vPos[v]
                let ip = Int(pos)
                if ip >= len - 1 {
                    if vPending[v] {
                        // Old note ran out before its fade finished: start the parked one now
                        vPos[v] = 0
                        vRate[v] = vPendRate[v]; vGain[v] = vPendGain[v]
                        vGL[v] = vPendGL[v]; vGR[v] = vPendGR[v]
                        vBuf[v] = vPendBuf[v]
                        vFade[v] = 1
                        vPending[v] = false
                    } else {
                        vOn[v] = false
                    }
                    continue
                }
                let fr = Float(pos - Double(ip))
                let buf = bank[vBuf[v]]
                let s = (buf[ip] + (buf[ip + 1] - buf[ip]) * fr) * vGain[v] * vFade[v]
                outL += s * vGL[v]
                outR += s * vGR[v]
                vPos[v] = pos + Double(vRate[v] * tape)
            }

            // Dust: faint hiss and the odd crackle
            let nL = rand() * 2 - 1, nR = rand() * 2 - 1
            hissL += (nL - hissL) * 0.35; hissR += (nR - hissR) * 0.35
            if rand() < crackleChance {
                crackle = (0.02 + 0.08 * rand()) * (rand() < 0.5 ? -1 : 1)
            }
            let c = crackle - crackleLP                     // crude highpass: a sharp tick
            crackleLP += (crackle - crackleLP) * 0.2
            crackle *= crackleDecay

            lvl += lvlInc
            dst += dustInc
            let dusty = dst * 0.35
            L[i] = tanhf(outL * 0.42 * lvl + (hissL * 0.006 + c) * dusty)
            R[i] = tanhf(outR * 0.42 * lvl + (hissR * 0.006 + c * 0.8) * dusty)
        }
    }
}
