import Foundation

/// Just enough IPv4 / UDP / DNS to read a question and wrap an answer.
enum DNSPacket {
    struct Query {
        var srcIP: [UInt8]       // the phone's tunnel address
        var dstIP: [UInt8]       // the made-up resolver
        var srcPort: UInt16
        var dstPort: UInt16
        var payload: Data        // the DNS message, untouched
        var name: String?        // first question's name, if it parsed
    }

    /// Parse an IPv4/UDP packet to port 53. Returns nil for anything else.
    static func parseQuery(_ packet: Data) -> Query? {
        let b = [UInt8](packet)
        guard b.count >= 28, b[0] >> 4 == 4 else { return nil }
        let ihl = Int(b[0] & 0x0F) * 4
        let total = min(b.count, Int(b[2]) << 8 | Int(b[3]))
        guard ihl >= 20, b[9] == 17, total >= ihl + 8 else { return nil }     // 17 = UDP
        // Fragments (more-fragments flag or a non-zero offset) aren't worth reassembling here.
        let frag = (Int(b[6]) << 8 | Int(b[7]))
        guard frag & 0x2000 == 0, frag & 0x1FFF == 0 else { return nil }
        let u = ihl
        let srcPort = UInt16(b[u]) << 8 | UInt16(b[u + 1])
        let dstPort = UInt16(b[u + 2]) << 8 | UInt16(b[u + 3])
        let udpLen = Int(b[u + 4]) << 8 | Int(b[u + 5])
        guard dstPort == 53, udpLen >= 8 + 12, u + udpLen <= total else { return nil }
        let payload = Data(b[(u + 8)..<(u + udpLen)])
        return Query(srcIP: Array(b[12..<16]), dstIP: Array(b[16..<20]),
                     srcPort: srcPort, dstPort: dstPort,
                     payload: payload, name: questionName(payload))
    }

    /// The first question's name ("www.example.com"), or nil if the message is odd.
    static func questionName(_ msg: Data) -> String? {
        let m = [UInt8](msg)
        guard m.count >= 12 else { return nil }
        let qdcount = Int(m[4]) << 8 | Int(m[5])
        let isQuery = m[2] & 0x80 == 0
        guard qdcount >= 1, isQuery else { return nil }
        var i = 12
        var labels: [String] = []
        while i < m.count {
            let len = Int(m[i])
            if len == 0 { break }
            guard len < 64, i + 1 + len <= m.count, labels.count < 64 else { return nil }   // no pointers in a question
            let bytes = m[(i + 1)..<(i + 1 + len)]
            labels.append(String(decoding: bytes, as: UTF8.self))
            i += 1 + len
        }
        guard i < m.count, !labels.isEmpty else { return nil }
        return labels.joined(separator: ".")
    }

    /// Wrap a resolver's answer in IPv4/UDP, addressed back to whoever asked.
    static func reply(to q: Query, payload: Data) -> Data {
        let udpLen = 8 + payload.count
        let total = 20 + udpLen
        var p = [UInt8](repeating: 0, count: total)
        // IPv4 header
        p[0] = 0x45                                   // version 4, 20-byte header
        p[2] = UInt8(total >> 8); p[3] = UInt8(total & 0xFF)
        p[6] = 0x40                                   // don't fragment
        p[8] = 64                                     // TTL
        p[9] = 17                                     // UDP
        for k in 0..<4 { p[12 + k] = q.dstIP[k]; p[16 + k] = q.srcIP[k] }
        let ipSum = checksum(p, 0, 20, initial: 0)
        p[10] = UInt8(ipSum >> 8); p[11] = UInt8(ipSum & 0xFF)
        // UDP header
        p[20] = UInt8(q.dstPort >> 8); p[21] = UInt8(q.dstPort & 0xFF)
        p[22] = UInt8(q.srcPort >> 8); p[23] = UInt8(q.srcPort & 0xFF)
        p[24] = UInt8(udpLen >> 8); p[25] = UInt8(udpLen & 0xFF)
        p.replaceSubrange(28..<total, with: payload)
        // UDP checksum over the pseudo-header (src, dst, protocol, length) and the datagram.
        var pseudo: UInt32 = 0
        for k in stride(from: 12, to: 20, by: 2) { pseudo += UInt32(p[k]) << 8 | UInt32(p[k + 1]) }
        pseudo += 17
        pseudo += UInt32(udpLen)
        var udpSum = checksum(p, 20, total, initial: pseudo)
        if udpSum == 0 { udpSum = 0xFFFF }
        p[26] = UInt8(udpSum >> 8); p[27] = UInt8(udpSum & 0xFF)
        return Data(p)
    }

    /// Internet checksum (RFC 1071) of p[from..<to], starting from a partial sum.
    static func checksum(_ p: [UInt8], _ from: Int, _ to: Int, initial: UInt32) -> UInt16 {
        var sum = initial
        var i = from
        while i + 1 < to {
            sum += UInt32(p[i]) << 8 | UInt32(p[i + 1])
            i += 2
        }
        if i < to { sum += UInt32(p[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
