import Foundation

/// One thing the phone said out loud: a hostname it asked the network to look up.
///
/// Compiled into both the Leitmotif app and its tunnel extension, which talk through
/// `NETunnelProviderSession.sendProviderMessage` (the app asks, the tunnel answers).
struct WireEvent: Codable, Equatable {
    var seq: Int
    /// When the query left the phone (seconds since 1970).
    var t: Double
    /// The full name asked for, lowercased, no trailing dot ("scontent-bos5-1.cdninstagram.com").
    var name: String
}

/// App → tunnel: "send me everything after `after`".
struct WireRequest: Codable {
    var after: Int
}

/// Tunnel → app.
struct WireReply: Codable {
    var events: [WireEvent]
    /// Lookups seen since the tunnel started (including repeats folded into one event).
    var queries: Int
    /// Lookups the upstream resolver never answered.
    var failures: Int
}

/// Where lookups go after Leitmotif has heard them. Stored in the VPN profile's
/// `providerConfiguration` so the tunnel can read it at start.
enum WireUpstream: String, CaseIterable, Identifiable {
    case cloudflare = "1.1.1.1"
    case quad9 = "9.9.9.9"
    case google = "8.8.8.8"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cloudflare: return "Cloudflare (1.1.1.1)"
        case .quad9:      return "Quad9 (9.9.9.9)"
        case .google:     return "Google (8.8.8.8)"
        }
    }
    /// The chosen resolver first, the others as fallbacks.
    var ordered: [String] { [rawValue] + WireUpstream.allCases.map(\.rawValue).filter { $0 != rawValue } }

    static let configKey = "upstreams"
}
