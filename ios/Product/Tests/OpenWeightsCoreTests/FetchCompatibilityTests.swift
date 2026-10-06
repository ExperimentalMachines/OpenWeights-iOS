import XCTest
@testable import OpenWeightsCore

private actor CompatibilityResolver: PublicWebResolving {
    var hosts: [String] = []
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { hosts.append(host); return ["8.8.8.8"] }
}
private actor CompatibilityConnector: PublicWebConnecting {
    var addresses: [String] = []; var replies: [WebHTTPResponse]
    init(_ replies: [WebHTTPResponse] = [WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar 730".utf8))]) { self.replies = replies }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        addresses.append(address.url.absoluteString)
        guard !replies.isEmpty else { throw PublicWebError.refused("Missing compatibility fixture response.") }
        return replies.removeFirst()
    }
}
final class FetchCompatibilityTests: XCTestCase {
    private func page(_ bytes: [UInt8], type: String = "text/plain") throws -> String {
        let address = try PublicWebAddress("https://example.com/")
        return try WebPageText.extract(PublicWebDocument(address: address, response: WebHTTPResponse(status: 200, headers: ["content-type": type], body: Data(bytes)), visited: [address.url]))
    }
    func testAndroidURLNormalizationFixturesRetainPublicHTTPSGuard() throws {
        let pairs = [("github.com/ExperimentalMachines/openweights", "https://github.com/ExperimentalMachines/openweights"), ("example.com", "https://example.com"), ("docs.example.co.uk/guide", "https://docs.example.co.uk/guide"), ("<https://example.com/a>", "https://example.com/a"), ("\"example.com/a\"", "https://example.com/a"), ("example.com/docs.", "https://example.com/docs"), ("example.com/docs,", "https://example.com/docs"), (" HTTPS://EXAMPLE.COM/a ", "https://example.com/a")]
        for (input, expected) in pairs { XCTAssertEqual(try FetchPageArguments.normalize(input).host, try PublicWebAddress(expected).host); XCTAssertEqual(try FetchPageArguments.normalize(input).target, try PublicWebAddress(expected).target) }
        XCTAssertEqual(try FetchPageArguments.normalize("https://[2606:4700:4700::1111]").host, "2606:4700:4700::1111")
        for input in ["", " ", "notes", "/home/user/notes.txt", "1.5", "192.168.1.1", "Read example.com/docs.", "what do you think", "ftp://files.example.com/x", "http://example.com/a", "https://127.0.0.1/", "<https://example.com@10.0.0.1/>", "https://0x7f000001/", "https://example.com/\r\nX:secret", "https://[::ffff:192.168.1.1]/", String(repeating: "x", count: 8193)] { XCTAssertThrowsError(try FetchPageArguments.normalize(input), input) }
    }
    func testAliasesPrimitiveValuesAndFindPrecedenceMatchAndroid() throws {
        for name in ["url", "link", "address", "input"] {
            let raw = "{\"\(name)\":\"example.com/docs\",\"ignored\":{\"anything\":true}}"
            XCTAssertEqual(try FetchPageArguments(raw).address.target, "/docs")
        }
        for name in ["find", "pattern", "search", "contains", "grep"] {
            let args = try FetchPageArguments("{\"link\":\"example.com/\",\"\(name)\":\"Cedar\",\"save\":\"unused.txt\"}")
            XCTAssertEqual(args.find, "Cedar"); XCTAssertNil(args.savePath)
        }
        for name in ["save_to", "saveTo", "save"] { XCTAssertEqual(try FetchPageArguments("{\"url\":\"https://example.com/\",\"\(name)\":\"page.txt\"}").savePath, "page.txt") }
        XCTAssertEqual(try FetchPageArguments("{\"url\":{},\"link\":\"example.com/\",\"find\":[],\"pattern\":730}").find, "730")
        XCTAssertEqual(try FetchPageArguments("{\"url\":\"example.com/\",\"find\":true}").find, "true")
        XCTAssertEqual(try FetchPageArguments("{\"url\":\"example.com/\",\"find\":null}").find, "null")
        XCTAssertEqual(try FetchPageArguments("{\"url\":\" \",\"link\":\"example.com/a\",\"find\":\" \",\"contains\":\"Cedar\"}").find, "Cedar")
        for json in ["[]", "null", "{\"url\":{\"value\":\"example.com\"}}", "{\"url\":\"example.com\",\"big\":\"" + String(repeating: "x", count: 16384) + "\"}"] { XCTAssertThrowsError(try FetchPageArguments(json)) }
    }
    func testNormalizedAliasDoesNotExpandTheExactApprovalTicket() async throws {
        let resolver = CompatibilityResolver(); let connector = CompatibilityConnector()
        let tools = WebTools(client: PublicWebClient(resolver: resolver, connector: connector))
        var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        let call = AgentToolCall(id: "alias", name: "fetch_url", argumentsJSON: "{\"link\":\"<example.com/docs.>\",\"pattern\":\"Cedar\"}")
        let normalized = AgentToolCall(id: "alias", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/docs\",\"find\":\"Cedar\"}")
        let denied = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: normalized))
        XCTAssertTrue(denied.rejected); let before = await resolver.hosts; XCTAssertTrue(before.isEmpty)
        let ticket = ApprovedToolCall(displayedCall: call)
        let accepted = await tools.execute(call, settings: settings, approval: ticket)
        XCTAssertFalse(accepted.rejected); XCTAssertTrue(accepted.text.contains("Requested: https://example.com/docs")); XCTAssertTrue(accepted.text.contains("Cedar"))
        let repeated = await tools.execute(call, settings: settings, approval: ticket); XCTAssertTrue(repeated.rejected)
        let addresses = await connector.addresses; XCTAssertEqual(addresses, ["https://example.com/docs"])
    }
    func testAliasedWholePageSaveAndFindTakePrecedenceWithoutOverwritingUserNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let connector = CompatibilityConnector([WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar 730".utf8)), WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar 730".utf8)), WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Cedar 730".utf8))])
        let tools = WebTools(client: PublicWebClient(resolver: CompatibilityResolver(), connector: connector)); var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        let save = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"input\":\"example.com/\",\"saveTo\":\"page.txt\"}")
        let saved = await tools.execute(save, settings: settings, approval: ApprovedToolCall(displayedCall: save), workspace: workspace)
        XCTAssertFalse(saved.rejected); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("page.txt"), encoding: .utf8), "Cedar 730")
        let find = AgentToolCall(id: "find", name: "fetch_url", argumentsJSON: "{\"address\":\"example.com/\",\"grep\":730,\"save\":\"unused.txt\"}")
        let found = await tools.execute(find, settings: settings, approval: ApprovedToolCall(displayedCall: find), workspace: workspace)
        XCTAssertFalse(found.rejected); XCTAssertTrue(found.text.contains("730")); XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unused.txt").path))
        try Data("User notes".utf8).write(to: root.appendingPathComponent("user.txt"))
        let overwrite = AgentToolCall(id: "overwrite", name: "fetch_url", argumentsJSON: "{\"link\":\"example.com/\",\"save\":\"user.txt\"}")
        let refused = await tools.execute(overwrite, settings: settings, approval: ApprovedToolCall(displayedCall: overwrite), workspace: workspace)
        XCTAssertTrue(refused.rejected); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("user.txt"), encoding: .utf8), "User notes")
    }
    func testEverySaveAliasRemainsGatedAfterUntrustedReadsInYolo() async throws {
        let tools = WebTools(); await tools.beginTurn(carriesUntrustedText: true)
        for key in ["save_to", "saveTo", "save"] {
            let call = AgentToolCall(id: key, name: "fetch_url", argumentsJSON: "{\"address\":\"example.com/\",\"\(key)\":\"page.txt\"}")
            let approval = await tools.requiresApproval(call, mode: .yolo); XCTAssertTrue(approval)
        }
    }
    func testKnownSignInWallsRefuseBeforeDNSAtInitialAndRedirectHops() async throws {
        for host in ["linkedin.com", "www.linkedin.com", "ph.linkedin.com", "m.facebook.com", "instagram.com"] { XCTAssertThrowsError(try FetchPageArguments.validateContentHost(PublicWebAddress("https://\(host)/profile"))) }
        for host in ["engineering.linkedin.com", "developers.facebook.com", "about.instagram.com", "notlinkedin.com", "linkedin.com.example.org"] { XCTAssertNoThrow(try FetchPageArguments.validateContentHost(PublicWebAddress("https://\(host)/"))) }
        let resolver = CompatibilityResolver(); let connector = CompatibilityConnector([WebHTTPResponse(status: 302, headers: ["location": "https://www.linkedin.com/in/cedar"], body: Data())])
        let client = PublicWebClient(resolver: resolver, connector: connector)
        do { _ = try await client.fetch("https://linkedin.com/in/cedar", validateHop: { try FetchPageArguments.validateContentHost($0) }); XCTFail("Initial sign-in wall dialed.") } catch is PublicWebError { }
        var hosts = await resolver.hosts; XCTAssertTrue(hosts.isEmpty)
        do { _ = try await client.fetch("https://example.com/", validateHop: { try FetchPageArguments.validateContentHost($0) }); XCTFail("Redirect sign-in wall dialed.") } catch is PublicWebError { }
        hosts = await resolver.hosts; XCTAssertEqual(hosts, ["example.com"])
        let addresses = await connector.addresses; XCTAssertEqual(addresses, ["https://example.com/"])
    }
    func testFiveUnicodeBOMsOverrideDeclaredLegacyCharset() throws {
        let expected = "旅行 🌿 Cedar"
        let fixtures: [[UInt8]] = [[239,187,191,230,151,133,232,161,140,32,240,159,140,191,32,67,101,100,97,114], [254,255,101,197,136,76,0,32,216,60,223,63,0,32,0,67,0,101,0,100,0,97,0,114], [255,254,197,101,76,136,32,0,60,216,63,223,32,0,67,0,101,0,100,0,97,0,114,0], [255,254,0,0,197,101,0,0,76,136,0,0,32,0,0,0,63,243,1,0,32,0,0,0,67,0,0,0,101,0,0,0,100,0,0,0,97,0,0,0,114,0,0,0], [0,0,254,255,0,0,101,197,0,0,136,76,0,0,0,32,0,1,243,63,0,0,0,32,0,0,0,67,0,0,0,101,0,0,0,100,0,0,0,97,0,0,0,114]]
        for bytes in fixtures { XCTAssertEqual(try page(bytes, type: "text/plain; charset=windows-1252"), expected) }
    }
    func testDeclaredIANALegacyCharsetsAndUnknownFallback() throws {
        XCTAssertEqual(try page([151,183,141,115,32,67,101,100,97,114], type: "text/plain; charset=Shift_JIS"), "旅行 Cedar")
        XCTAssertEqual(try page([207,240,232,226,229,242,32,67,101,100,97,114], type: "text/plain; charset=windows-1251"), "Привет Cedar")
        XCTAssertEqual(try page([234,252,243,236,239,242,32,67,101,100,97,114], type: "text/plain; charset=\"ISO-8859-7\""), "κόσμος Cedar")
        XCTAssertEqual(try page([230,151,133,232,161,140], type: "text/plain; charset=unknown-fixture-name"), "旅行")
        XCTAssertEqual(try page([99,97,102,233], type: "text/plain; charset=iso-8859-1; charset=utf-8"), "café")
    }
    func testUnicodeDefaultsMalformedSequencesAndASCIIReplacement() throws {
        XCTAssertEqual(try page([0,67,0,101,0,100,0,97,0,114], type: "text/plain; charset=utf-16"), "Cedar")
        XCTAssertEqual(try page([0,0,0,67], type: "text/plain; charset=utf-32"), "C")
        XCTAssertEqual(try page([0x41,0xc3,0x28]), "A\u{fffd}(")
        XCTAssertEqual(try page([0x00,0x41,0xd8,0x00,0x00], type: "text/plain; charset=utf-16be"), "A\u{fffd}")
        XCTAssertEqual(try page([0xd8,0x00,0x00,0x41], type: "text/plain; charset=utf-16be"), "\u{fffd}")
        XCTAssertEqual(try page([0x00,0x00,0xd8,0x00], type: "text/plain; charset=utf-32be"), "\u{fffd}")
        XCTAssertEqual(try page([65,233,66], type: "text/plain; charset=us-ascii"), "A\u{fffd}B")
        XCTAssertEqual(try page([65,129,66], type: "text/plain; charset=windows-1252"), "A\u{fffd}B")
        XCTAssertEqual(try page([130,32], type: "text/plain; charset=shift_jis"), "\u{fffd} ")
    }
    func testTextualSubtypePrefixesPreserveDataAndCleanHTML() throws {
        let json = "{\"test\":\"a < b\"}\n"
        XCTAssertEqual(try page(Array(json.utf8), type: "application/json-patch+json"), json)
        XCTAssertEqual(try page(Array("<root>Cedar</root>".utf8), type: "application/xml-external-parsed-entity"), "<root>Cedar</root>")
        XCTAssertEqual(try page(Array("<p>Cedar</p><script>ignore</script>".utf8), type: "application/xhtml+xml"), "Cedar")
    }
}
