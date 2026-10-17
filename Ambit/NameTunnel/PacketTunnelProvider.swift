import NetworkExtension
import Network

/// Leitmotif's listening post. A "VPN" that carries nothing but the phone's name lookups.
///
/// Every app on the phone has to look up a server's name (instagram.com) before it can
/// reach it. This tunnel makes itself the phone's DNS resolver, so every lookup passes by:
/// it notes the name, hands the question on to a real resolver, and passes the answer back.
/// All other traffic goes out exactly as it would without Leitmotif. The tunnel only claims
/// one made-up address (the resolver's); it never sees a byte of anything else.
///
/// Nothing is written to disk. The last few hundred names live in memory until the app
/// collects them, and the tunnel shuts itself down if the app stops asking for 5 minutes.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// The made-up resolver address the phone is told to use, and the tunnel's own address.
    private static let dnsAddress = "10.111.0.53"
    private static let tunnelAddress = "10.111.0.2"
    private static let dnsIP: [UInt8] = [10, 111, 0, 53]

    private let q = DispatchQueue(label: "leitmotif.tunnel")
    private var upstreams = WireUpstream.cloudflare.ordered

    // Event store (queue q only)
    private var events: [WireEvent] = []
    private var seq = 0
    private var queries = 0
    private var failures = 0
    private var lastSeen: [String: Double] = [:]

    // Self-shutdown when the app has gone quiet
    private var lastAsked = Date()
    private var watchdog: DispatchSourceTimer?
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let list = proto.providerConfiguration?[WireUpstream.configKey] as? [String], !list.isEmpty {
            upstreams = list
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: [Self.tunnelAddress], subnetMasks: ["255.255.255.255"])
        // Claim only the resolver's address: everything else bypasses the tunnel untouched.
        v4.includedRoutes = [NEIPv4Route(destinationAddress: Self.dnsAddress, subnetMask: "255.255.255.255")]
        settings.ipv4Settings = v4
        let dns = NEDNSSettings(servers: [Self.dnsAddress])
        dns.matchDomains = [""]               // "" = every domain: be the phone's default resolver
        settings.dnsSettings = dns
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            self.q.async {
                self.running = true
                self.lastAsked = Date()
                self.startWatchdog()
                self.readLoop()
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        q.async {
            self.running = false
            self.watchdog?.cancel()
            self.watchdog = nil
            self.events.removeAll()
            self.lastSeen.removeAll()
            completionHandler()
        }
    }

    /// The app asks "anything after N?" a few times a second; answer with what's new.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        q.async {
            self.lastAsked = Date()
            let after = (try? JSONDecoder().decode(WireRequest.self, from: messageData))?.after ?? 0
            // If the app restarted (its counter is ahead of ours), resend what we have.
            let from = after > self.seq ? 0 : after
            let fresh = self.events.filter { $0.seq > from }.suffix(256)
            let reply = WireReply(events: Array(fresh), queries: self.queries, failures: self.failures)
            completionHandler?(try? JSONEncoder().encode(reply))
        }
    }

    // MARK: Packets

    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.q.async {
                guard self.running else { return }
                for p in packets { self.handle(p) }
                self.readLoop()
            }
        }
    }

    /// One IPv4 packet headed for the made-up resolver. Anything that isn't a UDP DNS
    /// query is dropped (TCP DNS, used only for oversized answers, isn't handled).
    private func handle(_ packet: Data) {
        guard let query = DNSPacket.parseQuery(packet), query.dstIP == Self.dnsIP else { return }
        queries += 1
        if let name = query.name { note(name) }
        forward(query, attempt: 0)
    }

    private func note(_ raw: String) {
        let name = raw.lowercased()
        guard !name.isEmpty, !name.hasSuffix(".arpa"), !name.hasSuffix(".local") else { return }
        let now = Date().timeIntervalSince1970
        // A, AAAA and HTTPS lookups for the same name arrive together: one event.
        if let t = lastSeen[name], now - t < 2 { return }
        lastSeen[name] = now
        if lastSeen.count > 2000 { lastSeen = lastSeen.filter { now - $0.value < 60 } }
        seq += 1
        events.append(WireEvent(seq: seq, t: now, name: name))
        if events.count > 512 { events.removeFirst(events.count - 512) }
    }

    /// Ask a real resolver, then hand its answer back as if it came from 10.111.0.53.
    /// One short-lived UDP connection per question keeps this simple and survives
    /// Wi-Fi ↔ cellular switches; the next resolver in the list is tried after 2.5 s.
    private func forward(_ query: DNSPacket.Query, attempt: Int) {
        guard attempt < upstreams.count else {
            failures += 1
            return
        }
        let host = NWEndpoint.Host(upstreams[attempt])
        let conn = NWConnection(host: host, port: 53, using: .udp)
        var done = false
        let finish: (Data?) -> Void = { [weak self] answer in
            guard let self, !done else { return }
            done = true
            conn.cancel()
            if let answer, self.running {
                let reply = DNSPacket.reply(to: query, payload: answer)
                self.packetFlow.writePackets([reply], withProtocols: [NSNumber(value: AF_INET)])
            } else if self.running {
                self.forward(query, attempt: attempt + 1)
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: query.payload, completion: .contentProcessed { error in
                    if error != nil { finish(nil) }
                })
                conn.receiveMessage { data, _, _, error in
                    finish(error == nil ? data : nil)
                }
            case .failed, .waiting:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + 2.5) { finish(nil) }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if Date().timeIntervalSince(self.lastAsked) > 300 {
                // Nobody's listening any more: step aside and give the phone its DNS back.
                self.cancelTunnelWithError(nil)
            }
        }
        t.resume()
        watchdog = t
    }
}
