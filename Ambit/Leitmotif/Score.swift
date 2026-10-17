import Foundation

/// Which voice a burst of traffic is sung in.
enum UtteranceKind: String {
    case burst      // ordinary traffic: sung by the soloist in the middle register
    case bulk       // large downloads of full-size packets (streams, files): low and soft
    case chatter    // small bursts of tiny packets (pings, keep-alives, chat): whispered

    var label: String {
        switch self {
        case .burst: return "bursts"
        case .bulk: return "bulk (streams, downloads)"
        case .chatter: return "chatter"
        }
    }
}

/// One note of a motif: a scale step (relative to the motif's first note, which is itself
/// a chord tone) and a length in eighth notes.
struct MotifNote: Equatable {
    var degree: Int
    var eighths: Int
}

/// One burst of traffic, as heard and as scored.
struct Utterance: Identifiable {
    let id: Int
    let time: Date
    let word: String            // the gait word it completed: "↓L ↓L ↓M"
    let kind: UtteranceKind
    let motif: [MotifNote]
    let pan: Float
    let detail: String          // "412 KB received · 1.3 s · 1380 B/packet"
    var fate: Fate = .waiting

    enum Fate { case waiting, sung, whispered, merged, dropped }
}

/// Turns the gait of the phone's traffic into music. Everything here is a pure function of
/// the gait word, so a recurring pattern always sounds like itself.
enum Score {
    /// A burst, read as the last letter of a three-letter word ("↑s ↓M ↓L"). The word seeds
    /// the motif, so a recurring traffic pattern always gets the same tune.
    ///  • chatter (small bursts of small packets) → whispers
    ///  • bulk (large, mostly received, full-size packets) → the low, soft register
    ///  • everything else → the soloist's middle register
    static func utterance(_ b: Burst, word: [GaitSymbol], id: Int) -> Utterance {
        let text = word.map(\.text).joined(separator: " ")
        let key = "gait " + text
        let last = word.last ?? GaitSymbol(b)
        let kind: UtteranceKind
        if last.size == 0 && b.meanPacket < 300 {
            kind = .chatter
        } else if last.size == 2 && !last.up && b.meanPacket > 900 {
            kind = .bulk
        } else {
            kind = .burst
        }
        let h = fnv(key)
        let pan = Float(Double((h >> 40) & 0xFF) / 255 - 0.5) * (kind == .chatter ? 1.4 : 0.6)
        var detail = "\(formatBytes(b.bytes)) \(last.up ? "sent" : "received")"
        detail += String(format: " · %.1f s · %ld B/packet", b.duration, Int(b.meanPacket))
        if b.onCell { detail += " · cellular" }
        return Utterance(id: id, time: Date(), word: text, kind: kind,
                         motif: motif(key), pan: pan, detail: detail)
    }

    static func formatBytes(_ x: Double) -> String {
        if x >= 1_000_000 { return String(format: "%.1f MB", x / 1_000_000) }
        if x >= 1_000 { return String(format: "%.0f KB", x / 1_000) }
        return "\(Int(x)) B"
    }

    /// The motif: 2–4 notes drawn from the key's hash: a chord-tone start, mostly stepwise
    /// moves with the occasional leap, and a longer last note so each phrase lands.
    static func motif(_ key: String) -> [MotifNote] {
        var r = Mix(fnv(key))
        let count = 2 + r.int(3)
        let moves = [1, -1, 2, -2, 3, 0, 1, -1, 4, -3]
        let shortLens = [1, 1, 2, 1, 3, 2]
        var deg = [0, 2, 4][r.int(3)]                     // start on a chord tone
        var notes: [MotifNote] = []
        for i in 0..<count {
            if i > 0 { deg += moves[r.int(moves.count)] }
            let last = i == count - 1
            notes.append(MotifNote(degree: deg, eighths: last ? [2, 3, 4][r.int(3)] : shortLens[r.int(shortLens.count)]))
        }
        return notes
    }

    // MARK: Hashing (stable across launches, unlike Swift's Hasher)

    static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// SplitMix64: a tiny deterministic random stream seeded by a hash.
    struct Mix {
        var s: UInt64
        init(_ seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }
}
