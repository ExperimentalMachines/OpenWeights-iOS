import XCTest
import ImageIO
import CoreGraphics
@testable import OpenWeightsCore

private actor MediaFixtureTransport: SearchHTTPTransport {
    var requests: [SearchHTTPRequest] = []
    var responses: [WebHTTPResponse]
    init(_ responses: [WebHTTPResponse]) { self.responses = responses }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw PublicWebError.refused("No provider fixture.") }
        return responses.removeFirst()
    }
}
private struct MediaResolver: PublicWebResolving {
    var ip = "8.8.8.8"
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { [ip] }
}
private actor MediaConnector: PublicWebConnecting {
    var count = 0; let bytes: Data; let mime: String; let slow: Bool
    init(_ bytes: Data, mime: String = "image/png", slow: Bool = false) { self.bytes = bytes; self.mime = mime; self.slow = slow }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        count += 1
        if slow { try await Task.sleep(nanoseconds: 20_000_000_000) }
        return WebHTTPResponse(status: 200, headers: ["content-type": mime], body: bytes)
    }
}
final class MediaTests: XCTestCase {
    let imageJSON = "{\"results\":[{\"title\":\"Cedar picture\",\"thumbnail\":\"https://cdn.example.com/small.png\",\"image\":\"https://cdn.example.com/full.png\",\"url\":\"https://example.com/attribution\",\"width\":800,\"height\":400}]}"
    func response(_ body: String, status: Int = 200) -> WebHTTPResponse { WebHTTPResponse(status: status, headers: [:], body: Data(body.utf8)) }
    func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("media-check-" + UUID().uuidString) }
    func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let image = try XCTUnwrap(context.makeImage()); let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination)); return bytes as Data
    }
    func testTokenSpellingsBoundsAndInjectionRefusal() {
        for spelling in ["vqd='4-123_456'", "vqd=\"4-123_456\"", "vqd=4-123_456;"] { XCTAssertEqual(DuckDuckGoMediaProvider.token(in: spelling), "4-123_456") }
        XCTAssertNil(DuckDuckGoMediaProvider.token(in: "vqd=")); XCTAssertNil(DuckDuckGoMediaProvider.token(in: "vqd=" + String(repeating: "a", count: 257)))
        XCTAssertNil(DuckDuckGoMediaProvider.token(in: String(repeating: "x", count: 1_048_577)))
    }
    func testImageAndVideoRowsAreBoundedAttributedAndSchemeChecked() throws {
        let image = try XCTUnwrap(DuckDuckGoMediaProvider.hits(in: imageJSON, kind: .images)?.first)
        XCTAssertEqual(image.sourceURL, "https://example.com/attribution"); XCTAssertEqual(image.targetURL, "https://cdn.example.com/full.png"); XCTAssertEqual(image.width, 800)
        let body = "{\"results\":[null,4,{\"thumbnail\":\"https://127.0.0.1/a.png\"},{\"image\":\"http://example.com/a.png\"},{\"thumbnail\":\"https://user:pass@example.com/a.png\"},{\"thumbnail\":\"https://example.com/good.png\",\"url\":\"tel:123\"}]}"
        let good = try XCTUnwrap(DuckDuckGoMediaProvider.hits(in: body, kind: .images)); XCTAssertEqual(good.count, 1); XCTAssertEqual(good[0].sourceURL, good[0].thumbnailURL); XCTAssertEqual(good[0].title, "Untitled")
        let video = try XCTUnwrap(DuckDuckGoMediaProvider.hits(in: "{\"results\":[{\"title\":\"Clip\",\"images\":{\"medium\":\"https://example.com/thumb.jpg\"},\"content\":\"https://example.com/watch\"}]}", kind: .videos)?.first)
        XCTAssertEqual(video.sourceURL, "https://example.com/watch"); XCTAssertEqual(video.kind, .videos)
        let rows = (0..<20).map { "{\"thumbnail\":\"https://example.com/\($0).png\"}" }.joined(separator: ",")
        XCTAssertEqual(DuckDuckGoMediaProvider.hits(in: "{\"results\":[" + rows + "]}", kind: .images)?.count, 8)
    }
    func testProviderUsesPerQueryTokenAndSeparateImageVideoEndpoints() async throws {
        let transport = MediaFixtureTransport([response("vqd='4-123'"), response(imageJSON), response("vqd=4-456;"), response("{\"results\":[{\"images\":{\"medium\":\"https://example.com/t.jpg\"},\"content\":\"https://example.com/watch\"}]}")])
        let provider = DuckDuckGoMediaProvider(transport: transport)
        let images = try await provider.search(query: "C++ 旅行", kind: .images); XCTAssertEqual(images?.count, 1)
        let videos = try await provider.search(query: "otters", kind: .videos); XCTAssertEqual(videos?.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests[1].address.url.path, "/i.js"); XCTAssertEqual(requests[3].address.url.path, "/v.js")
        XCTAssertTrue(requests[1].address.target.contains("q=C%2B%2B+%E6%97%85%E8%A1%8C&vqd=4-123")); XCTAssertTrue(requests.allSatisfy { $0.engine == .duckduckgo && $0.method == .get })
    }
    func testChallengesMalformedAndNoDrawableRowsAreProviderFailures() async throws {
        for responses in [[response("challenge", status: 202)], [response("consent")], [response("vqd='4-123'"), response("not JSON")], [response("vqd='4-123'"), response("{\"results\":[]}")]] {
            let hits = try await DuckDuckGoMediaProvider(transport: MediaFixtureTransport(responses)).search(query: "otters", kind: .images); XCTAssertNil(hits)
        }
    }
    func testSwitchPlanUnattendedBadQueryAndCancelledCallHaveNoEgress() async throws {
        let transport = MediaFixtureTransport([]); let tools = WebTools(searchTransport: transport)
        let call = AgentToolCall(id: "pictures", name: "show_pictures", argumentsJSON: "{\"query\":\"otters\"}")
        var settings = WebToolSettings(); settings.mediaEnabled = false
        var result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.mediaEnabled = true; settings.mode = .plan
        result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.mode = .auto; result = await tools.execute(call, settings: settings, unattended: true); XCTAssertTrue(result.rejected)
        let bad = AgentToolCall(id: "bad", name: "show_pictures", argumentsJSON: "{\"query\":\"" + String(repeating: "x", count: 121) + "\"}")
        result = await tools.execute(bad, settings: settings); XCTAssertTrue(result.rejected)
        let captured = settings; let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return await tools.execute(call, settings: captured) }
        result = await task.value; XCTAssertTrue(result.rejected); let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
    func testPrivateQueryExactSingleUseApprovalAndModelTextExcludePreviewBytes() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let connector = MediaConnector(try png()); let cache = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(), connector: connector))
        let transport = MediaFixtureTransport([response("vqd='4-123'"), response(imageJSON)])
        let tools = WebTools(searchTransport: transport, previews: cache); await tools.beginTurn(carriesUntrustedText: true, carriesPrivateData: true)
        let call = AgentToolCall(id: "pictures", name: "show_pictures", argumentsJSON: "{\"q\":\"Cedar\",\"type\":\"images\"}")
        var result = await tools.execute(call, settings: WebToolSettings()); XCTAssertTrue(result.rejected)
        let altered = ApprovedToolCall(displayedCall: AgentToolCall(id: "pictures", name: "show_pictures", argumentsJSON: "{\"q\":\"Other\"}"))
        result = await tools.execute(call, settings: WebToolSettings(), approval: altered); XCTAssertTrue(result.rejected)
        let approval = ApprovedToolCall(displayedCall: call)
        result = await tools.execute(call, settings: WebToolSettings(), approval: approval)
        XCTAssertFalse(result.rejected); XCTAssertTrue(result.untrustedText); XCTAssertEqual(result.mediaEvidence?.query, "Cedar")
        let key = try XCTUnwrap(result.mediaEvidence?.hits.first?.previewKey); let cached = await cache.cached(key); XCTAssertNotNil(cached)
        XCTAssertTrue(result.text.contains("image: https://cdn.example.com/small.png https://example.com/attribution")); XCTAssertFalse(result.text.contains(key)); XCTAssertFalse(result.text.contains("base64"))
        result = await tools.execute(call, settings: WebToolSettings(), approval: approval); XCTAssertTrue(result.rejected)
        let requests = await transport.requests.count; XCTAssertEqual(requests, 2)
    }
    func testPreviewsDownsampleStripMetadataAndReuseOwnedCacheWithoutNetwork() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try XCTUnwrap(CGImageSourceCreateWithData(try png() as CFData, nil))
        let originalImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(original, 0, nil)); let privateBytes = NSMutableData()
        let encoded = try XCTUnwrap(CGImageDestinationCreateWithData(privateBytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(encoded, originalImage, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 14.6, kCGImagePropertyGPSLatitudeRef: "N"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private Cedar note"], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private author"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(encoded))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(privateBytes, nil)!, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary]); XCTAssertEqual((originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] as? String, "Private Cedar note")
        let connector = MediaConnector(privateBytes as Data, mime: "image/jpeg"); let cache = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(), connector: connector))
        let first = try await cache.prepare("https://example.com/thumb.png"); let second = try await cache.prepare("https://example.com/thumb.png"); XCTAssertEqual(first, second)
        let count = await connector.count; XCTAssertEqual(count, 1)
        let saved = await cache.cached(first); let bytes = try XCTUnwrap(saved); XCTAssertLessThanOrEqual(bytes.count, MediaPreviewCache.maximumPreview)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil)); let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 288); XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 144)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary]); XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment]); XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        let invalid = await cache.cached("../../outside"); XCTAssertNil(invalid)
        XCTAssertThrowsError(try MediaPreviewCache.thumbnail(Data("<svg/>".utf8)))
        XCTAssertThrowsError(try MediaPreviewCache.thumbnail(Data(repeating: 0, count: MediaPreviewCache.maximumBody + 1)))
    }
    func testThumbnailRequestsRefusePrivateDNSAndNonImageContent() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let inward = MediaConnector(try png()); let privateCache = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(ip: "10.0.0.1"), connector: inward))
        do { _ = try await privateCache.prepare("https://public-looking.example/a.png"); XCTFail("Private DNS connected.") } catch {}
        let count = await inward.count; XCTAssertEqual(count, 0)
        let html = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(), connector: MediaConnector(try png(), mime: "text/html")))
        do { _ = try await html.prepare("https://example.com/fake.png"); XCTFail("HTML was cached.") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testCancellationStopsImageFetchAndDoesNotSaveAPreview() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let connector = MediaConnector(try png(), slow: true); let cache = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(), connector: connector))
        let task = Task { try await cache.prepare("https://example.com/slow.png") }
        for _ in 0..<100 { if await connector.count > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled image returned a cache key.") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testCacheEvictsOnlyItsOwnBoundedPreviewEntries() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<260 { try Data([0]).write(to: directory.appendingPathComponent(String(format: "%064x", index) + ".jpg")) }
        let unrelated = directory.appendingPathComponent("user.txt"); try Data("Keep".utf8).write(to: unrelated)
        let cache = MediaPreviewCache(root: directory, client: PublicWebClient(resolver: MediaResolver(), connector: MediaConnector(try png())))
        _ = try await cache.prepare("https://example.com/new.png")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "jpg" }.count, 256); XCTAssertEqual(try String(contentsOf: unrelated), "Keep")
    }
}
