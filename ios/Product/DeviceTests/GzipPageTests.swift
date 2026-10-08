import XCTest
import CryptoKit
import OpenWeightsCore

private struct GzipPageResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}

private struct GzipPageConnector: PublicWebConnecting {
    let body: Data
    let framing: String
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        var wire = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=windows-1252\r\nContent-Encoding: gzip\r\n".utf8)
        switch framing {
        case "length": wire.append(Data("Content-Length: \(body.count)\r\n\r\n".utf8)); wire.append(body)
        case "chunked":
            wire.append(Data("Transfer-Encoding: chunked\r\n\r\n".utf8))
            for start in stride(from: 0, to: body.count, by: 29) {
                let piece = body[start..<min(start + 29, body.count)]
                wire.append(Data("\(String(piece.count, radix: 16))\r\n".utf8)); wire.append(piece); wire.append(Data("\r\n".utf8))
            }
            wire.append(Data("0\r\n\r\n".utf8))
        default: wire.append(Data("\r\n".utf8)); wire.append(body)
        }
        var decoder = WebHTTPResponseDecoder(maximumBody: maximumBody, allowsTextPrefix: true)
        for start in stride(from: 0, to: wire.count, by: 113) {
            let end = min(start + 113, wire.count)
            if let response = try decoder.append(wire[start..<end], endOfStream: end == wire.count) { return response }
        }
        throw PublicWebError.refused("The controlled gzip fixture did not complete.")
    }
}

final class GzipPageDeviceTests: XCTestCase {
    private func bytes(_ hex: String, sha256: String) throws -> Data {
        var result = Data(); var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 2)
            result.append(try XCTUnwrap(UInt8(hex[start..<end], radix: 16))); start = end
        }
        XCTAssertEqual(SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined(), sha256)
        return result
    }
    private func client(_ body: Data, _ framing: String) -> PublicWebClient {
        PublicWebClient(resolver: GzipPageResolver(), connector: GzipPageConnector(body: body, framing: framing))
    }
    private func attach(_ observations: [[String: Any]], complete: Bool) {
        let record: [String: Any] = ["purpose": "native-controlled-gzip-page-tools", "completed": complete,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "referenceSHA256": GzipPageReference.sourceSHA256, "observations": observations,
            "limitations": ["Controlled wire bytes use the canonical decoder, extractor, tools and app-owned temporary filesystem. Resolver and connector are injected.",
                "No live DNS/TLS, external provider, model inference, touch UI, accessibility or OS lifecycle is verified.",
                "A capped decoded prefix does not validate its unread gzip trailer. These methods do not close P13."]]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "gzip-page-native-observations"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testNativeGzipUnicodeReadFindSave() async throws {
        let body = try bytes(GzipPageReference.unicodeHex, sha256: GzipPageReference.unicodeSHA256)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        var observations: [[String: Any]] = []; var complete = false
        defer { attach(observations, complete: complete) }
        for framing in ["length", "chunked", "close"] {
            let current = client(body, framing)
            let document = try await current.fetch("https://example.com/gzip", maximumBody: WebPageText.maximumBytes)
            XCTAssertTrue(document.response.bodyWasGzipDecoded); XCTAssertTrue(document.response.bodyIsComplete)
            let decoded = try WebPageText.extract(document)
            XCTAssertEqual(decoded, GzipPageReference.unicodeText)
            guard document.response.bodyWasGzipDecoded, document.response.bodyIsComplete,
                  decoded == GzipPageReference.unicodeText else { return }
            let tools = WebTools(client: current)
            for (name, extra) in [("read", ""), ("find", ",\"find\":\"Cedar\""), ("save", ",\"save_to\":\"\(framing).txt\"")] {
                let call = AgentToolCall(id: name, name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/gzip\"\(extra)}")
                let result = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: call), workspace: workspace)
                XCTAssertFalse(result.rejected, result.text); XCTAssertTrue(result.text.contains("Cedar 730"))
                XCTAssertFalse(result.text.contains("This is a page prefix"))
                observations.append(["framing": framing, "action": name, "rejected": result.rejected, "text": result.text])
                guard !result.rejected, result.text.contains("Cedar 730") else { return }
            }
            let saved = try Data(contentsOf: root.appendingPathComponent(framing + ".txt"))
            XCTAssertEqual(saved, Data(GzipPageReference.unicodeText.utf8))
            guard saved == Data(GzipPageReference.unicodeText.utf8) else { return }
            observations.append(["framing": framing, "savedBytes": saved.count,
                "savedSHA256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined()])
        }
        complete = true
    }
    func testNativeGzipExpansionPrefixAndCorruptionRefusal() async throws {
        let body = try bytes(GzipPageReference.expansionHex, sha256: GzipPageReference.expansionSHA256)
        var corrupt = try bytes(GzipPageReference.unicodeHex, sha256: GzipPageReference.unicodeSHA256)
        corrupt[corrupt.count - 8] ^= 1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        var settings = WebToolSettings(); settings.fetchEnabled = true; settings.mode = .ask
        var observations: [[String: Any]] = []; var complete = false
        defer { attach(observations, complete: complete) }
        for framing in ["length", "chunked", "close"] {
            let current = client(body, framing)
            let document = try await current.fetch("https://example.com/gzip", maximumBody: WebPageText.maximumBytes)
            XCTAssertEqual(document.response.body, Data(repeating: 65, count: WebPageText.maximumBytes))
            XCTAssertTrue(document.response.bodyWasGzipDecoded); XCTAssertFalse(document.response.bodyIsComplete)
            guard document.response.body == Data(repeating: 65, count: WebPageText.maximumBytes),
                  document.response.bodyWasGzipDecoded, !document.response.bodyIsComplete else { return }
            let tools = WebTools(client: current)
            let call = AgentToolCall(id: "save", name: "fetch_url", argumentsJSON: "{\"url\":\"https://example.com/gzip\",\"save_to\":\"\(framing).txt\"}")
            let result = await tools.execute(call, settings: settings, approval: ApprovedToolCall(displayedCall: call), workspace: workspace)
            XCTAssertFalse(result.rejected, result.text)
            XCTAssertTrue(result.text.contains("This is a page prefix")); XCTAssertTrue(result.text.contains("Saved text was shortened"))
            guard !result.rejected, result.text.contains("This is a page prefix"),
                  result.text.contains("Saved text was shortened") else { return }
            let saved = try Data(contentsOf: root.appendingPathComponent(framing + ".txt"))
            XCTAssertEqual(saved.count, WebPageText.maximumBytes)
            XCTAssertTrue(String(decoding: saved, as: UTF8.self).hasPrefix("[Read stopped at the 512 KiB limit"))
            guard saved.count == WebPageText.maximumBytes,
                  String(decoding: saved, as: UTF8.self).hasPrefix("[Read stopped at the 512 KiB limit") else { return }
            var refused = false
            do { _ = try await client(corrupt, framing).fetch("https://example.com/gzip", maximumBody: WebPageText.maximumBytes); XCTFail("Damaged gzip returned text") }
            catch is PublicWebError { refused = true }
            observations.append(["framing": framing, "compressedBytes": body.count, "referenceDecodedBytes": GzipPageReference.expansionDecodedBytes,
                "returnedBytes": document.response.body.count, "bodyIsComplete": document.response.bodyIsComplete,
                "savedBytes": saved.count, "checksumCorruptionRefused": refused,
                "savedSHA256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined()])
            guard refused else { return }
        }
        complete = true
    }
}
