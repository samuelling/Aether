import Foundation

/// The house's water meter: total bytes in and out over Wi-Fi and cellular, for the whole
/// phone, read from the system's interface counters. It can't say which app or where to,
/// only how hard the phone is talking right now.
struct Meter {
    /// Smoothed rates in bytes per second.
    private(set) var down: Double = 0
    private(set) var up: Double = 0
    /// 0…1, log-scaled: ~2 KB/s → 0, ~5 MB/s → 1.
    var downLevel: Double { Meter.level(down) }
    var upLevel: Double { Meter.level(up) }
    /// False if the counters never moved (iOS may hide them); the music then ignores the meter.
    private(set) var works = false

    private var last: (rx: UInt32, tx: UInt32, t: TimeInterval)?

    static func level(_ bytesPerSec: Double) -> Double {
        guard bytesPerSec > 2_000 else { return 0 }
        return min(1, log10(bytesPerSec / 2_000) / log10(5_000_000 / 2_000))
    }

    mutating func sample(now: TimeInterval) {
        guard let c = Meter.counters() else { return }
        defer { last = (c.rx, c.tx, now) }
        guard let l = last else { return }
        let dt = now - l.t
        guard dt > 0.05 else { return }
        // The counters are 32-bit and wrap every 4 GiB: wrapping subtraction handles one wrap.
        let rx = Double(c.rx &- l.rx) / dt
        let tx = Double(c.tx &- l.tx) / dt
        // An interface vanishing (Wi-Fi off) shrinks the sum and looks like a giant wrap: skip it.
        guard rx < 400_000_000, tx < 400_000_000 else { return }
        if rx > 0 || tx > 0 { works = true }
        // Rise fast (a burst should be heard at once), fall over a couple of seconds.
        let kd = rx > down ? 0.6 : 1 - exp(-dt / 2.0)
        let ku = tx > up ? 0.6 : 1 - exp(-dt / 2.0)
        down += (rx - down) * kd
        up += (tx - up) * ku
    }

    /// Summed byte counters for Wi-Fi and cellular links.
    private static func counters() -> (rx: UInt32, tx: UInt32)? {
        guard let c = Counters.read() else { return nil }
        return (c.wifi.rxB &+ c.cell.rxB, c.wifi.txB &+ c.cell.txB)
    }
}
