import Foundation

/// The message the instruments exchange. Every field is optional; each fills in what it owns.
/// Identical to the suite's `Shared/DuoLink.swift` `DuoState`.
///
/// Division of labour (by timescale):
///  • Bellweathered (sky, hours)  → harmony: root pitch class and scale.
///  • Aether (radio room, secs)   → time: tempo and the shared chord timeline.
///  • Both                        → a short summary of their environment.
///  • Leitmotif and Orbitakt only listen.
struct DuoState: Codable, Equatable {
    var role: String                 // "aether" | "bellweather"
    var seq: Int = 0

    // Harmony (Bellweathered leads)
    var rootPC: Int?                 // 0 = C … 11 = B
    var scaleSteps: [Int]?           // semitone steps, e.g. [0, 2, 4, 7, 9]

    // Time (Aether leads)
    var bpm: Double?
    var chordDegree: Int?            // scale degree of the current chord root
    var chordSerial: Int?            // increments at every chord change
    var chordSeconds: Double?

    // Environment summaries
    var day: Double?                 // 0 night … 1 full day
    var cloud: Double?               // 0…100 %
    var precip: Double?              // 0…1 chance
    var wind: Double?                // mph
    var tempF: Double?
    var place: String?
    var devices: Int?                // Bluetooth emitters heard
    var air: Double?                 // 0…1 how much the radio field is moving
}

/// Ambit's in-process stand-in for the suite's MultipeerConnectivity link.
///
/// It keeps the same API as `Shared/DuoLink.swift`, so the four instruments' models talk to
/// each other exactly as they do across phones: the leads (Aether, Bellweathered) send their
/// state on every change and as a two-second heartbeat, and every instrument hears the roles
/// it listens to. The difference is that nothing leaves the process. There are no radios to
/// find each other with and no connection for iOS to cut when Ambit goes to the background,
/// so Leitmotif and Orbitakt stay locked to the live key, tempo and chord on the lock screen.
///
/// Main queue only. `onState` and `onLost` are always called on the main queue.
final class DuoLink: ObservableObject {
    static let leadRoles: Set<String> = ["aether", "bellweather"]

    static func appName(of role: String) -> String {
        switch role {
        case "aether": return "Aether"
        case "bellweather": return "Bellweathered"
        case "leitmotif": return "Leitmotif"
        case "orbitakt": return "Orbitakt"
        default: return role
        }
    }

    enum Phase: Equatable { case off, searching, connected, paused }

    @Published private(set) var partnerName: String?
    @Published private(set) var partner: DuoState?
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var searchEnds: Date?
    @Published private(set) var listeners: [String] = []
    @Published private(set) var enabled = true
    @Published private(set) var timeoutMinutes = 0

    var onState: ((DuoState) -> Void)?
    var onLost: (() -> Void)?

    var isConnected: Bool { partner != nil }

    private let role: String
    /// Roles whose state this instrument wants: the other lead, or (for a listener) both leads.
    private let listens: Set<String>
    private var lastHeard: [String: Date] = [:]
    private var watchdog: Timer?
    private var seq = 0

    private struct Member { weak var link: DuoLink? }
    private static var members: [Member] = []

    init(role: String) {
        self.role = role
        listens = DuoLink.leadRoles.contains(role) ? DuoLink.leadRoles.subtracting([role]) : DuoLink.leadRoles
    }

    deinit { watchdog?.invalidate() }

    /// Call once at init. Joins the ensemble.
    func start() {
        DuoLink.members.removeAll { $0.link == nil || $0.link === self }
        DuoLink.members.append(Member(link: self))
        DuoLink.members.forEach { $0.link?.refreshListeners() }
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkAlive() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // Kept for API compatibility with the multi-phone link; in one process there is
    // nothing to search for and nothing to time out.
    func setEnabled(_ on: Bool) {}
    func setTimeout(minutes: Int) {}
    func searchAgain() {}

    /// Hand our current state to everyone in the ensemble who listens to our role.
    func send(_ state: DuoState) {
        var s = state
        s.role = role
        seq += 1
        s.seq = seq
        for m in DuoLink.members {
            guard let other = m.link, other !== self, other.listens.contains(role) else { continue }
            // Async, so a reply sent from inside a receiver never re-enters the sender.
            DispatchQueue.main.async { [weak other] in other?.received(s) }
        }
    }

    // MARK: Private

    private func received(_ s: DuoState) {
        guard listens.contains(s.role) else { return }
        lastHeard[s.role] = Date()
        partner = s
        partnerName = DuoLink.appName(of: s.role)
        phase = .connected
        onState?(s)
    }

    /// A lead that stops sending for 10 s is let go (it never should, inside one app).
    private func checkAlive() {
        let now = Date()
        lastHeard = lastHeard.filter { now.timeIntervalSince($0.value) <= 10 }
        if lastHeard.isEmpty && partner != nil {
            partner = nil
            partnerName = nil
            phase = .searching
            onLost?()
        }
    }

    private func refreshListeners() {
        guard DuoLink.leadRoles.contains(role) else { return }
        let names = Set(DuoLink.members.compactMap { $0.link?.role }
            .filter { !DuoLink.leadRoles.contains($0) }
            .map { DuoLink.appName(of: $0) })
        let sorted = names.sorted()
        if sorted != listeners { listeners = sorted }
    }
}

/// Scale vocabulary every instrument understands (matched by semitone steps).
enum DuoScales {
    static let all: [(name: String, steps: [Int])] = [
        ("Major pentatonic", [0, 2, 4, 7, 9]),
        ("Minor pentatonic", [0, 3, 5, 7, 10]),
        ("Major", [0, 2, 4, 5, 7, 9, 11]),
        ("Natural minor", [0, 2, 3, 5, 7, 8, 10]),
        ("Dorian", [0, 2, 3, 5, 7, 9, 10]),
        ("Lydian", [0, 2, 4, 6, 7, 9, 11]),
        ("Whole tone", [0, 2, 4, 6, 8, 10]),
        ("Hirajoshi", [0, 2, 3, 7, 8]),
        ("Suspended", [0, 2, 5, 7, 10]),
    ]
}
