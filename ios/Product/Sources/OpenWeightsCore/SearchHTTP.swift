import Foundation

public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case duckduckgo, brave, yahoo, context7
    public var label: String {
        switch self { case .duckduckgo: return "DuckDuckGo"; case .brave: return "Brave"; case .yahoo: return "Yahoo"; case .context7: return "Context7" }
    }
    var hosts: Set<String> {
        switch self {
        case .duckduckgo: return ["duckduckgo.com", "html.duckduckgo.com", "lite.duckduckgo.com"]
        case .brave: return ["search.brave.com"]
        case .yahoo: return ["search.yahoo.com"]
        case .context7: return ["context7.com"]
        }
    }
    var cookieDomain: String {
        switch self { case .duckduckgo: return "duckduckgo.com"; case .brave: return "brave.com"; case .yahoo: return "yahoo.com"; case .context7: return "context7.com" }
    }
}

public struct SearchHTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }
    public let engine: SearchEngine
    public let address: PublicWebAddress
    public let method: Method
    public let headers: [String: String]
    public let body: Data
    public init(engine: SearchEngine, url: String, method: Method = .get, headers: [String: String] = [:], body: Data = Data()) throws {
        let address = try PublicWebAddress(url)
        guard engine.hosts.contains(address.host), address.port == 443 else { throw PublicWebError.refused("Search requests are limited to the selected provider's named HTTPS hosts.") }
        guard body.count <= 16_384, method == .post || body.isEmpty else { throw PublicWebError.refused("The search request body is invalid or too large.") }
        let allowed: Set<String> = ["user-agent", "accept", "content-type", "referer", "cookie"]
        var normalized: [String: String] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            guard allowed.contains(key), normalized[key] == nil, value.utf8.count <= 4096,
                  value.utf8.allSatisfy({ (32...126).contains($0) }) else { throw PublicWebError.refused("The search request headers are invalid.") }
            if key == "referer" {
                let source = try PublicWebAddress(value)
                guard engine.hosts.contains(source.host), source.port == 443 else { throw PublicWebError.refused("The search referrer must belong to its provider.") }
            }
            normalized[key] = value
        }
        self.engine = engine; self.address = address; self.method = method; self.headers = normalized; self.body = body
    }
    public var encoded: Data {
        var request = "\(method.rawValue) \(address.target) HTTP/1.1\r\nHost: \(address.host)\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { request += "\(name): \(value)\r\n" }
        if headers["user-agent"] == nil { request += "User-Agent: OpenWeights/1.0\r\n" }
        if method == .post { request += "Content-Length: \(body.count)\r\n" }
        var data = Data((request + "\r\n").utf8); data.append(body); return data
    }
    func redirected(_ destination: PublicWebAddress, status: Int) throws -> SearchHTTPRequest {
        let changesToGet = status == 303 || ([301, 302].contains(status) && method == .post)
        var headers = headers
        // Response cookies are reselected per hop. Explicit provider preferences stay on the same host.
        if destination.host != address.host { headers.removeValue(forKey: "cookie") }
        if changesToGet { headers.removeValue(forKey: "content-type") }
        return try SearchHTTPRequest(engine: engine, url: destination.url.absoluteString, method: changesToGet ? .get : method, headers: headers, body: changesToGet ? Data() : body)
    }
    public static func form(_ pairs: [(String, String)]) -> String {
        func encode(_ value: String) -> String {
            value.utf8.map { byte -> String in
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,42].contains(byte) { return String(UnicodeScalar(byte)) }
                return byte == 32 ? "+" : String(format: "%%%02X", byte)
            }.joined()
        }
        return pairs.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }
}

