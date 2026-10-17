import Foundation

/// Who the phone was talking to, broadly.
enum LookupKind: String {
    case app        // the services you chose to use (and their CDNs)
    case system     // the phone talking to Apple about itself
    case tracker    // analytics, ads and telemetry riding along

    var label: String {
        switch self {
        case .app: return "apps & web"
        case .system: return "Apple / system"
        case .tracker: return "trackers"
        }
    }
}

/// One note of a leitmotif: a scale step (relative to the motif's first note, which is
/// itself a chord tone) and a length in eighth notes.
struct MotifNote: Equatable {
    var degree: Int
    var eighths: Int
}

/// One lookup, as heard and as scored.
struct Lookup: Identifiable {
    let id: Int                 // tunnel sequence number
    let time: Date
    let name: String            // "scontent-bos5-1.cdninstagram.com"
    let domain: String          // "cdninstagram.com"
    let kind: LookupKind
    let motif: [MotifNote]
    let pan: Float
    var fate: Fate = .waiting

    enum Fate { case waiting, sung, whispered, merged, dropped }
}

/// Turns hostnames into music. Everything here is a pure function of the name, so a given
/// service always "sounds like itself": its motif is fixed across lookups, days and phones.
enum Score {
    static func lookup(_ e: WireEvent) -> Lookup {
        let domain = registrableDomain(e.name)
        let kind = classify(name: e.name, domain: domain)
        let h = fnv(domain)
        let pan = Float(Double((h >> 40) & 0xFF) / 255 - 0.5) * (kind == .tracker ? 1.4 : 0.6)
        return Lookup(id: e.seq, time: Date(timeIntervalSince1970: e.t), name: e.name,
                    domain: domain, kind: kind, motif: motif(domain: domain, name: e.name), pan: pan)
    }

    /// The motif: 2–4 notes drawn from the domain's hash, with a small family resemblance
    /// across its subdomains (api., cdn., www. vary only the last note).
    static func motif(domain: String, name: String) -> [MotifNote] {
        var r = Mix(fnv(domain))
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
        if name != domain {
            var v = Mix(fnv(name))
            let n = notes.count - 1
            notes[n].degree += [1, -1, 2, 0][v.int(4)]
            if v.int(4) == 0 { notes.append(MotifNote(degree: notes[n].degree + 1, eighths: 1)) }
        }
        return notes
    }

    // MARK: Names

    /// "scontent-bos5-1.cdninstagram.com" → "cdninstagram.com"; "bbc.co.uk" stays whole.
    static func registrableDomain(_ name: String) -> String {
        let labels = name.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return name }
        let tld = labels[labels.count - 1], sld = labels[labels.count - 2]
        let compoundSLD: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go", "gob"]
        let take = (tld.count == 2 && compoundSLD.contains(sld)) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    static func classify(name: String, domain: String) -> LookupKind {
        if trackerDomains.contains(domain) { return .tracker }
        let first = name.split(separator: ".").first.map(String.init) ?? ""
        let trackerWords = ["analytics", "telemetry", "metrics", "tracking", "tracker", "adservice", "ads",
                            "pixel", "beacon", "collector", "stats", "events", "log", "logs", "crashlytics"]
        if trackerWords.contains(first) { return .tracker }
        if systemDomains.contains(domain) { return .system }
        return .app
    }

    /// A small, hand-picked list: enough to hear the pattern, nowhere near a real blocklist.
    static let trackerDomains: Set<String> = [
        "doubleclick.net", "google-analytics.com", "googletagmanager.com", "googlesyndication.com",
        "googleadservices.com", "app-measurement.com", "crashlytics.com", "adsrvr.org",
        "branch.io", "app.link", "adjust.com", "adjust.world", "appsflyer.com", "appsflyersdk.com",
        "amplitude.com", "mixpanel.com", "segment.io", "segment.com", "sentry.io", "bugsnag.com",
        "scorecardresearch.com", "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "applovin.com", "applvn.com", "unityads.unity3d.com", "moatads.com", "doubleverify.com",
        "adnxs.com", "rubiconproject.com", "pubmatic.com", "chartboost.com", "vungle.com",
        "inmobi.com", "onesignal.com", "braze.com", "braze.eu", "appboy.com", "kochava.com",
        "singular.net", "newrelic.com", "nr-data.net", "datadoghq.com", "hotjar.com",
        "fullstory.com", "quantserve.com", "demdex.net", "omtrdc.net", "2o7.net", "everesttech.net",
        "bluekai.com", "krxd.net", "liadm.com", "openx.net", "casalemedia.com", "yieldmo.com",
        "smartadserver.com", "amazon-adsystem.com", "ads-twitter.com", "ads.linkedin.com",
        "facebook.net", "tiktokv.com", "byteoversea.com", "mparticle.com", "launchdarkly.com",
        "statsig.com", "optimizely.com", "iterable.com", "leanplum.com", "clevertap-prod.com",
    ]

    static let systemDomains: Set<String> = [
        "apple.com", "icloud.com", "icloud-content.com", "mzstatic.com", "apple-dns.net",
        "aaplimg.com", "cdn-apple.com", "apple-cloudkit.com", "apple.news", "me.com",
        "apple-mapkit.com", "itunes.com", "apple-livephotoskit.com",
    ]

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
