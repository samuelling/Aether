import Foundation
import NetworkExtension

/// Installs, starts and stops Leitmotif's listening tunnel, and collects what it heard.
///
/// The tunnel is a separate process (the LeitmotifNameTunnel extension). The app asks it for new
/// lookups a few times a second with a provider message; nothing is shared on disk.
@MainActor
final class Tunnel: ObservableObject {
    static let providerBundleID = "com.samuelling.ambit.name.tunnel"

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?
    @Published private(set) var queries = 0
    @Published private(set) var failures = 0

    /// Called on the main actor with each batch of new lookups.
    var onEvents: (([WireEvent]) -> Void)?

    var isOn: Bool { status == .connected }
    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    private var manager: NETunnelProviderManager?
    private var lastSeq = 0
    private var asking = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil,
                                                          queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let c = note.object as? NEVPNConnection,
                      c === self.manager?.connection else { return }
                self.status = c.status
            }
        }
        Task { await load() }
    }

    /// Pick up an existing Leitmotif profile (e.g. the tunnel is still running from last time).
    func load() async {
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            if let m = all.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Tunnel.providerBundleID
            }) {
                manager = m
                status = m.connection.status
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// First time: iOS asks "Leitmotif would like to add VPN configurations". Allow it.
    func start(upstream: WireUpstream) async {
        lastError = nil
        do {
            let m = manager ?? NETunnelProviderManager()
            let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Tunnel.providerBundleID
            proto.serverAddress = "On this iPhone"
            proto.providerConfiguration = [WireUpstream.configKey: upstream.ordered]
            m.protocolConfiguration = proto
            m.localizedDescription = "Ambit Name"
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()        // required between save and start
            manager = m
            if m.connection.status == .connected || m.connection.status == .connecting {
                // Already running (perhaps with another resolver): restart to pick up changes.
                m.connection.stopVPNTunnel()
                try await Task.sleep(nanoseconds: 800_000_000)
            }
            try m.connection.startVPNTunnel()
            status = m.connection.status
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Ask the tunnel for anything new. Cheap; call a few times a second.
    func poll() {
        guard !asking, status == .connected,
              let session = manager?.connection as? NETunnelProviderSession,
              let data = try? JSONEncoder().encode(WireRequest(after: lastSeq)) else { return }
        asking = true
        do {
            try session.sendProviderMessage(data) { [weak self] reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.received(reply) }
                }
            }
        } catch {
            asking = false
        }
    }

    private func received(_ data: Data?) {
        asking = false
        guard let data, let r = try? JSONDecoder().decode(WireReply.self, from: data) else { return }
        queries = r.queries
        failures = r.failures
        let fresh = r.events.filter { $0.seq > lastSeq || lastSeq > (r.events.last?.seq ?? 0) }
        if let last = r.events.last?.seq { lastSeq = last }
        if !fresh.isEmpty { onEvents?(fresh) }
    }
}
