import Foundation

/// Control surface shared between the main thread (writer) and the audio thread (reader).
/// Plain aligned Float stores; no locks, no allocation on the audio thread.
final class DroneParams {
    /// Device slots: how many emitters can sing at once.
    static let voiceCount = 32
    /// Shared pool of note voices. Notes take the least-recently-used voice, so long
    /// tails overlap freely; at full density a voice is reused only after ~15 s.
    static let noteVoices = 64
    static let bedVoices = 4

    enum G: Int, CaseIterable {
        case master, bedAmp, bedCut
        case response      // lag scale: 1 = drift (default), 0.03 = snap
    }

    // Note voices — written at note-on (freq…pan, trig) or continuously (live, wow)
    let nFreq: UnsafeMutablePointer<Float>
    let nVel: UnsafeMutablePointer<Float>
    let nBright: UnsafeMutablePointer<Float>
    let nDur: UnsafeMutablePointer<Float>     // seconds held before release
    let nPan: UnsafeMutablePointer<Float>
    let nTrig: UnsafeMutablePointer<Float>    // counter; a change = note-on
    let nLive: UnsafeMutablePointer<Float>    // live gain from the device's current strength
    let nWow: UnsafeMutablePointer<Float>     // tape wow depth in cents (from jitter)

    // Pad bed
    let bFreq: UnsafeMutablePointer<Float>

    private let g: UnsafeMutablePointer<Float>

    init() {
        func make(_ value: Float, _ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: value, count: n)
            return p
        }
        let nv = DroneParams.noteVoices
        nFreq = make(440, nv); nVel = make(0, nv); nBright = make(0.5, nv); nDur = make(4, nv)
        nPan = make(0, nv); nTrig = make(0, nv); nLive = make(1, nv); nWow = make(0, nv)
        bFreq = make(146.8, DroneParams.bedVoices)
        g = make(0, G.allCases.count)
        g[G.response.rawValue] = 1
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    deinit {
        [nFreq, nVel, nBright, nDur, nPan, nTrig, nLive, nWow, bFreq, g].forEach { $0.deallocate() }
    }
}

/// Two layers:
///  • Note voices — soft, glassy tones (fundamental + chorused twin + gentle overtones) with
///    slow swells, long releases and tape-style pitch wow. These carry the melody.
///  • Pad bed — four warm, filtered saw pairs gliding slowly between chords.
final class DroneDSP {
    private let sr: Float
    private let p: DroneParams
    private let nv = DroneParams.noteVoices
    private let nb = DroneParams.bedVoices

    // Note voice state (S = per-voice scalar slots, stored as nv-strided blocks)
    private enum NS: Int, CaseIterable {
        case ph1, ph2, ph3, ph4, wowPh, env, stage, hold, lastTrig
        case freq, vel, bright, gl, gr, live, wow
        case pFreq, pVel, pBright, pGl, pGr, pHold      // note waiting for a stolen voice to fade
    }
    private let ns: UnsafeMutablePointer<Float>

    // Bed state
    private enum BS: Int, CaseIterable {
        case phA, phB, freq, ic1, ic2, lfo
    }
    private let bs: UnsafeMutablePointer<Float>

    private var master: Float = 0
    private var bedAmp: Float = 0
    private var bedCut: Float = 400

    private let releaseCoef: Float
    private let stealCoef: Float

    /// 4096-point sine table (+1 guard); a lookup is several times cheaper than sinf,
    /// which matters with up to 64 voices × 5 oscillators.
    private let sine: UnsafeMutablePointer<Float>
    private static let tableSize = 4096

    init(sampleRate: Float, params: DroneParams) {
        sr = sampleRate
        p = params
        let nvCount = DroneParams.noteVoices
        let nbCount = DroneParams.bedVoices
        ns = UnsafeMutablePointer<Float>.allocate(capacity: NS.allCases.count * nvCount)
        ns.initialize(repeating: 0, count: NS.allCases.count * nvCount)
        bs = UnsafeMutablePointer<Float>.allocate(capacity: BS.allCases.count * nbCount)
        bs.initialize(repeating: 0, count: BS.allCases.count * nbCount)
        for b in 0..<nbCount {
            bs[BS.freq.rawValue * nbCount + b] = 146.8
            bs[BS.phB.rawValue * nbCount + b] = 0.31 * Float(b + 1)
            bs[BS.lfo.rawValue * nbCount + b] = 0.23 * Float(b)
        }
        for v in 0..<nvCount { ns[NS.wowPh.rawValue * nvCount + v] = 0.17 * Float(v) }
        // Release: τ = 3 s (≈ 20 s tail). Attack is set per block from the Response control.
        releaseCoef = expf(-1 / (3.0 * sampleRate))
        stealCoef = expf(-1 / (0.012 * sampleRate))       // ~12 ms fade when a voice is reused
        let n = DroneDSP.tableSize
        sine = UnsafeMutablePointer<Float>.allocate(capacity: n + 1)
        for i in 0...n { sine[i] = sinf(2 * Float.pi * Float(i) / Float(n)) }
    }

