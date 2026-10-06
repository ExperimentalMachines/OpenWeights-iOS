import XCTest
@testable import OpenWeightsCore

private struct FetchResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private actor FetchConnector: PublicWebConnecting {
    var count = 0
    let response: WebHTTPResponse
    init(_ body: String, headers: [String: String] = ["content-type": "text/html; charset=utf-8"], status: Int = 200, bodyIsComplete: Bool = true) {
        response = WebHTTPResponse(status: status, headers: headers, body: Data(body.utf8), bodyIsComplete: bodyIsComplete)
    }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        count += 1; return response
    }
}
final class WebToolTests: XCTestCase {
    func testHTMLStructureEntitiesRelativeLinksAndLargestArticle() throws {
        let body = "<nav>ignore me</nav><main><article>teaser</article><article><h1>Cedar &amp; Osaka</h1><p>" + String(repeating: "readable words ", count: 60) + "</p><ul><li>Vegetarian</li></ul><table><tr><th>Time</th><td>07:30</td></tr></table><a href='../source'>Evidence</a><script>evil()</script></article></main><footer>footer noise</footer>"
        let text = try WebPageText.html(body, baseURL: "https://example.com/docs/page")
        XCTAssertTrue(text.contains("Cedar & Osaka")); XCTAssertTrue(text.contains("\n- Vegetarian\n"))
        XCTAssertTrue(text.contains("Time | 07:30 |")); XCTAssertTrue(text.contains("Evidence (https://example.com/source)"))
        for absent in ["teaser", "ignore me", "evil", "footer noise"] { XCTAssertFalse(text.contains(absent), absent) }
    }
    func testNonHTMLBytesArePreservedAndBinaryCompressionEncodingEmptyStatusRefused() throws {
        let address = try PublicWebAddress("https://example.com/")
        func document(_ body: Data, type: String?, status: Int = 200, encoding: String? = nil) -> PublicWebDocument {
            var headers: [String: String] = [:]; headers["content-type"] = type; headers["content-encoding"] = encoding
            return PublicWebDocument(address: address, response: WebHTTPResponse(status: status, headers: headers, body: body), visited: [address.url])
        }
        let json = "{\"expression\":\"a < b\"}\n"
        XCTAssertEqual(try WebPageText.extract(document(Data(json.utf8), type: "application/json")), json)
        XCTAssertEqual(try WebPageText.extract(document(Data([0x63, 0x61, 0x66, 0xe9]), type: "text/plain; charset=iso-8859-1")), "café")
        XCTAssertEqual(try WebPageText.extract(document(Data([0xff]), type: "text/plain")), "\u{fffd}")
        XCTAssertEqual(try WebPageText.extract(document(Data("x".utf8), type: "text/plain; charset=made-up")), "x")
        for doc in [document(Data("zip".utf8), type: "application/zip"), document(Data("data".utf8), type: "text/plain", encoding: "gzip"), document(Data("error".utf8), type: "text/plain", status: 404), document(Data("<script>onlyScript()</script>".utf8), type: "text/html")] { XCTAssertThrowsError(try WebPageText.extract(doc)) }
    }
    func testFindSearchesBeyondExcerptPreservesUnicodeAndLimitsMatches() throws {
        let text = String(repeating: "opening ", count: 1000) + "\n旅行 Cedar price\n730 USD\n" + String(repeating: " tail", count: 300)
        let found = try WebPageSearch.render(text: text, pattern: "Cedar.*USD")
        XCTAssertTrue(found.contains("Cedar price\n730 USD")); XCTAssertTrue(found.contains("旅行")); XCTAssertLessThan(found.utf16.count, 4200)
        XCTAssertTrue(try WebPageSearch.render(text: "Literal [ bracket", pattern: "[").contains("1 places"))
        XCTAssertTrue(try WebPageSearch.render(text: "Cedar", pattern: "absent").contains("5 characters"))
        XCTAssertTrue(try WebPageSearch.render(text: String(repeating: "a", count: 1000), pattern: "a*").contains("places"))
        XCTAssertTrue(try WebPageSearch.render(text: String(repeating: "x ", count: 100), pattern: "x").contains("there may be more"))
    }
    func testCatastrophicRegexIsStoppedWithinBoundedTime() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try WebPageSearch.render(text: String(repeating: "a", count: 100_000), pattern: "(a+)+b")
        XCTAssertTrue(result.contains("took too long")); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }
    func testDisabledPlanAndInvalidCallsDoNotConnectAndExactApprovalsCannotReplay() async throws {
        let connector = FetchConnector("<p>Cedar</p>")
        let tools = WebTools(client: PublicWebClient(resolver: FetchResolver(), connector: connector))
        let call = AgentToolCall(id: "one", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\"}")
        var settings = WebToolSettings()
        var result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.fetchEnabled = true; settings.mode = .plan
        result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.mode = .ask
        result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        let ticket = ApprovedToolCall(displayedCall: call)
        let different = AgentToolCall(id: "two", name: "fetch_url", argumentsJSON: call.argumentsJSON)
        result = await tools.execute(different, settings: settings, approval: ticket); XCTAssertTrue(result.rejected)
        result = await tools.execute(call, settings: settings, approval: ticket); XCTAssertFalse(result.rejected); XCTAssertTrue(result.untrustedText)
        result = await tools.execute(call, settings: settings, approval: ticket); XCTAssertTrue(result.rejected)
        let count = await connector.count; XCTAssertEqual(count, 1)
    }
    func testPriorReadRequiresEgressApprovalAndYoloStillAsksForSaving() async throws {
        let tools = WebTools()
        await tools.beginTurn(carriesUntrustedText: true)
        let read = AgentToolCall(id: "one", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\"}")
        var needs = await tools.requiresApproval(read, mode: .auto); XCTAssertTrue(needs)
        needs = await tools.requiresApproval(read, mode: .yolo); XCTAssertFalse(needs)
        let save = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"save_to\":\"page.txt\"}")
        needs = await tools.requiresApproval(save, mode: .yolo); XCTAssertTrue(needs)
    }
    func testWholePageSaveFindPrecedenceExistingFilesAndRevokedGrants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let text = String(repeating: "Cedar ", count: 1000)
        let tools = WebTools(client: PublicWebClient(resolver: FetchResolver(), connector: FetchConnector(text, headers: ["content-type": "text/plain"])))
        var settings = WebToolSettings(); settings.fetchEnabled = true
        let save = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"save_to\":\"page.txt\"}")
        var result = await tools.execute(save, settings: settings, workspace: workspace); XCTAssertFalse(result.rejected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("page.txt"), encoding: .utf8), text)
        try Data("user notes".utf8).write(to: root.appendingPathComponent("user.txt"))
        await tools.beginTurn(carriesUntrustedText: false)
        let overwrite = AgentToolCall(id: "overwrite", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"save_to\":\"user.txt\"}")
        result = await tools.execute(overwrite, settings: settings, workspace: workspace); XCTAssertTrue(result.rejected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("user.txt"), encoding: .utf8), "user notes")
        await tools.beginTurn(carriesUntrustedText: false)
        let find = AgentToolCall(id: "find", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"find\":\"Cedar\",\"save_to\":\"unused.txt\"}")
        result = await tools.execute(find, settings: settings); XCTAssertFalse(result.rejected); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused.txt").path))
        await workspace.revoke(); await tools.beginTurn(carriesUntrustedText: false)
        result = await tools.execute(save, settings: settings, workspace: workspace); XCTAssertTrue(result.rejected)
        await tools.beginTurn(carriesUntrustedText: false)
        result = await tools.execute(save, settings: settings, workspace: workspace, unattended: true); XCTAssertTrue(result.rejected)
    }
    func testFullTextPrefixSaveReservesDisclosureBytesAndPreservesUTF8() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        for (index, body) in [String(repeating: "a", count: WebPageText.maximumBytes), String(repeating: "旅行", count: WebPageText.maximumBytes / 6), String(repeating: "🙂", count: WebPageText.maximumBytes / 4)].enumerated() {
            let connector = FetchConnector(body, headers: ["content-type": "text/plain; charset=utf-8"], bodyIsComplete: false)
            let tools = WebTools(client: PublicWebClient(resolver: FetchResolver(), connector: connector))
            var settings = WebToolSettings(); settings.fetchEnabled = true
            let call = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"save_to\":\"prefix\(index).txt\"}")
            let result = await tools.execute(call, settings: settings, workspace: workspace)
            XCTAssertFalse(result.rejected, result.text)
            guard !result.rejected else { continue }
            let bytes = try Data(contentsOf: root.appendingPathComponent("prefix\(index).txt"))
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertLessThanOrEqual(bytes.count, WebPageText.maximumBytes)
            XCTAssertTrue(text.hasPrefix("[Read stopped at the 512 KiB limit"))
            XCTAssertTrue(text.contains("Saved text was shortened"))
            XCTAssertTrue(result.text.contains("Saved text was shortened"))
            XCTAssertFalse(text.contains("\u{fffd}"))
            let content = String(text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).last ?? "")
            XCTAssertTrue(body.hasPrefix(content)); XCTAssertLessThan(content.utf8.count, body.utf8.count)
            XCTAssertTrue(result.text.contains("Saved \(content.utf16.count) characters"))
        }
    }

    func testLimitedPageDisclosesPrefixForReadFindAndSavedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let connector = FetchConnector("<main><p>Cedar</p><p>Osaka</p></main>", bodyIsComplete: false)
        let tools = WebTools(client: PublicWebClient(resolver: FetchResolver(), connector: connector))
        var settings = WebToolSettings(); settings.fetchEnabled = true
        for (id, extra) in [("read", ""), ("find", ",\"find\":\"absent beyond prefix\""), ("save", ",\"save_to\":\"prefix.txt\"")] {
            await tools.beginTurn(carriesUntrustedText: false)
            let call = AgentToolCall(id: id, name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\"\(extra)}")
            let result = await tools.execute(call, settings: settings, workspace: workspace)
            XCTAssertFalse(result.rejected)
            XCTAssertTrue(result.untrustedText)
            XCTAssertTrue(result.text.contains("This is a page prefix"))
            XCTAssertTrue(result.text.contains("cover only the returned prefix"))
        }
        let saved = try String(contentsOf: root.appendingPathComponent("prefix.txt"), encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("[Read stopped at the 512 KiB limit"))
        XCTAssertTrue(saved.contains("Cedar\nOsaka"))
    }
}
