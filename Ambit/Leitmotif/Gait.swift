import Foundation

// MARK: - Bursts and symbols

/// One burst of traffic: activity bounded by ~200 ms of quiet (or cut at 4 s, so a long
/// stream becomes a run of large bursts).
struct Burst {
    var start: TimeInterval
    var end: TimeInterval
    var up = 0.0          // bytes sent
    var down = 0.0        // bytes received
    var packets = 0.0
    var cellBytes = 0.0

    var bytes: Double { up + down }
    var duration: Double { max(0, end - start) }
    var meanPacket: Double { packets > 0 ? bytes / packets : 0 }
    var onCell: Bool { cellBytes > bytes / 2 }
}

/// The gait alphabet: direction × size, six letters. Like Morse, a single letter means little;
/// it's the words (the last three letters) that become motifs.
struct GaitSymbol: Equatable {
    var up: Bool          // the phone mostly sent (↑) or mostly received (↓)
    var size: Int         // 0 small, 1 medium, 2 large

    /// Size bins, in bytes per burst. First guesses: tune them from a recorded traffic log.
    static let smallBelow = 8_000.0
    static let largeFrom = 250_000.0

    init(_ b: Burst) {
        up = b.up > b.down
        size = b.bytes < GaitSymbol.smallBelow ? 0 : (b.bytes < GaitSymbol.largeFrom ? 1 : 2)
    }

    var text: String { (up ? "↑" : "↓") + ["s", "M", "L"][size] }
}

/// Watches the counters ~15 times a second and reports each finished burst.
/// Peer-to-peer links are left out: they carry the duo's own messages, and Leitmotif
/// shouldn't sing about itself.
final class GaitSensor {
    /// Bytes in one ~67 ms sample that count as "active" (a couple of small packets).
    static let activeBytes = 600.0
    static let quietSamplesToEnd = 3
    static let maxBurst = 4.0

    var onBurst: ((Burst) -> Void)?
    /// Every raw sample (for the traffic log): time, Wi-Fi, cellular and peer-to-peer deltas.
    var onSample: ((TimeInterval, IfDelta, IfDelta, IfDelta) -> Void)?

    private var last: Counters?
    private var current: Burst?
    private var quiet = 0

    func reset() {
        last = nil
        current = nil
        quiet = 0
    }

    func sample(now: TimeInterval) {
        guard let c = Counters.read() else { return }
        defer { last = c }
        guard let l = last else { return }
        let w = c.wifi.minus(l.wifi), m = c.cell.minus(l.cell), p = c.p2p.minus(l.p2p)
        guard w.plausible, m.plausible, p.plausible else { return }
        onSample?(now, w, m, p)

        let bytes = w.bytes + m.bytes
        let packets = w.packets + m.packets
        if bytes >= GaitSensor.activeBytes && packets >= 2 {
            if current == nil { current = Burst(start: now, end: now) }
            current!.up += w.txB + m.txB
            current!.down += w.rxB + m.rxB
            current!.packets += packets
            current!.cellBytes += m.bytes
            current!.end = now
            quiet = 0
            if now - current!.start >= GaitSensor.maxBurst { finish() }
        } else if current != nil {
            quiet += 1
            if quiet >= GaitSensor.quietSamplesToEnd { finish() }
        }
    }

    private func finish() {
        if let b = current { onBurst?(b) }
        current = nil
        quiet = 0
    }
}

// MARK: - Traffic log (the probe)

/// Writes every raw sample to a CSV in the app's Documents folder (visible in the Files app),
/// for tuning the burst thresholds and size bins against real use.
final class TrafficLog {
    let url: URL
    private let handle: FileHandle
    private var buffer = ""
    private var lines = 0
    private let t0: TimeInterval

    init?(now: TimeInterval) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        url = dir.appendingPathComponent("leitmotif-traffic-\(f.string(from: Date())).csv")
        let header = "t,wifi_rx_bytes,wifi_tx_bytes,wifi_rx_pkts,wifi_tx_pkts,cell_rx_bytes,cell_tx_bytes,cell_rx_pkts,cell_tx_pkts,p2p_rx_bytes,p2p_tx_bytes\n"
        guard FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8)),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        handle = h
        t0 = now
    }

    func write(_ t: TimeInterval, _ w: IfDelta, _ m: IfDelta, _ p: IfDelta) {
        func i(_ x: Double) -> String { String(Int(x)) }
        buffer += String(format: "%.3f", t - t0)
        buffer += ",\(i(w.rxB)),\(i(w.txB)),\(i(w.rxP)),\(i(w.txP)),\(i(m.rxB)),\(i(m.txB)),\(i(m.rxP)),\(i(m.txP)),\(i(p.rxB)),\(i(p.txB))\n"
        lines += 1
        if lines % 30 == 0 { flush() }
    }

    func close() {
        flush()
        try? handle.close()
    }

    private func flush() {
        guard !buffer.isEmpty, let d = buffer.data(using: .utf8) else { return }
        handle.write(d)
        buffer = ""
    }
}
