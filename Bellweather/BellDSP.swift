import Foundation

/// Control surface (main thread writes, audio thread reads). Plain aligned Float stores;
/// no locks and no allocation on the audio thread.
final class BellParams {
    static let layers = 6
    static let voices = 10

    enum G: Int, CaseIterable {
        case master
        // drone
        case droneHz, timbreA, timbreB, spread, cutoff, q, flfoRate, flfoDepth, swellMult, droneOut
        case lvl0, lvl1, lvl2, lvl3, lvl4, lvl5
        // air
        case windBP, windGust, windGain, rainGain, snowGain
        // hourly bell
        case bellTrig, bellF, bellDay, bellLevel
        // melody bus
        case melodyBus
    }

    // Melody note voices
    let nTrig: UnsafeMutablePointer<Float>     // counter; a change = note-on
    let nType: UnsafeMutablePointer<Float>     // 0 glass, 1 string, 2 kalimba
    let nFreq: UnsafeMutablePointer<Float>
    let nAmp: UnsafeMutablePointer<Float>
    let nPan: UnsafeMutablePointer<Float>
    let nDecay: UnsafeMutablePointer<Float>
    let nAtk: UnsafeMutablePointer<Float>
    let nBright: UnsafeMutablePointer<Float>
    let nCoef: UnsafeMutablePointer<Float>     // Karplus-Strong loop-filter coefficient

    private let g: UnsafeMutablePointer<Float>

    init() {
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: v, count: n)
            return p
        }
        let n = BellParams.voices
        nTrig = make(0, n); nType = make(0, n); nFreq = make(440, n); nAmp = make(0, n)
        nPan = make(0, n); nDecay = make(1.6, n); nAtk = make(0.002, n); nBright = make(0.6, n)
        nCoef = make(0.1, n)
        g = make(0, G.allCases.count)
        g[G.droneHz.rawValue] = 65.4
        g[G.cutoff.rawValue] = 1400
        g[G.q.rawValue] = 0.9
        g[G.spread.rawValue] = 1
        g[G.windBP.rawValue] = 400
        g[G.bellF.rawValue] = 130.8
        g[G.bellLevel.rawValue] = 1
        g[G.melodyBus.rawValue] = 0.55
        g[G.droneOut.rawValue] = 0.65
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    deinit {
        [nTrig, nType, nFreq, nAmp, nPan, nDecay, nAtk, nBright, nCoef, g].forEach { $0.deallocate() }
    }
}

/// Bell Weather's sound, rendered natively:
///  • a six-layer "blend" drone (sine morphing toward a slowly beating saw) at sub-octaves,
///    root, octaves and a 2.76× bell partial, each with its own swell and pan drift,
///    through a resonant lowpass with a slow filter LFO;
///  • wind (pink noise in a wandering band, gusts with a whistle and a short echo);
///  • rain hiss or snow hush;
///  • the hourly bell (six inharmonic partials);
///  • melody voices: FM glass bell, Karplus-Strong string, kalimba.
final class BellDSP {
    private let sr: Float
    private let p: BellParams
    private var rng: UInt32 = 0x9E37_79B9

    // Sine table
    private static let tableSize = 4096
    private let sine: UnsafeMutablePointer<Float>

    // Drone
    private let ratios: [Float] = [0.25, 0.5, 1, 2, 4, 2.76]
    private let swellRate: [Float] = [0.009, 0.013, 0.017, 0.021, 0.026, 0.031]
    private let swellDepth: [Float] = [0.10, 0.10, 0.075, 0.125, 0.15, 0.10]
    private let basePan: [Float] = [0, 0, 0, -0.45, 0.5, 0.3]
    private let sinPh: UnsafeMutablePointer<Float>
    private let sawPh: UnsafeMutablePointer<Float>
    private let swPh: UnsafeMutablePointer<Float>
    private let panPh: UnsafeMutablePointer<Float>
    private let panRate: UnsafeMutablePointer<Float>
    private let lvl: UnsafeMutablePointer<Float>
    private var hz: Float = 65.4, tA: Float = 0.25, tB: Float = 0.35, spread: Float = 1
    private var cut: Float = 1400, q: Float = 0.9, flfoPh: Float = 0
    private var fL1: Float = 0, fL2: Float = 0, fR1: Float = 0, fR2: Float = 0
    private var droneOut: Float = 0.65

