import Foundation
import OpenWeightsCore

private final class ProxyVaultFixture: SearchProxyCredentialStoring, @unchecked Sendable {
    let lock = NSLock(); var stored: SearchProxyCredentials?; var address: String?; var unavailable = false
    func read(for endpoint: SearchProxyEndpoint) throws -> SearchProxyCredentials? { try lock.withLock { if unavailable { throw CheckFailure("Fixture Keychain unavailable.") }; guard address == nil || address == endpoint.description else { throw CheckFailure("Fixture credential address mismatch.") }; return stored } }
    func save(_ credentials: SearchProxyCredentials?, for endpoint: SearchProxyEndpoint?) throws { try lock.withLock { if unavailable { throw CheckFailure("Fixture Keychain unavailable.") }; stored = credentials; address = endpoint?.description } }
    func fail() { lock.withLock { unavailable = true } }
    func forget() { lock.withLock { stored = nil } }
}
private actor ProxyProviderFixture: SearchHTTPTransport {
    var count = 0
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        count += 1
        if request.address.url.path == "/" { return WebHTTPResponse(status: 200, headers: [:], body: Data("vqd='4-123'".utf8)) }
        return WebHTTPResponse(status: 200, headers: [:], body: Data("{\"results\":[{\"title\":\"Cedar\",\"thumbnail\":\"https://example.com/image.png\",\"image\":\"https://example.com/full.png\",\"url\":\"https://example.com/source\"}]}".utf8))
    }
}
private final class ProxyRouteLog: @unchecked Sendable {
    let lock = NSLock(); var names: [String] = []; let provider = ProxyProviderFixture()
    func make(_ proxy: SearchProxy?) -> any SearchHTTPTransport { lock.withLock { names.append(proxy?.description ?? "direct") }; return provider }
    func snapshot() -> [String] { lock.withLock { names } }
}
private struct ProxyPageResolver: PublicWebResolving { func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] } }
private actor ProxyPageConnector: PublicWebConnecting {
    var count = 0
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        count += 1; return WebHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<html><body>A directly fetched public page.</body></html>".utf8))
    }
}
extension ControllerChecks {
    @MainActor static func proxyChecks(_ passed: inout [String]) async throws {
        let suite = "proxy-controller-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let vault = ProxyVaultFixture(); let routes = ProxyRouteLog(); let route = SearchProxyTransport(factory: { routes.make($0) })
        let pages = ProxyPageConnector(); let web = WebController(defaults: defaults, client: PublicWebClient(resolver: ProxyPageResolver(), connector: pages), proxyCredentials: vault, searchRoute: route)
        let credentials = try SearchProxyCredentials(username: "fixture", password: "fixture-password")
        try web.saveProxy(address: "http://proxy.example:8080", credentials: credentials)
        let serialized = String(describing: defaults.dictionaryRepresentation())
        try require(!serialized.contains(credentials.username) && !serialized.contains(credentials.password) && web.proxyHasCredentials, "Proxy credentials escaped to preferences.")
        let reopened = WebController(defaults: defaults, proxyCredentials: vault, searchRoute: route)
        try require(reopened.proxyAddress == web.proxyAddress && reopened.proxyHasCredentials && reopened.proxyDisclosure.contains("proxy.example:8080"), "Proxy metadata or disclosure did not reopen.")
        try reopened.saveProxy(address: reopened.proxyAddress, keepSavedCredentials: true)
        passed.append("proxy-address-auth-flag-and-disclosure-reopen-with-credentials-confined-to-vault")

        do { try web.saveProxy(address: "http://other.example:8080", keepSavedCredentials: true); throw CheckFailure("Credentials reused on new proxy.") }
        catch is PublicWebError { }
        do { try web.saveProxy(address: "http://fixture:fixture-password@other.example:8080"); throw CheckFailure("Inline credentials persisted.") }
        catch is PublicWebError { }
        try require(web.proxyAddress == "http://proxy.example:8080" && vault.read(for: SearchProxyEndpoint(web.proxyAddress)) == credentials, "Invalid save replaced the prior route or credentials.")
        passed.append("invalid-address-and-credential-reuse-on-a-new-hop-do-not-change-saved-route")

        web.mediaEnabled = true
        let media = AgentToolCall(id: "proxy-media", name: "show_pictures", argumentsJSON: "{\"query\":\"Cedar\"}")
        _ = await web.execute(media, mode: .auto, approval: nil, workspace: nil, unattended: true)
        try require(await routes.provider.count == 0, "Unattended media used proxy.")
        let page = AgentToolCall(id: "proxy-page", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\"}")
        web.fetchEnabled = true; await web.beginTurn(carriesUntrustedText: false)
        let fetched = await web.execute(page, mode: .auto, approval: nil, workspace: nil)
        let directPages = await pages.count; let directSearches = await routes.provider.count
        try require(!fetched.rejected && directPages == 1 && directSearches == 0, "Fetched page went through search proxy.")
        passed.append("page-fetch-stays-on-its-own-direct-client-and-unattended-media-does-not-egress")

        let preparedRoutes = routes.snapshot()
        vault.forget()
        let search = AgentToolCall(id: "proxy-search", name: "web_search", argumentsJSON: "{\"query\":\"Cedar\"}")
        let missing = await web.execute(search, mode: .auto, approval: nil, workspace: nil)
        let missingRequests = await routes.provider.count
        try require(missing.rejected && missingRequests == 0 && routes.snapshot() == preparedRoutes, "Missing credential contacted provider.")
        passed.append("missing-saved-proxy-credential-fails-before-provider-without-direct-fallback")

        vault.fail()
        do { try web.saveProxy(address: ""); throw CheckFailure("Keychain failure removed proxy metadata.") }
        catch is CheckFailure { }
        let unavailable = await web.execute(search, mode: .auto, approval: nil, workspace: nil)
        let unavailableRequests = await routes.provider.count
        try require(unavailable.rejected && web.proxyAddress == "http://proxy.example:8080" && unavailableRequests == 0, "Vault failure caused direct egress or lost saved proxy.")
        await web.beginTurn(carriesUntrustedText: false)
        let unaffected = await web.execute(page, mode: .auto, approval: nil, workspace: nil)
        let unaffectedPages = await pages.count
        try require(!unaffected.rejected && unaffectedPages == 2, "Search credential failure disabled unrelated page fetching.")
        passed.append("vault-failure-retains-route-fails-search-closed-and-leaves-page-fetch-usable")

        let removalSuite = "proxy-removal-" + UUID().uuidString; let removalDefaults = UserDefaults(suiteName: removalSuite)!; defer { removalDefaults.removePersistentDomain(forName: removalSuite) }
        let removalVault = ProxyVaultFixture(); let removal = WebController(defaults: removalDefaults, proxyCredentials: removalVault)
        try removal.saveProxy(address: "socks5://proxy.example:1080", credentials: credentials)
        try removal.saveProxy(address: "")
        try require(removal.proxyAddress.isEmpty && !removal.proxyHasCredentials && removalVault.read(for: SearchProxyEndpoint("socks5://proxy.example:1080")) == nil && removalDefaults.string(forKey: "tools.web.proxy.address") == "", "Removing proxy left credentials or routing metadata.")
        passed.append("explicit-proxy-removal-clears-vault-and-restores-direct-route-metadata")
    }
}
