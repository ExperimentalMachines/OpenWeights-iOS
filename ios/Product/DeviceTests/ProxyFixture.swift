import Foundation
import Network
import Darwin
import OpenWeightsCore

/// Owned loopback-only fixture. It can dial one checked public IP on port 443.
/// No origin DNS, arbitrary destinations, source bodies or credential values are recorded.
final class ProxyFixture: @unchecked Sendable {
    enum Mode { case connect, socks5, reject, hang, tlsPassThrough }
    struct Observation { var targets: [String] = []; var authenticated = false; var domainTarget = false; var connections = 0 }
    private let queue = DispatchQueue(label: "openweights.proxy-fixture")
    private let listener: NWListener
    private let ip: String
    private let mode: Mode
    private let authenticated: Bool
    private var sessions: [ProxyFixtureSession] = []
    private var observation = Observation()
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    init(ip: String, mode: Mode, authenticated: Bool = false) throws {
        guard PublicWebIP.isPublic(ip) else { throw PublicWebError.refused("The fixture requires a public IP.") }
        self.ip = ip; self.mode = mode; self.authenticated = authenticated
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { state in
                guard let callback = self.startContinuation else { return }
                switch state {
                case .ready: self.startContinuation = nil; callback.resume(returning: self.listener.port!.rawValue)
                case .failed(let error): self.startContinuation = nil; callback.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                self.observation.connections += 1
                let session = ProxyFixtureSession(client: connection, queue: self.queue, ip: self.ip, mode: self.mode, authenticated: self.authenticated) { target, authenticated, domain in
                    if let target { self.observation.targets.append(target) }
                    self.observation.authenticated = self.observation.authenticated || authenticated
                    self.observation.domainTarget = self.observation.domainTarget || domain
                }
                self.sessions.append(session); session.start()
            }
            queue.asyncAfter(deadline: .now() + 5) {
                guard let callback = self.startContinuation else { return }; self.startContinuation = nil; self.listener.cancel()
                callback.resume(throwing: PublicWebError.refused("The owned proxy fixture could not start."))
            }
            listener.start(queue: queue)
        }
    }
    func snapshot() -> Observation { queue.sync { observation } }
    func stop() { queue.sync { listener.cancel(); sessions.forEach { $0.stop() }; sessions.removeAll() } }
}
private final class ProxyFixtureSession {
    let client: NWConnection; let queue: DispatchQueue; let ip: String; let mode: ProxyFixture.Mode; let authenticated: Bool
    let record: (String?, Bool, Bool) -> Void
    var upstream: NWConnection?
    var stopped = false
    init(client: NWConnection, queue: DispatchQueue, ip: String, mode: ProxyFixture.Mode, authenticated: Bool, record: @escaping (String?, Bool, Bool) -> Void) {
        self.client = client; self.queue = queue; self.ip = ip; self.mode = mode; self.authenticated = authenticated; self.record = record
    }
    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.mode == .tlsPassThrough { self.dial(reply: Data()) }
                else if self.mode == .socks5 { self.greeting() }
                else { self.header(Data()) }
            case .failed, .cancelled: self.stop()
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + 45) { [weak self] in self?.stop() }
        client.start(queue: queue)
    }
    func stop() { guard !stopped else { return }; stopped = true; client.cancel(); upstream?.cancel() }
    func send(_ data: Data, then: @escaping () -> Void) {
        client.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }; if error != nil { self.stop() } else { then() }
        })
    }
    func read(_ count: Int, then: @escaping (Data) -> Void) {
        client.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil, !complete, let data, data.count == count else { self.stop(); return }; then(data)
        }
    }
    func header(_ prior: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil, !complete, let data, prior.count + data.count <= 8192 else { self.stop(); return }
            var bytes = prior; bytes.append(data)
            guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else { self.header(bytes); return }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let line = text.components(separatedBy: "\r\n").first,
                  line == "CONNECT \(self.ip.contains(":") ? "[\(self.ip)]" : self.ip):443 HTTP/1.1" else { self.record(nil, false, true); self.stop(); return }
            self.record(self.ip + ":443", false, false)
            if self.mode == .hang { return }
            if self.mode == .reject { self.send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) { self.stop() }; return }
            if self.authenticated {
                let expected = "Basic " + Data("fixture:fixture-password".utf8).base64EncodedString()
                let actual = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("proxy-authorization:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard actual == expected else {
                    self.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"fixture\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) { self.stop() }; return
                }
                self.record(nil, true, false)
            }
            self.dial(reply: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        }
    }
    func greeting() {
        read(2) { prefix in
            guard prefix[0] == 5, prefix[1] > 0, prefix[1] <= 8 else { self.stop(); return }
            self.read(Int(prefix[1])) { methods in
                let choice: UInt8 = self.authenticated ? 2 : 0
                guard methods.contains(choice) else { self.stop(); return }
                self.send(Data([5, choice])) { if self.authenticated { self.socksAuthentication() } else { self.socksTarget() } }
            }
        }
    }
    func socksAuthentication() {
        read(2) { prefix in
            guard prefix[0] == 1, prefix[1] > 0 else { self.stop(); return }
            self.read(Int(prefix[1])) { username in
                self.read(1) { length in
                    self.read(Int(length[0])) { password in
                        let accepted = username == Data("fixture".utf8) && password == Data("fixture-password".utf8)
                        self.record(nil, accepted, false); self.send(Data([1, accepted ? 0 : 1])) { if accepted { self.socksTarget() } else { self.stop() } }
                    }
                }
            }
        }
    }
    func socksTarget() {
        read(4) { prefix in
            guard prefix[0] == 5, prefix[1] == 1, prefix[2] == 0, [1,4].contains(prefix[3]) else { self.record(nil, false, true); self.stop(); return }
            self.read((prefix[3] == 1 ? 4 : 16) + 2) { address in
                let ipBytes = Array(address.dropLast(2))
                guard ipBytes == Array(IPv4Address(self.ip)?.rawValue ?? IPv6Address(self.ip)!.rawValue), address.suffix(2) == Data([1,187]) else { self.record(nil, false, true); self.stop(); return }
                self.record(self.ip + ":443", false, false)
                self.dial(reply: Data([5,0,0,1,127,0,0,1,0,0]))
            }
        }
    }
    func dial(reply: Data) {
        let parameters = NWParameters.tcp; parameters.preferNoProxies = true
        let host: NWEndpoint.Host = IPv4Address(ip).map { .ipv4($0) } ?? .ipv6(IPv6Address(ip)!)
        let upstream = NWConnection(host: host, port: 443, using: parameters); self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.send(reply) { self.pipe(from: self.client, to: upstream); self.pipe(from: upstream, to: self.client) }
            case .failed, .cancelled: self.stop()
            default: break
            }
        }
        upstream.start(queue: queue)
    }
    func pipe(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { return }
            guard error == nil, let data, !data.isEmpty else { self.stop(); return }
            to.send(content: data, completion: .contentProcessed { error in
                if error != nil || complete { self.stop() } else { self.pipe(from: from, to: to) }
            })
        }
    }
}

