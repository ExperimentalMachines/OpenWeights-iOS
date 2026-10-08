import XCTest
import CryptoKit
@testable import OpenWeightsCore

private struct GzipFixtureResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private struct GzipFixtureConnector: PublicWebConnecting {
    let response: WebHTTPResponse
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse { response }
}

final class WebGzipTests: XCTestCase {
    private func reference(_ name: String) throws -> (Data, [String: Any]) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "gzip-reference", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fixtures = try XCTUnwrap(root["fixtures"] as? [String: [String: Any]])
        let fixture = try XCTUnwrap(fixtures[name])
        if let filename = fixture["file"] as? String {
            let url = try XCTUnwrap(Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"))
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes.count, fixture["encodedBytes"] as? Int)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), fixture["encodedSHA256"] as? String)
            return (bytes, fixture)
        }
        let hex = try XCTUnwrap(fixture["gzipHex"] as? String)
        var bytes = Data(); var offset = hex.startIndex
        while offset < hex.endIndex {
            let end = hex.index(offset, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(hex[offset..<end], radix: 16))); offset = end
        }
        XCTAssertEqual(bytes.count, fixture["encodedBytes"] as? Int)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), fixture["encodedSHA256"] as? String)
        return (bytes, fixture)
    }
    private func parse(_ body: Data, framing: String, type: String = "text/plain; charset=windows-1252", maximum: Int = 512, prefix: Bool = true, receiveBytes: Int = 11) throws -> WebHTTPResponse {
        var message = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Encoding: gzip\r\nSet-Cookie: fixture=1\r\n".utf8)
        switch framing {
        case "length": message.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8)); message.append(body)
        case "chunked":
            message.append(Data("Transfer-Encoding: chunked\r\n\r\n".utf8))
            let chunkBytes = receiveBytes == 11 ? 7 : 65_536
            for start in stride(from: 0, to: body.count, by: chunkBytes) {
                let piece = body[start..<min(body.count, start + chunkBytes)]
                message.append(Data("\(String(piece.count, radix: 16))\r\n".utf8)); message.append(piece); message.append(Data("\r\n".utf8))
            }
            message.append(Data("0\r\n\r\n".utf8))
        default: message.append(Data("\r\n".utf8)); message.append(body)
        }
        var decoder = WebHTTPResponseDecoder(maximumBody: maximum, allowsTextPrefix: prefix)
        var response: WebHTTPResponse?
        for start in stride(from: 0, to: message.count, by: receiveBytes) {
            let end = min(message.count, start + receiveBytes)
            response = try decoder.append(message[start..<end], endOfStream: end == message.count)
            if response != nil { break }
        }
        return try XCTUnwrap(response)
    }
    func testPythonGzipReferenceReadsUnicodeAcrossThreeFramings() throws {
        let (body, fixture) = try reference("unicode")
        let address = try PublicWebAddress("https://example.com/")
        for framing in ["length", "chunked", "close"] {
            let response = try parse(body, framing: framing)
            XCTAssertTrue(response.bodyIsComplete); XCTAssertTrue(response.bodyWasGzipDecoded)
            XCTAssertEqual(response.headers["content-encoding"], "gzip")
            XCTAssertEqual(response.setCookieHeaders, ["fixture=1"])
            XCTAssertEqual(response.body.count, fixture["decodedBytes"] as? Int)
            XCTAssertEqual(SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined(), fixture["decodedSHA256"] as? String)
            XCTAssertEqual(try WebPageText.extract(PublicWebDocument(address: address, response: response, visited: [address.url])), fixture["expectedText"] as? String)
        }
    }
    func testExactDecodedLimitCompletesButOneExtraByteProducesExplicitPrefix() throws {
        let exact = try reference("exact-limit").0; let overflow = try reference("over-limit").0
        for framing in ["length", "chunked", "close"] {
            let whole = try parse(exact, framing: framing); let partial = try parse(overflow, framing: framing)
            XCTAssertEqual(whole.body, Data(repeating: 65, count: 512)); XCTAssertTrue(whole.bodyIsComplete)
            XCTAssertEqual(partial.body, whole.body); XCTAssertFalse(partial.bodyIsComplete)
        }
    }
    func testEightMiBExpansionReturnsOnlyThe512KiBPrefix() throws {
        let body = try reference("bomb").0
        XCTAssertLessThan(body.count, 16_384)
        let response = try parse(body, framing: "length", maximum: WebPageText.maximumBytes)
        XCTAssertEqual(response.body, Data(repeating: 65, count: WebPageText.maximumBytes))
        XCTAssertFalse(response.bodyIsComplete)
    }
    func testConcatenatedMembersPreserveAllTextWithinTheLimit() throws {
        let body = try reference("first-member").0 + reference("second-member").0
        let result = try parse(body, framing: "chunked")
        XCTAssertEqual(String(decoding: result.body, as: UTF8.self), "Cedar 730")
        XCTAssertTrue(result.bodyIsComplete)
    }
    func testMalformedHeadersTruncationChecksumAndTrailingGarbageAreRejected() throws {
        let body = try reference("unicode").0
        var corrupt = body; corrupt[corrupt.count - 8] ^= 1
        for invalid in [Data(), Data([1, 2, 3]), Data(body.dropLast()), corrupt, body + Data([1, 2, 3])] {
            for framing in ["length", "chunked", "close"] { XCTAssertThrowsError(try parse(invalid, framing: framing)) }
        }
    }
    func testTooManyMembersAreRejectedWithoutAnUnboundedEmptyMemberLoop() throws {
        let member = try reference("first-member").0
        XCTAssertThrowsError(try WebGzip.decode((0..<33).reduce(Data()) { value, _ in value + member }, maximumBytes: 512))
    }
    func testStrictAndBinaryResponsesRemainEncodedAndCannotMasqueradeAsText() throws {
        let body = try reference("unicode").0
        for response in [try parse(body, framing: "length", prefix: false), try parse(body, framing: "length", type: "application/octet-stream")] {
            XCTAssertEqual(response.body, body); XCTAssertFalse(response.bodyWasGzipDecoded)
            let address = try PublicWebAddress("https://example.com/")
            XCTAssertThrowsError(try WebPageText.extract(PublicWebDocument(address: address, response: response, visited: [address.url])))
        }
    }
    func testStrictCompressedWireLimitStillRejectsOversizedTransfers() throws {
        let body = try reference("unicode").0
        XCTAssertThrowsError(try parse(body, framing: "length", maximum: body.count - 1, prefix: false))
        XCTAssertThrowsError(try parse(body, framing: "chunked", maximum: body.count - 1, prefix: false))
    }
    func testLargerCompressedWireReadsStopAtTheDecodedPrefixAcrossThreeFramings() throws {
        let (body, fixture) = try reference("large-wire")
        XCTAssertGreaterThan(body.count, WebPageText.maximumBytes)
        for framing in ["length", "chunked", "close"] {
            let response = try parse(body, framing: framing, maximum: WebPageText.maximumBytes, receiveBytes: 8192)
            XCTAssertEqual(response.body.count, WebPageText.maximumBytes)
            XCTAssertFalse(response.bodyIsComplete); XCTAssertTrue(response.bodyWasGzipDecoded)
            XCTAssertEqual(SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined(), fixture["decodedPrefixSHA256"] as? String)
        }
    }
    func testCancelledTaskDoesNotReturnDecompressedText() async throws {
        let body = try reference("bomb").0
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try WebGzip.decode(body, maximumBytes: 512)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled decoding returned content") }
        catch is CancellationError { }
    }
    func testGzipUnicodePageFlowsThroughApprovedReadFindAndSave() async throws {
        let response = try parse(reference("unicode").0, framing: "chunked")
        let tools = WebTools(client: PublicWebClient(resolver: GzipFixtureResolver(), connector: GzipFixtureConnector(response: response)))
        var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        for (id, extra) in [("read", ""), ("find", ",\"find\":\"Cedar\""), ("save", ",\"save_to\":\"gzip.txt\"")] {
            let call = AgentToolCall(id: id, name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\"\(extra)}")
            let result = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: call), workspace: workspace)
            XCTAssertFalse(result.rejected, result.text); XCTAssertTrue(result.text.contains("Cedar 730"))
            XCTAssertFalse(result.text.contains("This is a page prefix"))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("gzip.txt"), encoding: .utf8), "旅行 🌿 Cedar 730")
    }
    func testGzipExpandedPrefixDisclosesTruncationAndBoundsSavedFile() async throws {
        let response = try parse(reference("bomb").0, framing: "length", maximum: WebPageText.maximumBytes)
        let tools = WebTools(client: PublicWebClient(resolver: GzipFixtureResolver(), connector: GzipFixtureConnector(response: response)))
        var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        let call = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/\",\"save_to\":\"prefix.txt\"}")
        let result = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: call), workspace: workspace)
        XCTAssertFalse(result.rejected, result.text)
        XCTAssertTrue(result.text.contains("This is a page prefix")); XCTAssertTrue(result.text.contains("Saved text was shortened"))
        let saved = try Data(contentsOf: root.appendingPathComponent("prefix.txt"))
        XCTAssertEqual(saved.count, WebPageText.maximumBytes)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).hasPrefix("[Read stopped at the 512 KiB limit"))
    }
}
