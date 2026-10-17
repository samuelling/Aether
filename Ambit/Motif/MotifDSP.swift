import Foundation

/// Control surface shared between the main thread and the audio thread, in the same style as
/// Aether's `DroneParams`: plain aligned stores, no locks, no allocation on the audio thread.
///
/// Notes travel in two rings, each scheduled on a beat clock that the audio thread owns, so
/// they land on the grid sample-accurately however late the main thread runs (it may be in
/// the background behind another app). The main thread *stages* a note into a slot and
/// *publishes* it on its next tick, so the audio thread never sees a slot half-written.
final class MotifParams {
    static let ring = 64

    enum G: Int, CaseIterable {
        case master, bpm
        case bright         // 0…1  download level: the felt opens up, the piano gets brighter
        case breath         // 0…1  upload level: more tape hiss and crackle
        case whisperGain
    }

    // Lead ring: the melody, one note at a time, played legato
    let lBeat: UnsafeMutablePointer<Double>
    let lFreq: UnsafeMutablePointer<Float>
    let lVel: UnsafeMutablePointer<Float>
    let lDur: UnsafeMutablePointer<Float>       // beats the note is held
    let lPan: UnsafeMutablePointer<Float>
    // Whisper ring: tiny high blips for trackers
    let wBeat: UnsafeMutablePointer<Double>
    let wFreq: UnsafeMutablePointer<Float>
    let wVel: UnsafeMutablePointer<Float>
    let wPan: UnsafeMutablePointer<Float>
    /// [0] lead published, [1] whisper published (main writes);
    /// [2] lead consumed, [3] whisper consumed (audio writes).
    let counts: UnsafeMutablePointer<Int>
    /// [0] the audio thread's beat clock. [1] lead loudness, [2] whisper loudness (for the UI).
    let clock: UnsafeMutablePointer<Double>

    private let g: UnsafeMutablePointer<Float>
    // Main-thread bookkeeping
    private var stagedLead = 0
    private var stagedWhisper = 0

    init() {
        func f(_ v: Float) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: MotifParams.ring)
            p.initialize(repeating: v, count: MotifParams.ring)
            return p
        }
        func d() -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: MotifParams.ring)
            p.initialize(repeating: 0, count: MotifParams.ring)
            return p
        }
        lBeat = d(); lFreq = f(440); lVel = f(0); lDur = f(1); lPan = f(0)
        wBeat = d(); wFreq = f(1760); wVel = f(0); wPan = f(0)
        counts = UnsafeMutablePointer<Int>.allocate(capacity: 4)
        counts.initialize(repeating: 0, count: 4)
        clock = UnsafeMutablePointer<Double>.allocate(capacity: 3)
        clock.initialize(repeating: 0, count: 3)
        g = UnsafeMutablePointer<Float>.allocate(capacity: G.allCases.count)
        g.initialize(repeating: 0, count: G.allCases.count)
        g[G.bpm.rawValue] = 72
        g[G.whisperGain.rawValue] = 1
    }

    deinit {
        [lFreq, lVel, lDur, lPan, wFreq, wVel, wPan, g].forEach { $0.deallocate() }
        lBeat.deallocate(); wBeat.deallocate(); counts.deallocate(); clock.deallocate()
    }

    subscript(_ k: G) -> Float {
        get { g[k.rawValue] }
        set { g[k.rawValue] = newValue }
    }

    var nowBeat: Double { clock[0] }

    // MARK: Main thread

    /// Make last tick's staged notes visible to the audio thread. Call first thing each tick.
    func publish() {
        counts[0] = stagedLead
        counts[1] = stagedWhisper
    }

    @discardableResult
    func stageLead(beat: Double, freq: Double, vel: Double, beats: Double, pan: Float) -> Bool {
        guard stagedLead - counts[2] < MotifParams.ring - 1 else { return false }
        let i = stagedLead % MotifParams.ring
        lBeat[i] = beat; lFreq[i] = Float(freq); lVel[i] = Float(vel); lDur[i] = Float(beats); lPan[i] = pan
        stagedLead += 1
        return true
    }

    @discardableResult
    func stageWhisper(beat: Double, freq: Double, vel: Double, pan: Float) -> Bool {
        guard stagedWhisper - counts[3] < MotifParams.ring - 1 else { return false }
        let i = stagedWhisper % MotifParams.ring
        wBeat[i] = beat; wFreq[i] = Float(freq); wVel[i] = Float(vel); wPan[i] = pan
        stagedWhisper += 1
        return true
    }
}

/// The soloist plays the dusty upright (synthesized once at launch, see `PianoSampler`).
///
///  • Lead notes are held for their written length, then a felt damper comes down, like a
///    pianist playing legato: each note rings into the next, never smeared by a pedal.
///  • Whispers are the same piano two octaves up, pianissimo and staccato.
///  • The whole instrument sits on tape: slow wow and flutter on the playback speed, a bed of
///    hiss and the odd crackle that rise with upload, and a lowpass that opens with download.
final class MotifDSP {
    private let sr: Float
    private let p: MotifParams
    private let N = MotifParams.ring

