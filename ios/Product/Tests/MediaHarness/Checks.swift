import Foundation
import OpenWeightsCore

actor RecordingTransport: SearchHTTPTransport {
    let base = SearchHTTPClient()
    var observations: [[String: String]] = []
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        do {
            let response = try await base.send(request, timeout: timeout)
            observations.append(["host": request.address.host, "path": request.address.url.path, "status": String(response.status), "bytes": String(response.body.count)])
            return response
        } catch { observations.append(["host": request.address.host, "path": request.address.url.path, "error": error.localizedDescription]); throw error }
    }
}
@main struct MediaHarness {
    static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("openweights-live-media-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport(); let cache = MediaPreviewCache(root: root)
        let tools = WebTools(searchTransport: transport, previews: cache)
        var observations: [[String: Any]] = []
        for kind in [MediaResultKind.images, .videos] {
            await tools.beginTurn(carriesUntrustedText: false)
            let args = try String(decoding: JSONSerialization.data(withJSONObject: ["query": "red panda", "kind": kind.rawValue], options: [.sortedKeys]), as: UTF8.self)
            let result = await tools.execute(AgentToolCall(id: kind.rawValue, name: "show_pictures", argumentsJSON: args), settings: WebToolSettings())
            let evidence = result.mediaEvidence
            var loaded = 0
            for hit in evidence?.hits ?? [] { if let key = hit.previewKey, await cache.cached(key) != nil { loaded += 1 } }
            observations.append(["kind": kind.rawValue, "query": "red panda", "answered": !result.rejected, "hits": (evidence?.hits ?? []).map { ["title": $0.title, "source": $0.sourceURL, "thumbnail": $0.thumbnailURL, "previewCached": $0.previewKey != nil] }, "cachedPreviews": loaded, "refusal": result.rejected ? result.text : ""])
            let proof: [String: Any] = ["status": "live-media-provider-observations", "observations": observations, "providerRequests": await transport.observations,
                "limitations": ["Live Mac provider and image-transport/decode checks, not iPhone inference or UI verification. Provider failures are preserved rather than interpreted as empty search results."]]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
        }
    }
}
