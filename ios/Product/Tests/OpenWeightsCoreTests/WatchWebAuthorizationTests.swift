import XCTest
@testable import OpenWeightsCore

private actor WatchWebResolver: PublicWebResolving {
    var hosts: [String] = []
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { hosts.append(host); return ["8.8.8.8"] }
}
private actor WatchWebConnector: PublicWebConnecting {
    var requests: [String] = []
    let redirect: Bool
    init(redirect: Bool = false) { self.redirect = redirect }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        requests.append(address.url.absoluteString)
        if redirect && address.target == "/page" { return WebHTTPResponse(status: 302, headers: ["location": "https://other.example.com/status"], body: Data()) }
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar status unchanged".utf8))
    }
}
final class WatchWebAuthorizationTests: XCTestCase {
    func testAuthorizationValidatesBoundsAndExactOutboundInputs() throws {
        let value = try WatchWebAuthorization(pages: ["<example.com/page.>"], queries: [" Cedar status "], providers: [.duckduckgo], proxyAddress: "socks5h://proxy.example:1080")
        XCTAssertEqual(value.pages, ["https://example.com/page"]); XCTAssertEqual(value.queries, ["Cedar status"])
        XCTAssertEqual(value.proxyAddress, "socks5://proxy.example:1080"); try value.validate()
        XCTAssertTrue(value.allowsPage(try PublicWebAddress("https://example.com/page")))
        XCTAssertFalse(value.allowsPage(try PublicWebAddress("https://example.com/page?private=secret")))
        XCTAssertTrue(value.allowsQuery("Cedar status", providers: [.duckduckgo]))
        XCTAssertFalse(value.allowsQuery("Cedar status secret", providers: [.duckduckgo]))
        XCTAssertFalse(value.allowsQuery("Cedar status", providers: [.brave]))
        for pages in [[], ["https://127.0.0.1/"], ["https://linkedin.com/in/a"], ["https://example.com/", "example.com/"], Array(repeating: "https://example.com/", count: 9)] {
            XCTAssertThrowsError(try WatchWebAuthorization(pages: pages, queries: []))
        }
        for query in ["", " ", "x\nsecret", String(repeating: "x", count: 121)] { XCTAssertThrowsError(try WatchWebAuthorization(pages: [], queries: [query], providers: [.duckduckgo])) }
        XCTAssertThrowsError(try WatchWebAuthorization(pages: [], queries: ["Cedar"], providers: []))
    }
    func testAuthorizationSurvivesReopenAndOldSnapshotsHaveNoGrant() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watches.json"), now = Date()
        let store = try WatchStore(file: file)
        let authorization = try WatchWebAuthorization(pages: ["https://example.com/page"], queries: ["Cedar status"], providers: [.duckduckgo])
        let saved = try await store.start(task: "Check Cedar", everyMinutes: 1, at: now, webAuthorization: authorization)
        let reopened = try WatchStore(file: file); let value = await reopened.watch(saved.id)
        XCTAssertEqual(value?.webAuthorization, authorization)
        let claim = try await reopened.begin(saved.id, at: now.addingTimeInterval(61)); let ticket = try XCTUnwrap(claim)
        _ = try await reopened.edit(saved.id, task: "Check something else", everyMinutes: 1, at: now.addingTimeInterval(62))
        let late = try await reopened.record(ticket, outcome: .checked, summary: "Old result", at: now.addingTimeInterval(63), changed: true)
        let edited = await reopened.watch(saved.id); XCTAssertNil(edited?.webAuthorization); XCTAssertNil(late)
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var watches = try XCTUnwrap(old["watches"] as? [[String: Any]]); watches[0].removeValue(forKey: "webAuthorization"); old["watches"] = watches
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let legacy = try WatchStore(file: file); let loaded = await legacy.watch(saved.id); XCTAssertNil(loaded?.webAuthorization)
    }
    func testForgedStoredAuthorizationFailsWithoutOverwritingSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watches.json"), store = try WatchStore(file: file)
        _ = try await store.start(task: "Check", everyMinutes: 1, webAuthorization: WatchWebAuthorization(pages: ["https://example.com/"], queries: []))
        var snapshot = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var watches = try XCTUnwrap(snapshot["watches"] as? [[String: Any]])
        watches[0]["webAuthorization"] = ["pages": ["https://127.0.0.1/"], "queries": [], "providers": [], "proxyAddress": ""]
        snapshot["watches"] = watches; let corrupt = try JSONSerialization.data(withJSONObject: snapshot); try corrupt.write(to: file)
        XCTAssertThrowsError(try WatchStore(file: file)); XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testApprovedRepeatedPageWorksAfterPrivateFindingsButOtherAddressesAndSavesRefuse() async throws {
        let resolver = WatchWebResolver(), connector = WatchWebConnector()
        let tools = WebTools(client: PublicWebClient(resolver: resolver, connector: connector))
        let authorization = try WatchWebAuthorization(pages: ["https://example.com/page"], queries: [])
        var settings = WebToolSettings(); settings.fetchEnabled = true
        let call = AgentToolCall(id: "page", name: "fetch_url", argumentsJSON: "{\"link\":\"example.com/page\",\"find\":\"Cedar\"}")
        for _ in 0..<2 {
            await tools.beginTurn(carriesUntrustedText: true, carriesPrivateData: true)
            let result = await tools.execute(call, settings: settings, unattended: true, watchAuthorization: authorization)
            XCTAssertFalse(result.rejected); XCTAssertTrue(result.text.contains("Cedar"))
        }
        for args in ["{\"url\":\"https://example.com/page?private=secret\"}", "{\"url\":\"https://example.com/page\",\"saveTo\":\"page.txt\"}"] {
            let result = await tools.execute(AgentToolCall(id: "bad", name: "fetch_url", argumentsJSON: args), settings: settings, unattended: true, watchAuthorization: authorization); XCTAssertTrue(result.rejected)
        }
        settings.fetchEnabled = false
        let disabled = await tools.execute(call, settings: settings, unattended: true, watchAuthorization: authorization); XCTAssertTrue(disabled.rejected)
        let requests = await connector.requests; XCTAssertEqual(requests.count, 2)
        settings.fetchEnabled = true
        let interactive = await tools.execute(call, settings: settings, watchAuthorization: authorization); XCTAssertTrue(interactive.rejected)
    }
    func testRedirectMustBeIndependentlyApprovedBeforeDNS() async throws {
        let resolver = WatchWebResolver(), connector = WatchWebConnector(redirect: true)
        let tools = WebTools(client: PublicWebClient(resolver: resolver, connector: connector))
        var settings = WebToolSettings(); settings.fetchEnabled = true
        let call = AgentToolCall(id: "redirect", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/page\"}")
        let limited = try WatchWebAuthorization(pages: ["https://example.com/page"], queries: [])
        let refused = await tools.execute(call, settings: settings, unattended: true, watchAuthorization: limited); XCTAssertTrue(refused.rejected)
        let hosts = await resolver.hosts; XCTAssertEqual(hosts, ["example.com"])
        let both = try WatchWebAuthorization(pages: limited.pages + ["https://other.example.com/status"], queries: [])
        let accepted = await tools.execute(call, settings: settings, unattended: true, watchAuthorization: both); XCTAssertFalse(accepted.rejected)
        let after = await resolver.hosts; XCTAssertEqual(after, ["example.com", "example.com", "other.example.com"])
    }
}
