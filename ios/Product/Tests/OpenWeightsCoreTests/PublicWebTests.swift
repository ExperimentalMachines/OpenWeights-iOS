import XCTest
@testable import OpenWeightsCore

private actor WebFixtureResolver: PublicWebResolving {
    var hosts: [String] = []
    let values: [String: [String]]
    init(_ values: [String: [String]]) { self.values = values }
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { hosts.append(host); return values[host] ?? [] }
}
private actor WebFixtureConnector: PublicWebConnecting {
    struct Attempt: Sendable { let host: String; let ip: String; let request: Data }
    var attempts: [Attempt] = []
    var responses: [WebHTTPResponse]
    var failedIPs: Set<String> = []
    init(_ responses: [WebHTTPResponse], failedIPs: Set<String> = []) { self.responses = responses; self.failedIPs = failedIPs }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        attempts.append(Attempt(host: address.host, ip: ip, request: address.request))
        if failedIPs.contains(ip) { throw PublicWebError.refused("Fixture public connection failed.") }
        guard !responses.isEmpty else { throw PublicWebError.refused("No fixture reply.") }
        return responses.removeFirst()
    }
}
final class PublicWebTests: XCTestCase {
    private func parse(_ text: String, maximumBody: Int = 1_048_576, eof: Bool = true) throws -> WebHTTPResponse? {
        var decoder = WebHTTPResponseDecoder(maximumBody: maximumBody)
        return try decoder.append(Data(text.utf8), endOfStream: eof)
    }
    func testPublicAddressUsesStructuredHostAndSafeRequestTarget() throws {
        let page = try PublicWebAddress("https://EXAMPLE.com:8443/a%20b?q=Cedar%0D%0AX-Test%3Afoo#ignored")
        XCTAssertEqual(page.host, "example.com"); XCTAssertEqual(page.port, 8443)
        XCTAssertNil(page.url.fragment)
        let request = String(decoding: page.request, as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /a%20b?q=Cedar%0D%0AX-Test%3Afoo HTTP/1.1\r\nHost: example.com:8443\r\n"))
        XCTAssertFalse(request.contains("\r\nX-Test:"))
        XCTAssertFalse(request.contains("Authorization:")); XCTAssertFalse(request.contains("Cookie:"))
        XCTAssertEqual(try PublicWebAddress("https://[2606:4700:4700::1111]/").host, "2606:4700:4700::1111")
        let international = try PublicWebAddress("https://bücher.de/旅行")
        XCTAssertEqual(international.host, "xn--bcher-kva.de")
        XCTAssertEqual(international.target, "/%E6%97%85%E8%A1%8C")
    }
    func testUnsafeURLSchemesCredentialsLocalAndAmbiguousHostsAreRefused() {
        for raw in ["http://example.com/", "file:///etc/passwd", "https://user:secret@example.com/", "https://example.com@127.0.0.1/", "https://127.1/", "https://2130706433/", "https://0177.0.0.1/", "https://0x7f000001/", "https://localhost/", "https://router.local/", "https://x.home.arpa/", "https://example.com./", "https://[fe80::1%25en0]/", "https://example.com/\r\nHeader: value", "https://example.com\\@127.0.0.1/", "https://example.com:0/", "https://example.com:99999/", "https://example..com/"] {
            XCTAssertThrowsError(try PublicWebAddress(raw), raw)
        }
    }
    func testNonpublicLiteralsIncludeMappedAndTranslatedIPv4() {
        for address in ["0177.0.0.1", "127.1", "0x7f000001", "2130706433", "::ffff:0177.0.0.1", "0.0.0.0", "10.1.2.3", "127.0.0.1", "100.64.0.1", "100.127.255.254", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.1.1", "192.0.0.1", "192.0.2.1", "192.88.99.1", "198.18.0.1", "198.19.255.255", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "fe80::1", "fec0::1", "fc00::1", "fdff::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:192.168.0.1", "64:ff9b::a00:1", "64:ff9b:1::808:808", "2001::1", "2001:db8::1", "2002:a00:1::1", "3fff::1", "not-an-ip"] {
            XCTAssertFalse(PublicWebIP.isPublic(address), address)
        }
        for address in ["8.8.8.8", "1.1.1.1", "100.128.0.1", "172.32.0.1", "2606:4700:4700::1111", "2001:4860:4860::8888", "::ffff:8.8.8.8", "64:ff9b::808:808"] {
            XCTAssertTrue(PublicWebIP.isPublic(address), address)
        }
    }
    func testEveryRedirectGetsAddressValidation() throws {
        let original = try PublicWebAddress("https://example.com/path/start")
        XCTAssertEqual(try original.redirected(to: "../next?q=1").url.absoluteString, "https://example.com/next?q=1")
        XCTAssertEqual(try original.redirected(to: "//other.example.org/read").host, "other.example.org")
        for target in ["http://example.com/", "https://10.0.0.1/", "https://[::ffff:127.0.0.1]/", "https://x.local/", "https://secret@example.org/", "\r\nhttps://example.org", ""] {
            XCTAssertThrowsError(try original.redirected(to: target), target)
        }
    }
    func testLengthFramedUTF8ResponseCanArriveByteByByte() throws {
        let body = "Cedar 🧠"; let wire = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        var decoder = WebHTTPResponseDecoder(maximumBody: body.utf8.count); var result: WebHTTPResponse?
        for (index, byte) in wire.enumerated() {
            result = try decoder.append(Data([byte]))
            if index < wire.count - 1 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result?.status, 200); XCTAssertEqual(result?.body, Data(body.utf8))
    }
    func testChunkedInterimAndTrailersHaveUnambiguousCompletion() throws {
        let wire = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=value\r\nCedar\r\n1\r\n!\r\n0\r\nX-Checksum: fixture\r\n\r\n"
        var decoder = WebHTTPResponseDecoder(); var response: WebHTTPResponse?
        for byte in wire.utf8 { response = try decoder.append(Data([byte])) }
        XCTAssertEqual(String(decoding: try XCTUnwrap(response).body, as: UTF8.self), "Cedar!")
        XCTAssertEqual(response?.headers["transfer-encoding"], "chunked")
        XCTAssertThrowsError(try parse("HTTP/1.1 101 Switching Protocols\r\n\r\n"))
    }
    func testTruncatedConflictingOrMalformedFramingFails() {
        for wire in ["HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort", "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nextra", "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n0\r\n\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabc", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nLocation: https://router.local\r\n\r\n", "HTTP/1.1 302 Found\r\nLocation: /first\r\nLocation: /second\r\n\r\n", "HTTP/1.1 200 OK\r\n Content-Length: 0\r\n\r\n", "HTTP/1.1 200 OK\r\nX-Test: good\nbad\r\n\r\n"] {
            XCTAssertThrowsError(try parse(wire), wire)
        }
    }
    func testBodyHeaderChunkAndWireBudgetsAreEnforced() {
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nlong", maximumBody: 3))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nlong\r\n0\r\n\r\n", maximumBody: 3))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\n\r\nlong", maximumBody: 3))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nX-Large: " + String(repeating: "x", count: 16_384)))
        XCTAssertThrowsError(try parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "1;x=a\r\na\r\n", count: 8_193) + "0\r\n\r\n"))
        var decoder = WebHTTPResponseDecoder(maximumBody: 1)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0, count: 262_146)))
    }
    func testCloseDelimitedResponseRequiresEOFAndNoBodyStatusIsHonored() throws {
        XCTAssertNil(try parse("HTTP/1.0 200 OK\r\n\r\nCedar", eof: false))
        XCTAssertEqual(try parse("HTTP/1.0 200 OK\r\n\r\nCedar")?.body, Data("Cedar".utf8))
        XCTAssertEqual(try parse("HTTP/1.1 204 No Content\r\n\r\n")?.body, Data())
        XCTAssertEqual(try parse("HTTP/1.1 304 Not Modified\r\nContent-Length: 99\r\n\r\n")?.body, Data())
    }
    func testLargeLengthDelimitedTextStopsAtPrefixWithoutAwaitingEOF() throws {
        let cap = WebPageText.maximumBytes
        let body = Data((String(repeating: "Cedar ", count: cap / 6 + 1) + " beyond-limit").utf8)
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2000000\r\n\r\n".utf8)
        var decoder = WebHTTPResponseDecoder(maximumBody: cap, allowsTextPrefix: true)
        XCTAssertNil(try decoder.append(header))
        var result: WebHTTPResponse?
        for offset in stride(from: 0, to: body.count, by: 16_384) {
            result = try decoder.append(body.subdata(in: offset..<min(body.count, offset + 16_384)))
            if result != nil { break }
        }
        XCTAssertEqual(result?.body, body.prefix(cap))
        XCTAssertEqual(result?.body.count, cap)
        XCTAssertEqual(result?.bodyIsComplete, false)
        XCTAssertEqual(result?.headers["content-length"], "2000000")
    }
    func testChunkedTextPrefixCanStopInsideChunkOrBeforeNextBody() throws {
        for wire in ["HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\nCedar", "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nCedar\r\n100000\r\n"] {
            var decoder = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
            let result = try XCTUnwrap(decoder.append(Data(wire.utf8)))
            XCTAssertEqual(result.body, Data("Cedar".utf8))
            XCTAssertFalse(result.bodyIsComplete)
        }
        var exact = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
        let result = try XCTUnwrap(exact.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nCedar\r\n0\r\n\r\n".utf8)))
        XCTAssertTrue(result.bodyIsComplete)
    }
    func testCloseDelimitedTextPrefixDistinguishesKnownAndUnknownCompletion() throws {
        for (body, eof, complete) in [("Cedar", false, false), ("Cedar", true, true), ("Cedar more", false, false), ("Cedar more", true, false)] {
            var decoder = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
            let result = try XCTUnwrap(decoder.append(Data("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n\(body)".utf8), endOfStream: eof))
            XCTAssertEqual(result.body, Data("Cedar".utf8))
            XCTAssertEqual(result.bodyIsComplete, complete)
        }
    }
    func testPrefixPolicyDoesNotAcceptInvalidFramingOrPrematureEOF() {
        for wire in ["HTTP/1.1 200 OK\r\nContent-Length: 50\r\nContent-Length: 51\r\n\r\nCedar", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nCedar\r\n0\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nCedar", "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nCedar", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nCedarxXX", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n50\r\nCedar", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF\r\n"] {
            var decoder = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
            XCTAssertThrowsError(try decoder.append(Data(wire.utf8), endOfStream: true), wire)
        }
    }
    func testPrefixRequiresSuccessfulUncompressedReadableTextAndExplicitOptIn() {
        for headers in ["Content-Type: application/zip\r\n", "Content-Type: text/plain\r\nContent-Encoding: gzip\r\n", "Content-Type: text/plain\r\nContent-Encoding: br\r\n"] {
            var decoder = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
            XCTAssertThrowsError(try decoder.append(Data("HTTP/1.1 200 OK\r\n\(headers)Content-Length: 50\r\n\r\nCedar".utf8)))
        }
        var status = WebHTTPResponseDecoder(maximumBody: 5, allowsTextPrefix: true)
        XCTAssertThrowsError(try status.append(Data("HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\nContent-Length: 50\r\n\r\nCedar".utf8)))
        var strict = WebHTTPResponseDecoder(maximumBody: 5)
        XCTAssertThrowsError(try strict.append(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 50\r\n\r\nCedar".utf8)))
    }
    func testPrivateDNSAnswersCannotReachConnector() async throws {
        let resolver = WebFixtureResolver(["example.com": ["127.0.0.1", "::ffff:10.0.0.1"]]); let connector = WebFixtureConnector([])
        do { _ = try await PublicWebClient(resolver: resolver, connector: connector).fetch("https://example.com/"); XCTFail("Private DNS should fail.") } catch {}
        let attempts = await connector.attempts; XCTAssertTrue(attempts.isEmpty)
    }
    func testFilteredDNSFallbackDialsCheckedIPsWithOriginalHost() async throws {
        let resolver = WebFixtureResolver(["example.com": ["10.0.0.1", "8.8.8.8", "8.8.8.8", "1.1.1.1"]])
        let connector = WebFixtureConnector([WebHTTPResponse(status: 200, headers: [:], body: Data("Cedar".utf8))], failedIPs: ["8.8.8.8"])
        let result = try await PublicWebClient(resolver: resolver, connector: connector).fetch("https://example.com/read")
        let attempts = await connector.attempts
        XCTAssertEqual(attempts.map(\.ip), ["8.8.8.8", "1.1.1.1"]); XCTAssertTrue(attempts.allSatisfy { $0.host == "example.com" })
        XCTAssertEqual(result.response.body, Data("Cedar".utf8)); XCTAssertEqual(result.visited.count, 1)
    }
    func testRedirectToPrivateLiteralIsRefusedBeforeAnotherDNSLookup() async throws {
        let resolver = WebFixtureResolver(["example.com": ["8.8.8.8"]]); let connector = WebFixtureConnector([WebHTTPResponse(status: 302, headers: ["location": "https://192.168.1.1/admin"], body: Data())])
        do { _ = try await PublicWebClient(resolver: resolver, connector: connector).fetch("https://example.com/"); XCTFail("Private redirect should fail.") } catch {}
        let hosts = await resolver.hosts; let attempts = await connector.attempts
        XCTAssertEqual(hosts, ["example.com"]); XCTAssertEqual(attempts.count, 1)
    }
    func testRedirectToPrivateDNSAndLoopsCannotConnectAgain() async throws {
        let resolver = WebFixtureResolver(["example.com": ["8.8.8.8"], "other.example.org": ["192.168.0.1"]])
        let connector = WebFixtureConnector([WebHTTPResponse(status: 302, headers: ["location": "https://other.example.org/"], body: Data())])
        do { _ = try await PublicWebClient(resolver: resolver, connector: connector).fetch("https://example.com/"); XCTFail("Private redirect DNS should fail.") } catch {}
        let attempts = await connector.attempts; XCTAssertEqual(attempts.count, 1)
        let looping = WebFixtureConnector([WebHTTPResponse(status: 302, headers: ["location": "/"], body: Data())])
        do { _ = try await PublicWebClient(resolver: resolver, connector: looping).fetch("https://example.com/"); XCTFail("Loop should fail.") } catch {}
        let loopAttempts = await looping.attempts; XCTAssertEqual(loopAttempts.count, 1)
    }
    func testCancelledClientDoesNotResolveOrConnect() async throws {
        let resolver = WebFixtureResolver(["example.com": ["8.8.8.8"]]); let connector = WebFixtureConnector([])
        let task = Task { () throws -> PublicWebDocument in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PublicWebClient(resolver: resolver, connector: connector).fetch("https://example.com/")
        }
        do { _ = try await task.value; XCTFail("Cancelled request should fail.") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let hosts = await resolver.hosts; let attempts = await connector.attempts
        XCTAssertTrue(hosts.isEmpty); XCTAssertTrue(attempts.isEmpty)
    }
}