    // Wind
    private let pinkW: UnsafeMutablePointer<Float>
    private var wbp: Float = 400, w1: Float = 0, w2: Float = 0
    private var gust: Float = 0, whLP: Float = 0
    private var windGain: Float = 0
    private let echo: UnsafeMutablePointer<Float>
    private let echoLen: Int
    private var echoIdx = 0

    // Precipitation
    private let pinkL: UnsafeMutablePointer<Float>
    private let pinkR: UnsafeMutablePointer<Float>
    private var rL1: Float = 0, rL2: Float = 0, rR1: Float = 0, rR2: Float = 0
    private var sL1: Float = 0, sL2: Float = 0, sR1: Float = 0, sR2: Float = 0
    private var rainG: Float = 0, snowG: Float = 0

    // Hourly bell
    private let bellRatio: [Float] = [0.5, 1, 1.19, 1.5, 2, 4.05]
    private let bellPeak: [Float] = [0.4, 0.5, 0.3, 0.25, 0.3, 0.35]
    private let bellDecay: [Float] = [8, 6, 4, 3, 2.5, 0.4]
    private let bPh: UnsafeMutablePointer<Float>
    private let bEnv: UnsafeMutablePointer<Float>
    private let bTgt: UnsafeMutablePointer<Float>
    private let bMul: UnsafeMutablePointer<Float>
    private let bAge: UnsafeMutablePointer<Float>
    private var bInc: Float = 0
    private var lastBell: Float = 0
    private var bellOn = false

    // Melody voices (per-voice scalars in strided blocks)
    private enum VS: Int, CaseIterable {
        case on, type, age, amp, env, atkSamp, aMul, idx, iMul, iEndAge
        case phC, phM, incC, incM, gl, gr, life, fade
        case k1, k2, k3, kM1, kM2, kM3, kPh1, kPh2, kPh3     // kalimba partials
        case lenA, lenB, gA, gB, lpA, lpB, coef               // string
        case lastTrig
    }
    private let vs: UnsafeMutablePointer<Float>
    private static let ksCap = 4096
    private let ksA: UnsafeMutablePointer<Float>
    private let ksB: UnsafeMutablePointer<Float>
    private let ksW: UnsafeMutablePointer<Int>

    private var master: Float = 0

    init(sampleRate: Float, params: BellParams) {
        sr = sampleRate
        p = params
        func make(_ v: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let q = UnsafeMutablePointer<Float>.allocate(capacity: n)
            q.initialize(repeating: v, count: n)
            return q
        }
        let n = BellDSP.tableSize
        sine = make(0, n + 1)
        for i in 0...n { sine[i] = sinf(2 * Float.pi * Float(i) / Float(n)) }

        let L = BellParams.layers
        sinPh = make(0, L); sawPh = make(0, L); swPh = make(0, L); panPh = make(0, L)
        panRate = make(0.02, L); lvl = make(0, L)
        var seed: UInt32 = 0x1234_5678
        func r01() -> Float { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Float(seed >> 8) / 16_777_216 }
        for i in 0..<L {
            swPh[i] = r01(); panPh[i] = r01(); sawPh[i] = r01()
            panRate[i] = 0.011 + r01() * 0.02
        }

        pinkW = make(0, 7); pinkL = make(0, 7); pinkR = make(0, 7)
        echoLen = max(1, Int(0.42 * sampleRate))
        echo = make(0, echoLen)

        let B = bellRatio.count
        bPh = make(0, B); bEnv = make(0, B); bTgt = make(0, B); bMul = make(1, B); bAge = make(0, B)

        let V = BellParams.voices
        vs = make(0, VS.allCases.count * V)
        ksA = make(0, BellDSP.ksCap * V)
        ksB = make(0, BellDSP.ksCap * V)
        ksW = UnsafeMutablePointer<Int>.allocate(capacity: V)
        ksW.initialize(repeating: 0, count: V)
    }