    private var beat: Double = 0
    private var lTail = 0
    private var wTail = 0
    private var master: Float = 0
    private var bright: Float = 0
    private var breath: Float = 0

    // Sample bank (installed once the background render finishes)
    private var bank: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var bankFreqs: UnsafeMutablePointer<Float>?
    private var bankCount = 0
    private var bankLength = 0
    private var bankRateScale: Float = 1

    // Voices (raw buffers: no Swift arrays on the audio thread)
    private static let poly = 16
    private let vPos: UnsafeMutablePointer<Double>
    private let vRate: UnsafeMutablePointer<Float>
    private let vGain: UnsafeMutablePointer<Float>
    private let vGL: UnsafeMutablePointer<Float>
    private let vGR: UnsafeMutablePointer<Float>
    private let vBuf: UnsafeMutablePointer<Int>
    private let vOn: UnsafeMutablePointer<Bool>
    private let vWhisper: UnsafeMutablePointer<Bool>
    private let vHold: UnsafeMutablePointer<Int>      // samples until the damper comes down
    private let vDamp: UnsafeMutablePointer<Float>    // 1 = undamped, falls toward 0
    private let vStart: UnsafeMutablePointer<Int>     // trigger order, for stealing the oldest

    private var serial = 0
    private var lp1L: Float = 0, lp2L: Float = 0, lp1R: Float = 0, lp2R: Float = 0
    private var wowPh: Float = 0, flutPh: Float = 0
    private var hissL: Float = 0, hissR: Float = 0
    private var crackle: Float = 0, crackleLP: Float = 0
    private var rng: UInt32 = 0x2545_F491

    private let leadDamp: Float, whisperDamp: Float, stealDamp: Float, crackleDecay: Float

