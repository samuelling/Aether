import Foundation

// MARK: - The phone's interface counters

/// Running totals for one group of network interfaces (32-bit, they wrap every 4 GiB).
struct IfCounts {
    var rxB: UInt32 = 0, txB: UInt32 = 0, rxP: UInt32 = 0, txP: UInt32 = 0

    /// Change since `old`, with wrapping subtraction (handles one wrap between readings).
    func minus(_ old: IfCounts) -> IfDelta {
        IfDelta(rxB: Double(rxB &- old.rxB), txB: Double(txB &- old.txB),
                rxP: Double(rxP &- old.rxP), txP: Double(txP &- old.txP))
    }
}

struct IfDelta {
    var rxB = 0.0, txB = 0.0, rxP = 0.0, txP = 0.0
    var bytes: Double { rxB + txB }
    var packets: Double { rxP + txP }
    /// An interface vanishing (Wi-Fi off) shrinks a sum and looks like a giant wrap.
    var plausible: Bool { rxB < 200_000_000 && txB < 200_000_000 }
}

/// The phone's link-level counters by kind of link, from the BSD interface table.
///  • wifi: en*   • cell: pdp_ip*   • p2p: awdl*/llw* (AirDrop, Handoff, AirPlay, and the
///    duo link itself, which is why gait mode ignores it).
struct Counters {
    var wifi = IfCounts(), cell = IfCounts(), p2p = IfCounts()

    static func read() -> Counters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var c = Counters()
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let raw = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let d = raw.assumingMemoryBound(to: if_data.self).pointee
            func add(_ g: inout IfCounts) {
                g.rxB &+= d.ifi_ibytes; g.txB &+= d.ifi_obytes
                g.rxP &+= d.ifi_ipackets; g.txP &+= d.ifi_opackets
            }
            if name.hasPrefix("en") { add(&c.wifi) }
            else if name.hasPrefix("pdp_ip") { add(&c.cell) }
            else if name.hasPrefix("awdl") || name.hasPrefix("llw") { add(&c.p2p) }
        }
        return c
    }
}
