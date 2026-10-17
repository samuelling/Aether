import Foundation

// Moved here from Aether (where it played the optional arpeggio): Leitmotif's soloist
// now sings on this piano.

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