    deinit {
        [sine, sinPh, sawPh, swPh, panPh, panRate, lvl, pinkW, pinkL, pinkR, echo,
         bPh, bEnv, bTgt, bMul, bAge, vs, ksA, ksB].forEach { $0.deallocate() }
        ksW.deallocate()
    }

    // MARK: Helpers

    @inline(__always) private func sn(_ ph: Float) -> Float {
        let x = ph * Float(BellDSP.tableSize)
        let i = min(max(Int(x), 0), BellDSP.tableSize - 1)
        let f = x - Float(i)
        return sine[i] + (sine[i + 1] - sine[i]) * f
    }

    @inline(__always) private func wrap(_ x: Float) -> Float { x - floorf(x) }

    @inline(__always) private func white() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng >> 8) / 8_388_608 - 1
    }

    /// Paul Kellet's refined pink-noise filter (state in a 7-float block).
    @inline(__always) private func pink(_ b: UnsafeMutablePointer<Float>) -> Float {
        let w = white()
        b[0] = 0.99886 * b[0] + w * 0.0555179
        b[1] = 0.99332 * b[1] + w * 0.0750759
        b[2] = 0.96900 * b[2] + w * 0.1538520
        b[3] = 0.86650 * b[3] + w * 0.3104856
        b[4] = 0.55000 * b[4] + w * 0.5329522
        b[5] = -0.7616 * b[5] - w * 0.0168980
        let out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
        b[6] = w * 0.115926
        return out * 0.11
    }

    @inline(__always) private func polyBlep(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    /// TPT state-variable filter coefficients for cutoff fc and damping k (= 1/Q).
    @inline(__always) private func svf(_ fc: Float, _ k: Float) -> (Float, Float, Float) {
        let g = tanf(Float.pi * min(max(fc, 20), sr * 0.45) / sr)
        let a1 = 1 / (1 + g * (g + k))
        return (a1, g * a1, g * g * a1)
    }

    // MARK: Note-on

    private func startVoice(_ v: Int) {
        let V = BellParams.voices
        func set(_ k: VS, _ x: Float) { vs[k.rawValue * V + v] = x }
        let type = p.nType[v]
        let f = max(20, p.nFreq[v])
        let decay = max(0.1, p.nDecay[v])
        let atk = max(0, p.nAtk[v])
        let ang = (max(-1, min(1, p.nPan[v])) + 1) * Float.pi / 4
        set(.on, 1); set(.type, type); set(.age, 0); set(.amp, p.nAmp[v]); set(.env, 0)
        set(.gl, cosf(ang)); set(.gr, sinf(ang)); set(.phC, 0); set(.phM, 0)

        if type < 0.5 {
            // FM glass bell: carrier f, modulator 3.51 f; index falls from (1.2 + 2·bright)
            // to 0.2/3.51 over 0.7·decay; amplitude falls to −80 dB over 1.2·decay.
            let i0 = 1.2 + 2 * p.nBright[v]
            let i1: Float = 0.2 / 3.51
            let tI = 0.7 * decay * sr
            set(.atkSamp, (atk + 0.003) * sr)
            set(.aMul, powf(0.0001, 1 / (1.2 * decay * sr)))
            set(.idx, i0); set(.iMul, powf(i1 / i0, 1 / tI)); set(.iEndAge, tI)
            set(.incC, f / sr); set(.incM, 3.51 * f / sr)
            set(.life, (atk + 1.2 * decay + 0.1) * sr)
        } else if type < 1.5 {
            // Karplus-Strong: two strings (f and 1.003 f), noise burst through a one-pole
            // lowpass set by brightness, loop filter coef, −60 dB after `decay` seconds.
            let coef = max(0, min(0.9, p.nCoef[v]))
            let bright = max(0.05, min(1, p.nBright[v]))
            let norm = 0.6 / sqrtf(bright + 0.05)
            let base = v * BellDSP.ksCap
            func lenFor(_ freq: Float) -> Float {
                min(Float(BellDSP.ksCap - 4), max(2, sr / freq - coef / (1 - coef)))
            }
            let la = lenFor(f), lb = lenFor(f * 1.003)
            var lp: Float = 0
            for i in 0..<BellDSP.ksCap {
                lp += (white() - lp) * bright
                ksA[base + i] = lp * norm
            }
            lp = 0
            for i in 0..<BellDSP.ksCap {
                lp += (white() - lp) * bright
                ksB[base + i] = lp * norm
            }
            ksW[v] = Int(max(la, lb)) + 2
            set(.lenA, la); set(.lenB, lb)
            set(.gA, powf(0.001, 1 / (decay * f)))
            set(.gB, powf(0.001, 1 / (decay * 0.92 * f * 1.003)))
            set(.lpA, 0); set(.lpB, 0); set(.coef, coef)
            set(.atkSamp, (atk + 0.004) * sr)
            let life = min(9, max(0.3, 1.15 * decay))
            set(.life, life * sr); set(.fade, 0.06 * sr)
        } else {
            // Kalimba: three partials (1, 3.93, 9.2) with their own decays.
            set(.atkSamp, (0.003 + 0.4 * atk) * sr)
            set(.kM1, powf(0.0001, 1 / ((decay * 1.0 * 1.1 + 0.05) * sr)))
            set(.kM2, powf(0.0001, 1 / ((decay * 0.3 * 1.1 + 0.05) * sr)))
            set(.kM3, powf(0.0001, 1 / ((decay * 0.08 * 1.1 + 0.05) * sr)))
            set(.k1, 1); set(.k2, 0.35); set(.k3, 0.1)
            set(.kPh1, 0); set(.kPh2, 0); set(.kPh3, 0)
            set(.incC, f / sr)
            set(.life, (decay * 1.1 + 0.3) * sr)
        }
    }

    // MARK: Render

    func render(frames n: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard n > 0 else { return }
        L.update(repeating: 0, count: n)
        R.update(repeating: 0, count: n)
        let bt = Float(n) / sr
        let twoPi = 2 * Float.pi
        func k(_ tau: Float) -> Float { 1 - expf(-bt / tau) }

        // ---------- smoothed globals ----------
        hz += (p[.droneHz] - hz) * k(0.05)
        tA += (p[.timbreA] - tA) * k(1.5)
        tB += (p[.timbreB] - tB) * k(1.5)
        spread += (p[.spread] - spread) * k(1.5)
        cut += (p[.cutoff] - cut) * k(1.5)
        q += (p[.q] - q) * k(1.5)
        droneOut += (p[.droneOut] - droneOut) * k(1)
        let kl = k(4)
        for i in 0..<BellParams.layers {
            if let key = BellParams.G(rawValue: BellParams.G.lvl0.rawValue + i) {
                lvl[i] += (p[key] - lvl[i]) * kl
            }
        }

        // ---------- drone ----------
        flfoPh = wrap(flfoPh + p[.flfoRate] * bt)
        let fc = max(20, cut + p[.flfoDepth] * sn(flfoPh))
        let (a1, a2, a3) = svf(fc, 1 / max(0.5, q))
        let sineG = 1 - 0.9 * tA, sawG = 0.9 * tA
        let beat = min(max(tB * spread, 0), 1.6) * 0.3 + 0.02
        let swellMult = p[.swellMult]

        for li in 0..<BellParams.layers {
            let f = hz * ratios[li]
            guard f < sr * 0.45 else { continue }
            swPh[li] = wrap(swPh[li] + swellRate[li] * swellMult * bt)
            panPh[li] = wrap(panPh[li] + panRate[li] * bt)
            let swell = 0.9 + swellDepth[li] * sn(swPh[li])
            let panAmt: Float = basePan[li] == 0 ? 0.12 : 0.18
            let pan = max(-1, min(1, basePan[li] + panAmt * sn(panPh[li])))
            let ang = (pan + 1) * Float.pi / 4
            let g = lvl[li] * swell * 1.25
            let gl = g * cosf(ang), gr = g * sinf(ang)
            let incS = f / sr
            let isBell = li == 5
            let incW = (f + beat) / sr
            var ps = sinPh[li], pw = sawPh[li]
            for i in 0..<n {
                var x = sn(ps)
                ps += incS; if ps >= 1 { ps -= 1 }
                if !isBell {
                    let saw = 2 * pw - 1 - polyBlep(pw, incW)
                    pw += incW; if pw >= 1 { pw -= 1 }
                    x = x * sineG + saw * sawG
                }
                L[i] += x * gl
                R[i] += x * gr
            }
            sinPh[li] = ps; sawPh[li] = pw
        }
        // Resonant lowpass on the drone bus, then its level
        var l1 = fL1, l2 = fL2, r1 = fR1, r2 = fR2
        for i in 0..<n {
            var v3 = L[i] - l2
            var v1 = a1 * l1 + a2 * v3
            var v2 = l2 + a2 * l1 + a3 * v3
            l1 = 2 * v1 - l1; l2 = 2 * v2 - l2
            L[i] = v2 * droneOut
            v3 = R[i] - r2
            v1 = a1 * r1 + a2 * v3
            v2 = r2 + a2 * r1 + a3 * v3
            r1 = 2 * v1 - r1; r2 = 2 * v2 - r2
            R[i] = v2 * droneOut
        }
        fL1 = abs(l1) < 1e-15 ? 0 : l1; fL2 = abs(l2) < 1e-15 ? 0 : l2
        fR1 = abs(r1) < 1e-15 ? 0 : r1; fR2 = abs(r2) < 1e-15 ? 0 : r2

        // ---------- wind ----------
        wbp += (p[.windBP] - wbp) * k(0.25)
        let gust0 = gust
        gust += (p[.windGust] - gust) * k(0.05)
        let wg0 = windGain
        windGain += (p[.windGain] - windGain) * k(0.8)
        let (wa1, wa2, wa3) = svf(wbp, 1 / 1.3)
        let hpA = 1 - expf(-twoPi * 2500 / sr)
        let gInc = (gust - gust0) / Float(n), wInc = (windGain - wg0) / Float(n)
        var gu = gust0, wgn = wg0
        if windGain > 1e-5 || wg0 > 1e-5 {
            for i in 0..<n {
                let x = pink(pinkW)
                let v3 = x - w2
                let v1 = wa1 * w1 + wa2 * v3
                let v2 = w2 + wa2 * w1 + wa3 * v3
                w1 = 2 * v1 - w1; w2 = 2 * v2 - w2
                let wn = white()
                whLP += (wn - whLP) * hpA
                gu += gInc
                let s = v1 + (wn - whLP) * gu * 0.5
                let d = echo[echoIdx]
                echo[echoIdx] = s + d * 0.45
                echoIdx += 1; if echoIdx >= echoLen { echoIdx = 0 }
                wgn += wInc
                let y = (s + d * 0.5) * wgn
                L[i] += y
                R[i] += y
            }
            if abs(w1) < 1e-15 { w1 = 0 }; if abs(w2) < 1e-15 { w2 = 0 }
        }

        // ---------- rain / snow ----------
        let rg0 = rainG, sg0 = snowG
        rainG += (p[.rainGain] - rainG) * k(2)
        snowG += (p[.snowGain] - snowG) * k(2)
        if rainG > 1e-5 || snowG > 1e-5 || rg0 > 1e-5 || sg0 > 1e-5 {
            let (ra1, ra2, ra3) = svf(2600, 1 / 0.5)
            let (sa1, sa2, sa3) = svf(850, 1.414)
            let rInc = (rainG - rg0) / Float(n), sInc = (snowG - sg0) / Float(n)
            var rgn = rg0, sgn = sg0
            for i in 0..<n {
                let xl = pink(pinkL), xr = pink(pinkR)
                rgn += rInc; sgn += sInc
                // rain: bandpass
                var v3 = xl - rL2
                var v1 = ra1 * rL1 + ra2 * v3
                var v2 = rL2 + ra2 * rL1 + ra3 * v3
                rL1 = 2 * v1 - rL1; rL2 = 2 * v2 - rL2
                let rl = v1
                v3 = xr - rR2
                v1 = ra1 * rR1 + ra2 * v3
                v2 = rR2 + ra2 * rR1 + ra3 * v3
                rR1 = 2 * v1 - rR1; rR2 = 2 * v2 - rR2
                let rr = v1
                // snow: lowpass
                v3 = xl - sL2
                v1 = sa1 * sL1 + sa2 * v3
                v2 = sL2 + sa2 * sL1 + sa3 * v3
                sL1 = 2 * v1 - sL1; sL2 = 2 * v2 - sL2
                let sl = v2
                v3 = xr - sR2
                v1 = sa1 * sR1 + sa2 * v3
                v2 = sR2 + sa2 * sR1 + sa3 * v3
                sR1 = 2 * v1 - sR1; sR2 = 2 * v2 - sR2
                let srr = v2
                L[i] += rl * rgn + sl * sgn
                R[i] += rr * rgn + srr * sgn
            }
        }

        // ---------- hourly bell ----------
        if p[.bellTrig] != lastBell {
            lastBell = p[.bellTrig]
            bInc = max(20, p[.bellF]) / sr
            let day = max(0, min(1, p[.bellDay]))
            for j in 0..<bellRatio.count {
                let peak = j == 5 ? 0.35 * (0.5 + 0.5 * day) : bellPeak[j]
                bTgt[j] = peak
                bEnv[j] = 0
                bAge[j] = 0
                bPh[j] = 0
                bMul[j] = powf(0.0001 / max(peak, 0.0002), 1 / (max(0.05, bellDecay[j] - 0.004) * sr))
            }
            bellOn = true
        }
        if bellOn {
            let atk = 0.004 * sr
            let g = 0.5 * p[.bellLevel]
            var any = false
            for j in 0..<bellRatio.count {
                var env = bEnv[j], age = bAge[j], ph = bPh[j]
                let tgt = bTgt[j], mul = bMul[j]
                let inc = bInc * bellRatio[j]
                guard inc < 0.45 else { continue }
                if age > atk && env < 1e-4 { continue }
                any = true
                for i in 0..<n {
                    if age < atk { env = tgt * age / atk } else { env *= mul }
                    age += 1
                    let y = sn(ph) * env * g
                    ph += inc; if ph >= 1 { ph -= 1 }
                    L[i] += y; R[i] += y
                }
                bEnv[j] = env; bAge[j] = age; bPh[j] = ph
            }
            bellOn = any
        }

        // ---------- melody ----------
        let V = BellParams.voices
        let bus = p[.melodyBus]
        for v in 0..<V {
            func at(_ key: VS) -> Int { key.rawValue * V + v }
            if p.nTrig[v] != vs[at(.lastTrig)] {
                vs[at(.lastTrig)] = p.nTrig[v]
                startVoice(v)
            }
            guard vs[at(.on)] > 0.5 else { continue }
            let type = vs[at(.type)]
            var age = vs[at(.age)]
            let amp = vs[at(.amp)] * bus
            let gl = vs[at(.gl)], gr = vs[at(.gr)]
            let atkS = max(1, vs[at(.atkSamp)])
            let life = vs[at(.life)]
            var env = vs[at(.env)]

            if type < 0.5 {
                var idx = vs[at(.idx)]
                let iMul = vs[at(.iMul)], iEnd = vs[at(.iEndAge)], aMul = vs[at(.aMul)]
                var pc = vs[at(.phC)], pm = vs[at(.phM)]
                let ic = vs[at(.incC)], im = vs[at(.incM)]
                for i in 0..<n {
                    if age < atkS { env = age / atkS } else { env *= aMul }
                    if age < iEnd { idx *= iMul }
                    age += 1
                    let y = sinf(twoPi * pc + idx * sn(pm)) * env * amp
                    pc += ic; if pc >= 1 { pc -= 1 }
                    pm += im; if pm >= 1 { pm -= 1 }
                    L[i] += y * gl; R[i] += y * gr
                }
                vs[at(.idx)] = idx; vs[at(.phC)] = pc; vs[at(.phM)] = pm
                if age > atkS && env < 1e-4 { vs[at(.on)] = 0 }
            } else if type < 1.5 {
                let base = v * BellDSP.ksCap
                let cap = BellDSP.ksCap
                let la = vs[at(.lenA)], lb = vs[at(.lenB)]
                let ga = vs[at(.gA)], gb = vs[at(.gB)]
                let coef = vs[at(.coef)]
                var lpa = vs[at(.lpA)], lpb = vs[at(.lpB)]
                var w = ksW[v]
                let fade = max(1, vs[at(.fade)])
                for i in 0..<n {
                    // Fractional read L samples behind the write head (linear interpolation)
                    var ra = Float(w) - la; if ra < 0 { ra += Float(cap) }
                    let ia = Int(ra) % cap, fa = ra - floorf(ra)
                    let ya = ksA[base + ia] + (ksA[base + (ia + 1) % cap] - ksA[base + ia]) * fa
                    var rb = Float(w) - lb; if rb < 0 { rb += Float(cap) }
                    let ib = Int(rb) % cap, fb = rb - floorf(rb)
                    let yb = ksB[base + ib] + (ksB[base + (ib + 1) % cap] - ksB[base + ib]) * fb
                    lpa = (1 - coef) * ya + coef * lpa
                    lpb = (1 - coef) * yb + coef * lpb
                    ksA[base + w] = lpa * ga
                    ksB[base + w] = lpb * gb
                    w += 1; if w >= cap { w = 0 }
                    env = age < atkS ? age / atkS : 1
                    if age > life - fade { env *= max(0, (life - age) / fade) }
                    age += 1
                    let y = (ya * 0.7 + yb * 0.5) * env * amp
                    L[i] += y * gl; R[i] += y * gr
                }
                ksW[v] = w
                vs[at(.lpA)] = lpa; vs[at(.lpB)] = lpb
                if age >= life { vs[at(.on)] = 0 }
            } else {
                var k1 = vs[at(.k1)], k2 = vs[at(.k2)], k3 = vs[at(.k3)]
                let m1 = vs[at(.kM1)], m2 = vs[at(.kM2)], m3 = vs[at(.kM3)]
                var p1 = vs[at(.kPh1)], p2 = vs[at(.kPh2)], p3 = vs[at(.kPh3)]
                let inc = vs[at(.incC)]
                let i2 = inc * 3.93, i3 = inc * 9.2
                for i in 0..<n {
                    env = age < atkS ? age / atkS : 1
                    age += 1
                    var x = sn(p1) * k1
                    if i2 < 0.45 { x += sn(p2) * k2 }
                    if i3 < 0.45 { x += sn(p3) * k3 }
                    if age > atkS { k1 *= m1; k2 *= m2; k3 *= m3 }
                    p1 += inc; if p1 >= 1 { p1 -= 1 }
                    p2 = wrap(p2 + i2); p3 = wrap(p3 + i3)
                    let y = x * env * amp * 0.69
                    L[i] += y * gl; R[i] += y * gr
                }
                vs[at(.k1)] = k1; vs[at(.k2)] = k2; vs[at(.k3)] = k3
                vs[at(.kPh1)] = p1; vs[at(.kPh2)] = p2; vs[at(.kPh3)] = p3
                if age > atkS && k1 < 1e-4 { vs[at(.on)] = 0 }
            }
            vs[at(.age)] = age
            vs[at(.env)] = env
            if age >= life + sr { vs[at(.on)] = 0 }
        }

        // ---------- master ----------
        let m0 = master
        master += (p[.master] - master) * k(0.8)
        let mInc = (master - m0) / Float(n)
        var m = m0
        for i in 0..<n {
            m += mInc
            L[i] = tanhf(L[i] * m)
            R[i] = tanhf(R[i] * m)
        }
    }
}