public protocol SearchHTTPConnecting: Sendable {
    func exchangeSearch(_ request: SearchHTTPRequest, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse
}
public protocol SearchHTTPTransport: Sendable {
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse
}

public actor SearchHTTPClient: SearchHTTPTransport {
    private let resolver: any PublicWebResolving
    private let connector: any SearchHTTPConnecting
    private struct StoredCookie { let cookie: HTTPCookie; let hostOnly: Bool }
    private var cookies: [SearchEngine: [StoredCookie]] = [:]
    public init(resolver: any PublicWebResolving = SystemPublicWebResolver(), connector: any SearchHTTPConnecting = ApplePublicWebConnector()) {
        self.resolver = resolver; self.connector = connector
    }
    public func send(_ initial: SearchHTTPRequest, timeout: TimeInterval = 30) async throws -> WebHTTPResponse {
        var request = initial; var visited: [URL] = []
        let end = ProcessInfo.processInfo.systemUptime + min(60, max(1, timeout.isFinite ? timeout : 30))
        func remaining() throws -> TimeInterval {
            let value = end - ProcessInfo.processInfo.systemUptime
            guard value > 0 else { throw PublicWebError.refused("The search request timed out.") }; return value
        }
        while true {
            try Task.checkCancellation()
            guard visited.count < 6, !visited.contains(request.address.url) else { throw PublicWebError.refused("The search provider redirected too many times or in a loop.") }
            visited.append(request.address.url)
            var headers = request.headers
            if let cookie = cookieHeader(engine: request.engine, address: request.address), headers["cookie"] == nil { headers["cookie"] = cookie }
            let outgoing = try SearchHTTPRequest(engine: request.engine, url: request.address.url.absoluteString, method: request.method, headers: headers, body: request.body)
            let addresses = try await resolver.resolve(host: request.address.host, timeout: min(10, try remaining()))
            try Task.checkCancellation()
            let publicIPs = Array(NSOrderedSet(array: addresses.filter(PublicWebIP.isPublic))).compactMap { $0 as? String }.prefix(8)
            guard !publicIPs.isEmpty else { throw PublicWebError.refused("The search provider did not resolve to a public address.") }
            var response: WebHTTPResponse?; var failure: Error?
            for ip in publicIPs {
                try Task.checkCancellation()
                do { response = try await connector.exchangeSearch(outgoing, ip: ip, timeout: min(15, try remaining()), maximumBody: 1_048_576); break }
                catch { if error is CancellationError { throw error }; failure = error }
            }
            guard let response else { throw failure ?? PublicWebError.refused("The search provider could not be reached.") }
            try Task.checkCancellation()
            saveCookies(response, engine: request.engine, address: request.address)
            if [301,302,303,307,308].contains(response.status) {
                guard let location = response.headers["location"] else { throw PublicWebError.refused("The search redirect has no destination.") }
                request = try request.redirected(request.address.redirected(to: location), status: response.status)
                continue
            }
            return response
        }
    }
    private func saveCookies(_ response: WebHTTPResponse, engine: SearchEngine, address: PublicWebAddress) {
        var current = cookies[engine] ?? []
        let fields = response.setCookieHeaders.isEmpty ? response.headers["set-cookie"].map { [$0] } ?? [] : response.setCookieHeaders
        for field in fields.prefix(32) {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": field], for: address.url) {
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                guard cookie.name.utf8.count + cookie.value.utf8.count <= 2048,
                      domain == engine.cookieDomain || domain.hasSuffix("." + engine.cookieDomain),
                      address.host == domain || address.host.hasSuffix("." + domain) else { continue }
                current.removeAll { $0.cookie.name == cookie.name && $0.cookie.domain == cookie.domain && $0.cookie.path == cookie.path }
                if cookie.expiresDate.map({ $0 > Date() }) ?? true { current.append(StoredCookie(cookie: cookie, hostOnly: !field.split(separator: ";").dropFirst().contains { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "domain" })) }
            }
        }
        cookies[engine] = Array(current.suffix(64))
    }
    private func cookieHeader(engine: SearchEngine, address: PublicWebAddress) -> String? {
        let matches = (cookies[engine] ?? []).filter { stored in
            let cookie = stored.cookie
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let domainMatches = !stored.hostOnly ? address.host == domain || address.host.hasSuffix("." + domain) : address.host == domain
            let path = address.url.path.isEmpty ? "/" : address.url.path
            let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).first == "/"))
            return domainMatches && pathMatches && (cookie.expiresDate.map({ $0 > Date() }) ?? true)
        }
        return matches.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: matches.map(\.cookie))["Cookie"]
    }
}
