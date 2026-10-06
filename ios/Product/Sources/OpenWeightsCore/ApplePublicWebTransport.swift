import Darwin
import Foundation
import Network
import Security

public struct SystemPublicWebResolver: PublicWebResolving {
    public init() {}
    public func resolve(host: String, timeout: TimeInterval) async throws -> [String] {
        try Task.checkCancellation()
        if PublicWebIP.bytes(host) != nil { return PublicWebIP.isPublic(host) ? [host] : [] }
        let gate = WebResolutionGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(30, max(0.01, timeout))) {
                    gate.finish(.failure(PublicWebError.refused("Public host resolution timed out.")))
                }
                DispatchQueue.global(qos: .utility).async {
                    guard !gate.finished else { return }
                    var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
                    var result: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                        gate.finish(.failure(PublicWebError.refused("The public host could not be resolved."))); return
                    }
                    defer { freeaddrinfo(first) }
                    var pointer: UnsafeMutablePointer<addrinfo>? = first; var addresses: [String] = []
                    while let current = pointer {
                        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let address = String(cString: name)
                            if PublicWebIP.isPublic(address), !addresses.contains(address) { addresses.append(address) }
                        }
                        pointer = current.pointee.ai_next
                    }
                    gate.finish(.success(Array(addresses.prefix(8))))
                }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }
}

// getaddrinfo itself cannot be interrupted. Its late result must not start a connection.
private final class WebResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<[String], Error>?
    private var continuation: CheckedContinuation<[String], Error>?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return settled != nil }
    func install(_ value: CheckedContinuation<[String], Error>) {
        lock.lock(); let result = settled
        if result == nil { continuation = value }
        lock.unlock()
        if let result { value.resume(with: result) }
    }
    func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = result; let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: result)
    }
}

public struct ApplePublicWebConnector: PublicWebConnecting, SearchHTTPConnecting {
    private let observe: (@Sendable (String) -> Void)?
    private let proxy: SearchProxy?
    public init(proxy: SearchProxy? = nil, observe: (@Sendable (String) -> Void)? = nil) { self.proxy = proxy; self.observe = observe }
    public func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        try await exchange(address: address, request: address.request, ip: ip, timeout: timeout, maximumBody: maximumBody, allowsTextPrefix: true)
    }
    public func exchangeSearch(_ request: SearchHTTPRequest, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        try await exchange(address: request.address, request: request.encoded, ip: ip, timeout: timeout, maximumBody: maximumBody, allowsTextPrefix: false)
    }
    private func exchange(address: PublicWebAddress, request: Data, ip: String, timeout: TimeInterval, maximumBody: Int, allowsTextPrefix: Bool) async throws -> WebHTTPResponse {
        guard PublicWebIP.isPublic(ip) else { throw PublicWebError.refused("A nonpublic connection was refused.") }
        let endpoint: NWEndpoint.Host
        if let ipv4 = IPv4Address(ip) { endpoint = .ipv4(ipv4) }
        else if let ipv6 = IPv6Address(ip) { endpoint = .ipv6(ipv6) }
        else { throw PublicWebError.refused("The checked connection address is invalid.") }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // Keep system trust verification against the URL host while dialing the checked IP.
        address.host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if let proxy {
            let context = NWParameters.PrivacyContext(description: "OpenWeights selected search proxy")
            context.proxyConfigurations = [proxy.configuration()]
            parameters.setPrivacyContext(context)
        }
        let connection = NWConnection(host: endpoint, port: NWEndpoint.Port(rawValue: address.port)!, using: parameters)
        let operation = WebConnectionOperation(connection: connection, maximumBody: maximumBody, allowsTextPrefix: allowsTextPrefix, observe: observe)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.run(request: request, timeout: timeout)
        } onCancel: { operation.cancel() }
    }
}

private final class WebConnectionOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.experimentalmachines.openweights.public-web")
    private let connection: NWConnection
    private var decoder: WebHTTPResponseDecoder
    private var continuation: CheckedContinuation<WebHTTPResponse, Error>?
    private var finished = false
    private var stopped = false
    private var sent = false
    private let observe: (@Sendable (String) -> Void)?
    init(connection: NWConnection, maximumBody: Int, allowsTextPrefix: Bool, observe: (@Sendable (String) -> Void)?) {
        self.connection = connection; self.decoder = WebHTTPResponseDecoder(maximumBody: maximumBody, allowsTextPrefix: allowsTextPrefix); self.observe = observe
    }
    func cancel() { queue.async { self.stopped = true; self.finish(.failure(CancellationError())) } }
    func run(request: Data, timeout: TimeInterval) async throws -> WebHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                if self.stopped { continuation.resume(throwing: CancellationError()); self.continuation = nil; return }
                self.connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.finished else { return }
                    self.observe?("Connection state: \(state)")
                    switch state {
                    case .ready:
                        guard !self.sent else { return }; self.sent = true
                        self.connection.send(content: request, completion: .contentProcessed { [weak self] error in
                            guard let self, !self.finished else { return }
                            if let error { self.finish(.failure(error)) } else { self.observe?("Request sent"); self.receive() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    case .waiting(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                self.queue.asyncAfter(deadline: .now() + min(60, max(0.01, timeout))) { [weak self] in
                    self?.finish(.failure(PublicWebError.refused("The public page connection timed out.")))
                }
                self.connection.start(queue: self.queue)
            }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            self.observe?("Received \(data?.count ?? 0) bytes, EOF \(complete)")
            if let error { self.finish(.failure(error)); return }
            do {
                if let response = try self.decoder.append(data ?? Data(), endOfStream: complete) { self.finish(.success(response)) }
                else if complete { self.finish(.failure(PublicWebError.refused("The public page was incomplete."))) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<WebHTTPResponse, Error>) {
        guard !finished else { return }; finished = true
        connection.stateUpdateHandler = nil; connection.cancel()
        let callback = continuation; continuation = nil; callback?.resume(with: result)
    }
}
