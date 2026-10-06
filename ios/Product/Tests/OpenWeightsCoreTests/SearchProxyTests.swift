import XCTest
@testable import OpenWeightsCore

private actor ProxyRouteFixture: SearchHTTPTransport {
    let name: String
    init(_ name: String) { self.name = name }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse { WebHTTPResponse(status: 200, headers: [:], body: Data(name.utf8)) }
}
private final class ProxyFactoryLog: @unchecked Sendable {
    let lock = NSLock(); var values: [String] = []
    func make(_ proxy: SearchProxy?) -> any SearchHTTPTransport {
        let name = proxy?.description ?? "direct"
        lock.withLock { values.append(name) }; return ProxyRouteFixture(name)
    }
    func snapshot() -> [String] { lock.withLock { values } }
}
final class SearchProxyTests: XCTestCase {
    func testExplicitSchemesPortsIPv6AndCredentialSeparation() throws {
        XCTAssertEqual(try SearchProxyEndpoint(" HTTP://proxy.example:8080/ ").description, "http://proxy.example:8080")
        XCTAssertEqual(try SearchProxyEndpoint("https://proxy.example:8443").kind, .https)
        XCTAssertEqual(try SearchProxyEndpoint("socks5h://[::1]:1080").description, "socks5://[::1]:1080")
        XCTAssertEqual(try SearchProxyEndpoint("socks://127.0.0.1:1080").kind, .socks5)
        for value in ["proxy.example:8080", "ftp://example.com:1", "http://example.com", "http://example.com:0", "http://example.com:65536", "http://example.com:1/path", "http://example.com:1?q=secret", "http://example.com:1#x", "http://user:secret@example.com:1", "http://exa mple.com:1", "http://%65xample.com:1", "http://[fe80::1%25en0]:1", "http://-invalid.example:1"] {
            XCTAssertThrowsError(try SearchProxyEndpoint(value), value)
        }
    }
    func testCredentialBoundsAndSafeDescriptions() throws {
        let credentials = try SearchProxyCredentials(username: "fixture", password: "fixture-password")
        let proxy = SearchProxy(endpoint: try SearchProxyEndpoint("http://proxy.example:8080"), credentials: credentials)
        XCTAssertFalse(String(describing: credentials).contains(credentials.password))
        XCTAssertFalse(String(reflecting: credentials).contains(credentials.username))
        XCTAssertEqual(String(describing: proxy), "http://proxy.example:8080")
        for (name, password) in [("", "p"), ("a:b", "p"), ("a\n", "p"), ("a", "p\r"), (String(repeating: "x", count: 256), "p"), ("a", String(repeating: "x", count: 256))] {
            XCTAssertThrowsError(try SearchProxyCredentials(username: name, password: password))
        }
    }
    func testAppleConfigurationsForbidDirectFailover() throws {
        for address in ["http://proxy.example:8080", "https://proxy.example:8443", "socks5://proxy.example:1080"] {
            XCTAssertFalse(SearchProxy(endpoint: try SearchProxyEndpoint(address)).configuration().allowFailover)
        }
    }
    func testChangedRouteAndCredentialsReplaceTransportButSameRouteRetainsIt() async throws {
        let log = ProxyFactoryLog(); let route = SearchProxyTransport(factory: { log.make($0) })
        let request = try SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/")
        let direct = try await route.send(request, timeout: 1)
        XCTAssertEqual(direct.body, Data("direct".utf8))
        let endpoint = try SearchProxyEndpoint("http://proxy.example:8080")
        let proxy = SearchProxy(endpoint: endpoint)
        await route.configure(proxy); await route.configure(proxy)
        let response = try await route.send(request, timeout: 1)
        XCTAssertEqual(response.body, Data(endpoint.description.utf8))
        await route.configure(SearchProxy(endpoint: endpoint, credentials: try SearchProxyCredentials(username: "fixture", password: "fixture-password")))
        await route.configure(nil)
        XCTAssertEqual(log.snapshot(), ["direct", endpoint.description, endpoint.description, "direct"])
    }
}
