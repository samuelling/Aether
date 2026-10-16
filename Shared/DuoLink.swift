import Foundation
import MultipeerConnectivity

/// The message both apps exchange. Every field is optional; each app fills in what it owns.
///
/// Division of labour (by timescale):
///  • Bellweather (sky, hours)   → harmony: root pitch class and scale.
///  • Aether (radio room, secs)  → time: tempo and the shared chord timeline.
///  • Both                       → a short summary of their environment.
struct DuoState: Codable, Equatable {
    var role: String                 // "aether" | "bellweather"
    var seq: Int = 0

    // Harmony (Bellweather leads)
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

/// Finds the partner app nearby (Bluetooth or peer-to-peer Wi-Fi, no router needed),
/// connects automatically, and keeps both sides informed. If the partner goes quiet for
/// 10 s it is dropped, and each app simply carries on solo until they find each other again.
///
/// Not actor-isolated: every callback hops to the main queue before touching state, and
/// `onState` is always called on the main queue.
final class DuoLink: NSObject, ObservableObject {
    static let serviceType = "aether-duo"      // must match NSBonjourServices in Info.plist

    @Published private(set) var partnerName: String?
    @Published private(set) var partner: DuoState?
    @Published private(set) var searching = false

    /// Called on the main queue whenever a partner's state arrives.
    var onState: ((DuoState) -> Void)?
    /// Called on the main queue when the partner disconnects or times out.
    var onLost: (() -> Void)?

    var isConnected: Bool { partner != nil }

    private let role: String
    private let peer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var lastHeard = Date.distantPast
    private var lastRebrowse = Date.distantPast
    private var watchdog: Timer?
    private var seq = 0

    init(role: String) {
        self.role = role
        // A stable name per install keeps the invite tie-break deterministic.
        let key = "duo.peerSuffix"
        let suffix = UserDefaults.standard.string(forKey: key) ?? {
            let s = String(UUID().uuidString.prefix(6))
            UserDefaults.standard.set(s, forKey: key)
            return s
        }()
        peer = MCPeerID(displayName: "\(role)-\(suffix)")
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["role": role],
                                               serviceType: DuoLink.serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: DuoLink.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    deinit {
        watchdog?.invalidate()
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        searching = true
        watchdog?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkAlive() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        watchdog?.invalidate()
        searching = false
        dropPartner()
    }

    /// Send our current state to the partner (cheap; call on change and as a heartbeat).
    func send(_ state: DuoState) {
        guard !session.connectedPeers.isEmpty else { return }
        var s = state
        s.role = role
        seq += 1
        s.seq = seq
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    // MARK: Private

    private func checkAlive() {
        if partner != nil && Date().timeIntervalSince(lastHeard) > 10 { dropPartner() }
        // Nobody connected: restart browsing now and then so discovery (and the invite) fires again.
        if searching && session.connectedPeers.isEmpty && Date().timeIntervalSince(lastRebrowse) > 10 {
            rebrowse()
        }
    }

    private func rebrowse() {
        lastRebrowse = Date()
        browser.stopBrowsingForPeers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.searching else { return }
            self.browser.startBrowsingForPeers()
        }
    }

    private func dropPartner() {
        let had = partner != nil
        partner = nil
        partnerName = nil
        if had { onLost?() }
    }

    fileprivate func received(_ data: Data, from name: String) {
        guard let s = try? JSONDecoder().decode(DuoState.self, from: data), s.role != role else { return }
        lastHeard = Date()
        partner = s
        partnerName = s.role == "aether" ? "Aether" : "Bellweather"
        onState?(s)
    }

    fileprivate func peerDisconnected() {
        if session.connectedPeers.isEmpty {
            dropPartner()
            if searching { rebrowse() }
        }
    }
}

// MARK: - Multipeer delegates (arrive on background queues)

extension DuoLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        if state == .notConnected {
            DispatchQueue.main.async { [weak self] in self?.peerDisconnected() }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in self?.received(data, from: name) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension DuoLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Only pair with the *other* app, and let exactly one side send the invitation.
        guard let theirRole = info?["role"], theirRole != role else { return }
        guard peer.displayName < peerID.displayName else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

extension DuoLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept unless we're already paired with someone else. A relaunched partner keeps
        // its name, so a stale entry for the same name doesn't block the new invite.
        let name = peerID.displayName
        invitationHandler(session.connectedPeers.allSatisfy { $0.displayName == name }, session)
    }
}

/// Scale vocabulary both apps understand (matched by semitone steps).
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