    init(sampleRate: Float, params: MotifParams) {
        sr = sampleRate
        p = params
        let n = MotifDSP.poly
        func f(_ v: Float) -> UnsafeMutablePointer<Float> {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: n)
            b.initialize(repeating: v, count: n)
            return b
        }
        vPos = UnsafeMutablePointer<Double>.allocate(capacity: n); vPos.initialize(repeating: 0, count: n)
        vRate = f(1); vGain = f(0); vGL = f(0.7); vGR = f(0.7); vDamp = f(1)
        vBuf = UnsafeMutablePointer<Int>.allocate(capacity: n); vBuf.initialize(repeating: 0, count: n)
        vHold = UnsafeMutablePointer<Int>.allocate(capacity: n); vHold.initialize(repeating: 0, count: n)
        vStart = UnsafeMutablePointer<Int>.allocate(capacity: n); vStart.initialize(repeating: 0, count: n)
        vOn = UnsafeMutablePointer<Bool>.allocate(capacity: n); vOn.initialize(repeating: false, count: n)
        vWhisper = UnsafeMutablePointer<Bool>.allocate(capacity: n); vWhisper.initialize(repeating: false, count: n)
        leadDamp = expf(-1 / (0.30 * sampleRate))       // felt damper on a held melody note
        whisperDamp = expf(-1 / (0.09 * sampleRate))    // quicker on the staccato whispers
        stealDamp = expf(-1 / (0.004 * sampleRate))     // a reused voice fades in ~20 ms
        crackleDecay = expf(-1 / (0.0008 * sampleRate))
    }

    deinit {
        vPos.deallocate(); vRate.deallocate(); vGain.deallocate(); vGL.deallocate(); vGR.deallocate()
        vDamp.deallocate(); vBuf.deallocate(); vHold.deallocate(); vStart.deallocate()
        vOn.deallocate(); vWhisper.deallocate()
    }

    /// Main thread, once. The sampler must outlive this object (MotifEngine holds it).
    func install(_ s: PianoSampler) {
        bankFreqs = s.rootFreqs
        bankCount = s.count
        bankLength = s.length
        bankRateScale = Float(s.sampleRate) / sr
        bank = s.buffers                                  // last: the audio thread checks this
    }

    @inline(__always) private func rand() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng >> 8) / 16_777_216
    }

    /// Start a note on a free voice, or on the oldest one. A stolen voice can't fade first
    /// (the new note must land on its beat), so it's swapped at once; with 16 voices that only
    /// happens to a note already deep in its decay.
    private func trigger(freq: Float, vel: Float, pan: Float, holdSamples: Int, whisper: Bool) {
        guard let freqs = bankFreqs, bankCount > 0 else { return }
        var bi = 0
        var best = Float.greatestFiniteMagnitude
        for i in 0..<bankCount {
            let d = abs(log2f(freq / freqs[i]))
            if d < best { best = d; bi = i }
        }
        var v = -1
        var oldest = Int.max
        for i in 0..<MotifDSP.poly {
            if !vOn[i] { v = i; break }
            if vStart[i] < oldest { oldest = vStart[i]; v = i }
        }
        let a = (max(-1, min(1, pan)) + 1) * Float.pi / 4
        serial += 1
        vPos[v] = 0
        vRate[v] = freq / freqs[bi] * bankRateScale
        vGain[v] = vel
        vGL[v] = cosf(a); vGR[v] = sinf(a)
        vBuf[v] = bi
        vHold[v] = holdSamples
        vDamp[v] = 1
        vStart[v] = serial
        vWhisper[v] = whisper
        vOn[v] = true
    }

    func render(frames: Int, left L: UnsafeMutablePointer<Float>, right R: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        let bpm = max(30, min(200, p[.bpm]))
        let beatStep = Double(bpm) / 60 / Double(sr)
        let samplesPerBeat = Float(60) / bpm * sr
        let lHead = p.counts[0], wHead = p.counts[1]
        let mTarget = p[.master]
        let brightT = p[.bright], breathT = p[.breath]
        let wGain = p[.whisperGain]
        let twoPi = 2 * Float.pi
        let wowInc: Float = 0.33 / sr, flutInc: Float = 5.7 / sr
        let crackleChance = 2.5 / sr
        let len = bankLength
        var leadPeak: Float = 0, whisperPeak: Float = 0

        for n in 0..<frames {
            beat += beatStep
            // Notes are due on the beat clock. Until the piano is ready they're skipped, not
            // queued, so nothing bunches up at launch.
            if lTail < lHead, p.lBeat[lTail % N] <= beat {
                let i = lTail % N
                trigger(freq: p.lFreq[i], vel: p.lVel[i], pan: p.lPan[i] * 0.6,
                        holdSamples: Int(max(0.1, p.lDur[i]) * samplesPerBeat), whisper: false)
                lTail += 1
            }
            if wTail < wHead, p.wBeat[wTail % N] <= beat {
                let i = wTail % N
                trigger(freq: p.wFreq[i], vel: p.wVel[i] * 0.3 * wGain, pan: p.wPan[i],
                        holdSamples: Int(0.08 * sr), whisper: true)
                wTail += 1
            }
            master += (mTarget - master) * 0.0004
            bright += (brightT - bright) * 0.0002
            breath += (breathT - breath) * 0.0002

            // Tape: slow wow and a little flutter on the playback speed
            let tape = 1 + 0.0012 * sinf(twoPi * wowPh) + 0.0003 * sinf(twoPi * flutPh)
            wowPh += wowInc; if wowPh >= 1 { wowPh -= 1 }
            flutPh += flutInc; if flutPh >= 1 { flutPh -= 1 }

            var outL: Float = 0, outR: Float = 0
            if let bank {
                for v in 0..<MotifDSP.poly where vOn[v] {
                    let pos = vPos[v]
                    let ip = Int(pos)
                    if ip >= len - 1 || vDamp[v] < 0.0005 { vOn[v] = false; continue }
                    if vHold[v] > 0 {
                        vHold[v] -= 1
                    } else {
                        vDamp[v] *= vWhisper[v] ? whisperDamp : leadDamp
                    }
                    let fr = Float(pos - Double(ip))
                    let buf = bank[vBuf[v]]
                    let s = (buf[ip] + (buf[ip + 1] - buf[ip]) * fr) * vGain[v] * vDamp[v]
                    outL += s * vGL[v]
                    outR += s * vGR[v]
                    if vWhisper[v] { whisperPeak = max(whisperPeak, abs(s)) } else { leadPeak = max(leadPeak, abs(s)) }
                    vPos[v] = pos + Double(vRate[v] * tape)
                }
            }

            // The felt: two one-poles, ~1.1 kHz when the phone is quiet, ~7 kHz when it's busy
            let a = min(1, twoPi * (1100 + 6000 * bright) / sr)
            lp1L += (outL - lp1L) * a; lp2L += (lp1L - lp2L) * a
            lp1R += (outR - lp1R) * a; lp2R += (lp1R - lp2R) * a

            // Dust: hiss and the odd crackle, rising with upload
            let nL = rand() * 2 - 1, nR = rand() * 2 - 1
            hissL += (nL - hissL) * 0.35; hissR += (nR - hissR) * 0.35
            if rand() < crackleChance * (0.5 + 2 * breath) {
                crackle = (0.02 + 0.08 * rand()) * (rand() < 0.5 ? -1 : 1)
            }
            let c = crackle - crackleLP
            crackleLP += (crackle - crackleLP) * 0.2
            crackle *= crackleDecay
            let dust = 0.12 + 0.5 * breath

            L[n] = tanhf((lp2L * 0.55 + (hissL * 0.006 + c) * dust) * master)
            R[n] = tanhf((lp2R * 0.55 + (hissR * 0.006 + c * 0.8) * dust) * master)
        }

        p.clock[0] = beat
        p.clock[1] = Double(leadPeak * 1.4)
        p.clock[2] = Double(whisperPeak * 3)
        p.counts[2] = lTail
        p.counts[3] = wTail
    }
}