    deinit {
        ns.deallocate()
        bs.deallocate()
        sine.deallocate()
    }

    /// sin(2π·ph) for ph in [0, 1), by linear interpolation in the table.
    @inline(__always) private func sn(_ ph: Float) -> Float {
        let x = ph * Float(DroneDSP.tableSize)
        let i = min(max(Int(x), 0), DroneDSP.tableSize - 1)
        let f = x - Float(i)
        let a = sine[i]
        return a + (sine[i + 1] - a) * f
    }

    @inline(__always) private func polyBlep(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    func render(frames: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        L.update(repeating: 0, count: frames)
        R.update(repeating: 0, count: frames)

        let blockT = Float(frames) / sr
        let invN = 1 / Float(frames)
        // Response scales every expressive time constant (not the tails or the chord glide).
        let lag = max(0.02, min(1.5, p[.response]))
        let kLive = 1 - expf(-blockT / (1.5 * lag))
        let kWow = 1 - expf(-blockT / (1.0 * lag))
        // Attack: one-pole toward 1.3, reaching 1 in ~2.4 s at drift, ~70 ms at snap.
        let attackCoef = 1 - expf(-1 / (1.6 * lag * sr))

        // ---------- Note voices (the melody) ----------
        for v in 0..<nv {
            func at(_ k: NS) -> Int { k.rawValue * nv + v }

            // Note-on? If the voice is still ringing, park the note and fade the old one
            // out quickly (stage 4) so the new pitch never jumps onto an audible tail.
            if p.nTrig[v] != ns[at(.lastTrig)] {
                ns[at(.lastTrig)] = p.nTrig[v]
                let ang = (p.nPan[v] + 1) * Float.pi / 4
                ns[at(.pFreq)] = p.nFreq[v]
                ns[at(.pVel)] = p.nVel[v]
                ns[at(.pBright)] = p.nBright[v]
                ns[at(.pHold)] = p.nDur[v] * sr
                ns[at(.pGl)] = cosf(ang); ns[at(.pGr)] = sinf(ang)
                ns[at(.stage)] = (ns[at(.stage)] != 0 && ns[at(.env)] > 1e-3) ? 4 : 5
            }
            if ns[at(.stage)] == 5 {
                // Load the parked note and begin its swell.
                ns[at(.freq)] = ns[at(.pFreq)]
                ns[at(.vel)] = ns[at(.pVel)]
                ns[at(.bright)] = ns[at(.pBright)]
                ns[at(.hold)] = ns[at(.pHold)]
                ns[at(.gl)] = ns[at(.pGl)]; ns[at(.gr)] = ns[at(.pGr)]
                ns[at(.live)] = p.nLive[v]
                ns[at(.wow)] = p.nWow[v]
                ns[at(.env)] = 0
                ns[at(.stage)] = 1
            }
            var stage = ns[at(.stage)]
            if stage == 0 { continue }

            let live0 = ns[at(.live)]
            let live1 = live0 + (p.nLive[v] - live0) * kLive
            ns[at(.live)] = live1
            let wow = ns[at(.wow)] + (p.nWow[v] - ns[at(.wow)]) * kWow
            ns[at(.wow)] = wow

            let f = ns[at(.freq)]
            let b = ns[at(.bright)]
            let vel = ns[at(.vel)]
            let gl = ns[at(.gl)], gr = ns[at(.gr)]
            let inc1 = f / sr
            let inc4 = f * 1.0041 / sr          // ~7 cents above: slow chorus beating
            let a2 = 0.28 * b, a3 = 0.10 * b * b
            let wowDepth = wow * 0.000578        // cents → frequency ratio
            let wowInc: Float = 0.45 / sr

            var ph1 = ns[at(.ph1)], ph2 = ns[at(.ph2)], ph3 = ns[at(.ph3)], ph4 = ns[at(.ph4)]
            var wph = ns[at(.wowPh)]
            var env = ns[at(.env)]
            var hold = ns[at(.hold)]
            var live = live0
            let liveInc = (live1 - live0) * invN

            for i in 0..<frames {
                // Envelope: 1 attack → 2 hold → 3 release → 0 idle
                if stage == 1 {
                    env += (1.3 - env) * attackCoef
                    if env >= 1 { env = 1; stage = 2 }
                } else if stage == 2 {
                    hold -= 1
                    if hold <= 0 { stage = 3 }
                } else if stage == 3 {
                    env *= releaseCoef
                    if env < 1e-4 { env = 0; stage = 0; break }
                } else if stage == 4 {
                    env *= stealCoef
                    if env < 1e-4 { env = 0; stage = 5; break }   // next block loads the parked note
                }

                let w = 1 + wowDepth * sn(wph)
                wph += wowInc; if wph >= 1 { wph -= 1 }

                let x = sn(ph1) + 0.55 * sn(ph4) + a2 * sn(ph2) + a3 * sn(ph3)
                ph1 += inc1 * w; if ph1 >= 1 { ph1 -= 1 }
                ph4 += inc4 * w; if ph4 >= 1 { ph4 -= 1 }
                ph2 += 2 * inc1 * w; if ph2 >= 1 { ph2 -= 1 }
                ph3 += 3 * inc1 * w; if ph3 >= 1 { ph3 -= 1 }

                live += liveInc
                let y = x * env * vel * live * 0.07
                L[i] += y * gl
                R[i] += y * gr
            }

            ns[at(.ph1)] = ph1; ns[at(.ph2)] = ph2; ns[at(.ph3)] = ph3; ns[at(.ph4)] = ph4
            ns[at(.wowPh)] = wph
            ns[at(.env)] = env
            ns[at(.hold)] = hold
            ns[at(.stage)] = stage
        }

        // ---------- Pad bed ----------
        let bedA0 = bedAmp
        bedAmp += (p[.bedAmp] - bedAmp) * (1 - expf(-blockT / (3 * lag)))
        let bedAInc = (bedAmp - bedA0) * invN
        let cutTarget = 160 * powf(9, max(0, min(1, p[.bedCut])))
        bedCut += (cutTarget - bedCut) * (1 - expf(-blockT / (2 * lag)))
        let gq = tanf(Float.pi * min(bedCut, sr * 0.45) / sr)
        let k: Float = 1.1
        let c1 = 1 / (1 + gq * (gq + k)), c2 = gq * c1, c3 = gq * c2
        let kGlide = 1 - expf(-blockT / 4)

        for bv in 0..<nb {
            func at(_ k: BS) -> Int { k.rawValue * nb + bv }
            bs[at(.freq)] += (p.bFreq[bv] - bs[at(.freq)]) * kGlide
            let f = bs[at(.freq)]
            let dtA = f * 0.9965 / sr, dtB = f * 1.0035 / sr
            let lfoInc = (0.03 + 0.017 * Float(bv)) / sr
            let pan = -0.6 + 0.4 * Float(bv)            // spread −0.6 … +0.6
            let ang = (pan + 1) * Float.pi / 4
            let gl = cosf(ang), gr = sinf(ang)

            var pa = bs[at(.phA)], pb = bs[at(.phB)], lfo = bs[at(.lfo)]
            var s1 = bs[at(.ic1)], s2 = bs[at(.ic2)]
            var amp = bedA0

            for i in 0..<frames {
                let x = (2 * pa - 1 - polyBlep(pa, dtA)) + (2 * pb - 1 - polyBlep(pb, dtB))
                pa += dtA; if pa >= 1 { pa -= 1 }
                pb += dtB; if pb >= 1 { pb -= 1 }
                let v3 = x - s2
                let v1 = c1 * s1 + c2 * v3
                let v2 = s2 + c2 * s1 + c3 * v3
                s1 = 2 * v1 - s1
                s2 = 2 * v2 - s2
                let breathe = 0.55 + 0.45 * sn(lfo)
                lfo += lfoInc; if lfo >= 1 { lfo -= 1 }
                amp += bedAInc
                let y = v2 * amp * breathe * 0.045
                L[i] += y * gl
                R[i] += y * gr
            }
            if abs(s1) < 1e-15 { s1 = 0 }
            if abs(s2) < 1e-15 { s2 = 0 }
            bs[at(.phA)] = pa; bs[at(.phB)] = pb; bs[at(.lfo)] = lfo
            bs[at(.ic1)] = s1; bs[at(.ic2)] = s2
        }

        // ---------- Master ----------
        let m0 = master
        master += (p[.master] - master) * (1 - expf(-blockT / 0.6))
        var m = m0
        let mInc = (master - m0) * invN
        for i in 0..<frames {
            m += mInc
            L[i] = tanhf(L[i] * m)
            R[i] = tanhf(R[i] * m)
        }
    }
}
