import Foundation
import Network
import Security

/// A user-selected hop. It is never supplied by a model or page and never changes origin validation.
public struct SearchProxyEndpoint: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case http, https, socks5 }
    public let kind: Kind
    public let host: String
    public let port: UInt16
    public init(_ text: String) throws {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 1024, !raw.contains("%"), raw.utf8.allSatisfy({ (33...126).contains($0) }),
              let url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(),
              let parsed = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let port = url.port, (1...65535).contains(port) else { throw Self.invalid() }
        let host = parsed.hasPrefix("[") && parsed.hasSuffix("]") ? String(parsed.dropFirst().dropLast()) : parsed
        guard !host.isEmpty, !host.contains("%"), host.utf8.count <= 253,
              PublicWebIP.bytes(host) != nil || host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                  label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { throw Self.invalid() }
        switch scheme {
        case "http": kind = .http
        case "https": kind = .https
        case "socks", "socks5", "socks5h": kind = .socks5
        default: throw Self.invalid()
        }
        self.host = host; self.port = UInt16(port)
    }
    public var description: String { kind.rawValue + "://" + (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
    private static func invalid() -> PublicWebError { .refused("Use http://host:port, https://host:port or socks5://host:port. Enter credentials in the separate fields.") }
}

public struct SearchProxyCredentials: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String
    public init(username: String, password: String) throws {
        guard !username.isEmpty, username.utf8.count <= 255, password.utf8.count <= 255,
              !username.contains(":"), (username + password).unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PublicWebError.refused("Proxy credentials need a username without colons or control characters and at most 255 bytes per field.")
        }
        self.username = username; self.password = password
    }
    public var description: String { "[proxy credentials]" }
    public var debugDescription: String { description }
}

public struct SearchProxy: Equatable, Sendable, CustomStringConvertible {
    public let endpoint: SearchProxyEndpoint
    public let credentials: SearchProxyCredentials?
    public init(endpoint: SearchProxyEndpoint, credentials: SearchProxyCredentials? = nil) { self.endpoint = endpoint; self.credentials = credentials }
    public var description: String { endpoint.description }
    func configuration() -> ProxyConfiguration {
        let hop = NWEndpoint.hostPort(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!)
        var config: ProxyConfiguration
        switch endpoint.kind {
        case .http: config = ProxyConfiguration(httpCONNECTProxy: hop)
        case .https:
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            endpoint.host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
            config = ProxyConfiguration(httpCONNECTProxy: hop, tlsOptions: tls)
        case .socks5: config = ProxyConfiguration(socksv5Proxy: hop)
        }
        config.allowFailover = false
        if let credentials { config.applyCredential(username: credentials.username, password: credentials.password) }
        return config
    }
}

public protocol SearchProxyCredentialStoring: Sendable {
    func read(for endpoint: SearchProxyEndpoint) throws -> SearchProxyCredentials?
    func save(_ credentials: SearchProxyCredentials?, for endpoint: SearchProxyEndpoint?) throws
}
public struct AppleSearchProxyCredentialStore: SearchProxyCredentialStoring {
    private let service: String
    public init(service: String = "org.experimentalmachines.openweights.search-proxy") { self.service = service }
    private struct Stored: Codable { let endpoint: String; let credentials: SearchProxyCredentials }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "credentials"] }
    public func read(for endpoint: SearchProxyEndpoint) throws -> SearchProxyCredentials? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let decoded = try? JSONDecoder().decode(Stored.self, from: data), decoded.endpoint == endpoint.description,
              let checked = try? SearchProxyCredentials(username: decoded.credentials.username, password: decoded.credentials.password) else {
            throw PublicWebError.refused("Keychain could not read the proxy credential. Search stays on its configured route. Save or remove the proxy under Tools.")
        }
        return checked
    }
    public func save(_ credentials: SearchProxyCredentials?, for endpoint: SearchProxyEndpoint?) throws {
        let query = query
        guard let credentials else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PublicWebError.refused("Keychain could not remove the proxy credential.") }; return
        }
        guard let endpoint else { throw PublicWebError.refused("The proxy credential needs its matching address.") }
        let data = try JSONEncoder().encode(Stored(endpoint: endpoint.description, credentials: credentials))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw PublicWebError.refused("Keychain could not save the proxy credential.") }
        } else if status != errSecSuccess { throw PublicWebError.refused("Keychain could not update the proxy credential.") }
    }
}

/// Keeps provider cookies in one route only. A changed hop or credential creates a fresh cookie jar.
public actor SearchProxyTransport: SearchHTTPTransport {
    private let factory: @Sendable (SearchProxy?) -> any SearchHTTPTransport
    private var proxy: SearchProxy?
    private var transport: any SearchHTTPTransport
    public init(factory: @escaping @Sendable (SearchProxy?) -> any SearchHTTPTransport = { SearchHTTPClient(connector: ApplePublicWebConnector(proxy: $0)) }) {
        self.factory = factory; transport = factory(nil)
    }
    public func configure(_ proxy: SearchProxy?) {
        if self.proxy != proxy { transport = factory(proxy); self.proxy = proxy }
    }
    public func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        let snapshot = transport
        return try await snapshot.send(request, timeout: timeout)
    }
}
