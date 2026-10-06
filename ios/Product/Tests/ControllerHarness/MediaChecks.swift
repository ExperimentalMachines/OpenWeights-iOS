import Foundation
import ImageIO
import CoreGraphics
import OpenWeightsCore

private actor ControllerMediaTransport: SearchHTTPTransport {
    var requests = 0; let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests += 1
        if slow { try await Task.sleep(nanoseconds: 20_000_000_000) }
        let body = request.address.url.path == "/" ? "vqd='4-123'" : "{\"results\":[{\"title\":\"Cedar picture\",\"thumbnail\":\"https://example.com/thumb.png\",\"image\":\"https://example.com/full.png\",\"url\":\"https://example.com/source\"}]}"
        return WebHTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
    }
}
private struct ControllerMediaResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private actor ControllerMediaConnector: PublicWebConnecting {
    var requests = 0; let image: Data
    init() throws {
        let context = try XCTImageContext()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil), let image = context.makeImage() else { throw CheckFailure("Image fixture could not be made.") }
        CGImageDestinationAddImage(destination, image, nil); guard CGImageDestinationFinalize(destination) else { throw CheckFailure("Image fixture could not be encoded.") }
        self.image = bytes as Data
    }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse { requests += 1; return WebHTTPResponse(status: 200, headers: ["content-type": "image/png"], body: image) }
}
private func XCTImageContext() throws -> CGContext {
    guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CheckFailure("Image context unavailable.") }
    context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16)); return context
}
extension ControllerChecks {
    @MainActor static func mediaChecks(_ passed: inout [String]) async throws {
        let transport = ControllerMediaTransport(); let connector = try ControllerMediaConnector()
        let fixture = try Fixture(mode: .media, write: false, webClient: PublicWebClient(resolver: ControllerMediaResolver(), connector: connector), searchTransport: transport); defer { fixture.cleanup() }
        fixture.web.mediaEnabled = true; fixture.files.mode = .ask; try await fixture.loadAndSend()
        try await wait("Pictures did not ask") { fixture.chat.pendingToolApproval != nil }
        try require(await transport.requests == 0 && fixture.chat.pendingToolApprovalContext?.contains("DuckDuckGo") == true && fixture.chat.pendingToolApprovalContext?.contains("thumbnails") == true, "Pictures left the device before query/thumbnail disclosure and approval.")
        fixture.chat.answerToolApproval(approved: true); try await wait("Approved pictures did not complete") { !fixture.chat.busy }
        let tool = fixture.chat.current!.messages.first { $0.toolName == "show_pictures" }
        try require(tool?.status == .complete && tool?.toolUntrustedText == true && tool?.mediaEvidence?.hits.first?.sourceURL == "https://example.com/source", "Media attribution or provenance was not saved.")
        let key = tool?.mediaEvidence?.hits.first?.previewKey ?? ""; let bytes = await fixture.web.mediaCache.cached(key)
        try require(bytes != nil && fixture.runtime.captures.last!.messages.contains { $0["content"]?.contains("image: https://example.com/thumb.png https://example.com/source") == true }, "Pictures were not cached or their source was missing from the answer pass.")
        let reopened = try ConversationStore(file: fixture.conversationFile); let stored = try await reopened.conversation(fixture.chat.current!.id); let previewRequests = await connector.requests
        try require(stored.messages.first { $0.toolName == "show_pictures" } == tool && previewRequests == 1, "Media source/cache identity did not reopen.")
        passed.append("approved-pictures-cache-attributed-preview-and-durable-evidence-feed-the-answer-pass")

        let declinedTransport = ControllerMediaTransport(); let declined = try Fixture(mode: .media, write: false, searchTransport: declinedTransport); defer { declined.cleanup() }
        declined.web.mediaEnabled = true; declined.files.mode = .ask; try await declined.loadAndSend(); try await wait("Decline did not ask") { declined.chat.pendingToolApproval != nil }
        declined.chat.answerToolApproval(approved: false); try await wait("Declined pictures hung") { !declined.chat.busy }
        try require(await declinedTransport.requests == 0 && declined.chat.current!.messages.allSatisfy { $0.mediaEvidence == nil }, "Declined query requested media.")
        passed.append("declined-picture-query-makes-no-provider-or-preview-requests")

        let privateTransport = ControllerMediaTransport(); let privateRead = try Fixture(mode: .readThenMedia, write: false, searchTransport: privateTransport); defer { privateRead.cleanup() }
        try await privateRead.prepareFiles(); privateRead.web.mediaEnabled = true; try await privateRead.loadAndSend(); try await wait("Private picture query did not ask") { privateRead.chat.pendingToolApproval != nil }
        try require(await privateTransport.requests == 0 && privateRead.chat.pendingToolApproval?.displayedCall.name == "show_pictures", "Private file read did not gate picture-query egress.")
        privateRead.chat.answerToolApproval(approved: false); try await wait("Declined private query hung") { !privateRead.chat.busy }
        passed.append("private-file-read-requires-exact-media-query-approval-in-auto")

        let slow = ControllerMediaTransport(slow: true); let stopped = try Fixture(mode: .media, write: false, searchTransport: slow); defer { stopped.cleanup() }
        stopped.web.mediaEnabled = true; try await stopped.loadAndSend(); for _ in 0..<200 { if await slow.requests > 0 { break }; try await Task.sleep(nanoseconds: 1_000_000) }; let started = await slow.requests; try require(started > 0, "Slow provider never started.")
        stopped.web.mediaEnabled = false; try await wait("Picture switch did not stop active request") { !stopped.chat.busy }
        try require(stopped.chat.current!.messages.allSatisfy { $0.mediaEvidence == nil }, "Switched-off request saved media evidence.")
        passed.append("switching-pictures-off-cancels-an-active-media-request")

        let suite = "media-default-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let settings = WebController(defaults: defaults); try require(settings.mediaEnabled && settings.definitions.contains { $0.name == "show_pictures" }, "Pictures did not inherit Android's enabled default.")
        settings.searchEnabled = false; try require(settings.definitions.contains { $0.name == "show_pictures" }, "Search switch also disabled pictures.")
        settings.mediaEnabled = false; let reopenedSettings = WebController(defaults: defaults)
        try require(!reopenedSettings.mediaEnabled && !reopenedSettings.definitions.contains { $0.name == "show_pictures" }, "The picture switch did not persist independently.")
        passed.append("picture-default-on-and-independent-switch-persists-across-controller-reopen")

        let unsupported = try Fixture(mode: .media, supportsTools: false, write: false); defer { unsupported.cleanup() }
        unsupported.web.mediaEnabled = true; try await unsupported.loadAndSend(); try await wait("Unsupported model chat hung") { !unsupported.chat.busy }
        try require(unsupported.runtime.captures.first?.tools.isEmpty == true && unsupported.chat.error == nil, "Picture defaults blocked ordinary unsupported-model chat.")
        passed.append("non-tool-models-can-chat-with-picture-default-on-without-receiving-media-tools")
    }
}