struct ProxyFixtureCheckError: Error { let message: String }
private func proxyFixtureCheck(_ value: Bool, _ message: String) throws { if !value { throw ProxyFixtureCheckError(message: message) } }
func verifyProxyTransport() async throws -> (checks: [String], ip: String) {
        var passed: [String] = []
        let resolver = SystemPublicWebResolver()
        let valid = try await resolver.resolve(host: "badssl.com", timeout: 15)
        let wrong = try await resolver.resolve(host: "wrong.host.badssl.com", timeout: 15)
        guard let ip = valid.first(where: { wrong.contains($0) }) else { throw ProxyFixtureCheckError(message: "No shared public badssl address.") }
        let address = try PublicWebAddress("https://badssl.com/")
        let direct = try await ApplePublicWebConnector().exchange(address: address, ip: ip, timeout: 20, maximumBody: 262144)
        try proxyFixtureCheck(direct.status == 200, "Direct positive TLS control failed."); passed.append("direct-valid-origin-control")
        for (mode, scheme, auth, label) in [(ProxyFixture.Mode.connect, "http", false, "http-connect"), (.connect, "http", true, "authenticated-http-connect"), (.socks5, "socks5", false, "socks5"), (.socks5, "socks5", true, "authenticated-socks5")] {
            let fixture = try ProxyFixture(ip: ip, mode: mode, authenticated: auth); let port = try await fixture.start(); defer { fixture.stop() }
            let credentials = auth ? try SearchProxyCredentials(username: "fixture", password: "fixture-password") : nil
            let proxy = SearchProxy(endpoint: try SearchProxyEndpoint("\(scheme)://127.0.0.1:\(port)"), credentials: credentials)
            let connector = ApplePublicWebConnector(proxy: proxy)
            let result = try await connector.exchange(address: address, ip: ip, timeout: 20, maximumBody: 262144)
            try proxyFixtureCheck(result.status == 200 && String(decoding: result.body, as: UTF8.self).contains("badssl"), "Proxied origin control failed: \(label)")
            let observation = fixture.snapshot()
            try proxyFixtureCheck(observation.targets.contains(ip + ":443") && !observation.domainTarget && (!auth || observation.authenticated), "Proxy target/auth mismatch: \(label)")
            passed.append(label + "-checked-ip-and-original-host-tls")
            if mode == .connect && !auth {
                do { _ = try await connector.exchange(address: PublicWebAddress("https://wrong.host.badssl.com/"), ip: ip, timeout: 20, maximumBody: 65536); throw ProxyFixtureCheckError(message: "Mismatched TLS host accepted through CONNECT.") }
                catch let error as NWError { guard case .tls = error else { throw error }; passed.append("origin-hostname-mismatch-refused-through-connect") }
                let before = fixture.snapshot().connections
                do { _ = try await connector.exchange(address: address, ip: "127.0.0.1", timeout: 1, maximumBody: 65536); throw ProxyFixtureCheckError(message: "Private origin admitted through proxy.") }
                catch is PublicWebError { try proxyFixtureCheck(fixture.snapshot().connections == before, "Private origin contacted proxy."); passed.append("private-origin-refused-before-proxy") }
            }
        }
        for (mode, label) in [(ProxyFixture.Mode.reject, "refusal"), (.hang, "timeout"), (.tlsPassThrough, "proxy-tls-hostname-mismatch")] {
            let fixture = try ProxyFixture(ip: ip, mode: mode); let port = try await fixture.start(); defer { fixture.stop() }
            let proxy = SearchProxy(endpoint: try SearchProxyEndpoint("\(mode == .tlsPassThrough ? "https" : "http")://127.0.0.1:\(port)"))
            let connector = ApplePublicWebConnector(proxy: proxy)
            do { _ = try await connector.exchange(address: address, ip: ip, timeout: mode == .hang ? 0.5 : 10, maximumBody: 65536); throw ProxyFixtureCheckError(message: "Failed proxy fell back to direct: \(label)") }
            catch is ProxyFixtureCheckError { throw ProxyFixtureCheckError(message: "Failed proxy returned origin bytes: \(label)") }
            catch { try proxyFixtureCheck(fixture.snapshot().connections > 0, "Proxy was never contacted: \(label)"); passed.append(label + "-no-origin-content-or-direct-failover") }
        }
        for (mode, scheme) in [(ProxyFixture.Mode.connect, "http"), (.socks5, "socks5")] {
            let fixture = try ProxyFixture(ip: ip, mode: mode, authenticated: true); let port = try await fixture.start(); defer { fixture.stop() }
            let proxy = SearchProxy(endpoint: try SearchProxyEndpoint("\(scheme)://127.0.0.1:\(port)"), credentials: try SearchProxyCredentials(username: "fixture", password: "wrong-fixture-password"))
            do { _ = try await ApplePublicWebConnector(proxy: proxy).exchange(address: address, ip: ip, timeout: 2, maximumBody: 65536); throw ProxyFixtureCheckError(message: "Rejected credentials returned origin bytes.") }
            catch is ProxyFixtureCheckError { throw ProxyFixtureCheckError(message: "Rejected credentials fell back to direct.") }
            catch { let observed = fixture.snapshot(); try proxyFixtureCheck(observed.connections > 0 && !observed.authenticated, "Authentication refusal fixture was not reached."); passed.append(scheme + "-wrong-credentials-no-content-or-direct-fallback") }
        }
        let hanging = try ProxyFixture(ip: ip, mode: .hang); let port = try await hanging.start(); defer { hanging.stop() }
        let connector = ApplePublicWebConnector(proxy: SearchProxy(endpoint: try SearchProxyEndpoint("http://127.0.0.1:\(port)")))
        let task = Task { try await connector.exchange(address: address, ip: ip, timeout: 10, maximumBody: 65536) }
        for _ in 0..<100 { if hanging.snapshot().connections > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try proxyFixtureCheck(hanging.snapshot().connections > 0, "Cancellation fixture never contacted."); task.cancel()
        do { _ = try await task.value; throw ProxyFixtureCheckError(message: "Cancelled proxy returned content.") }
        catch is CancellationError { passed.append("proxy-connection-cancelled-without-content") }
    return (passed, ip)
}
