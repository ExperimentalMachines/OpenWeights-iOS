import Foundation
import XCTest
import OpenWeightsCore
@testable import OpenWeights

private actor NativeShortlistTransport: HubDiscoveryTransport {
    private var missing = true
    private(set) var requests: [URL] = []
    func recover() { missing = false }
    func get(_ url: URL) async throws -> HubAPIResponse {
        requests.append(url)
        let id = url.path.replacingOccurrences(of: "/api/models/", with: "")
        if id == HubShortlist.recommended[1], missing { return HubAPIResponse(status: 503, data: Data()) }
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "tags": [HubShortlist.experimental.contains(id) ? "executorch" : "gguf"], "pipeline_tag": "text-generation"])
        return HubAPIResponse(status: 200, data: data)
    }
}
extension ProductTests {
    func testNativeShortlistControllerFilteringPartialFailureAndRetry() async throws {
        let transport = NativeShortlistTransport()
        let discovery = DiscoveryController(client: HubDiscoveryClient(transport: transport))
        defer { discovery.cancel() }
        var q = HubQuery(); q.shortlistOnly = true
        discovery.search(q); try await waitUntil(seconds: 10) { !discovery.busy }
        XCTAssertNil(discovery.error); XCTAssertFalse(discovery.hasMore)
        XCTAssertEqual(discovery.unavailableRepositories, [HubShortlist.recommended[1]])
        XCTAssertEqual(discovery.models.count, 5)
        await transport.recover(); discovery.retry(); try await waitUntil(seconds: 10) { !discovery.busy }
        XCTAssertNil(discovery.error); XCTAssertTrue(discovery.unavailableRepositories.isEmpty)
        XCTAssertEqual(discovery.models.map(\.id), HubShortlist.recommended + HubShortlist.experimental)
        q.text = "QWEN"; discovery.search(q); try await waitUntil(seconds: 10) { !discovery.busy }
        XCTAssertEqual(discovery.models.map(\.id), ["unsloth/Qwen3-1.7B-GGUF"])
        q.text = ""; q.runtimes = [.executorch]; discovery.search(q); try await waitUntil(seconds: 10) { !discovery.busy }
        XCTAssertEqual(discovery.models.map(\.id), HubShortlist.experimental)
        XCTAssertTrue(discovery.models.allSatisfy(\.experimental)); XCTAssertFalse(discovery.hasMore)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 24); XCTAssertTrue(requests.allSatisfy { $0.query == nil })
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: ["purpose":"native-shortlist-controller-fixtures", "completed":true,
            "shortlist":HubShortlist.recommended, "experimental":HubShortlist.experimental,
            "requestCount":requests.count, "actions":["partial-repository-error-visible","retry-recovers-six-exact-ids","typing-stays-inside-shortlist","runtime-filter-keeps-experimental-label","no-pagination"],
            "limitations":["Controlled API and direct controller calls. No native gestures, model download, inference or default recommendation claim."]],options:[.prettyPrinted,.sortedKeys]), uniformTypeIdentifier:"public.json")
        attachment.name="native-shortlist-controller.json";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testNativeLivePublicAndroidShortlistMetadata() async throws {
        let discovery = DiscoveryController(client:HubDiscoveryClient(transport:HubAPITransport(useStoredCredential:false)))
        defer { discovery.cancel() }
        var q=HubQuery();q.shortlistOnly=true
        discovery.search(q);try await waitUntil(seconds:120) { !discovery.busy }
        XCTAssertNil(discovery.error)
        XCTAssertEqual(discovery.models.filter { !$0.experimental }.map(\.id),HubShortlist.recommended)
        XCTAssertEqual(Set(discovery.models.map(\.id)+discovery.unavailableRepositories),Set(HubShortlist.recommended+HubShortlist.experimental))
        XCTAssertTrue(Set(discovery.models.map(\.id)).isDisjoint(with:discovery.unavailableRepositories))
        XCTAssertFalse(discovery.hasMore);XCTAssertTrue(discovery.models.allSatisfy { !$0.runtimes.isEmpty })
        let rows=discovery.models.map { model in ["id":model.id,"runtimes":HubRuntime.allCases.filter { model.runtimes.contains($0) }.map(\.rawValue),"experimental":model.experimental,"gated":model.gated] as [String:Any] }
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:["purpose":"native-live-public-android-shortlist", "repositories":rows,"unavailable":discovery.unavailableRepositories,"controllerError":discovery.error ?? "", "completed":discovery.error == nil && discovery.models.filter { !$0.experimental }.count == 4 && Set(discovery.models.map(\.id)+discovery.unavailableRepositories) == Set(HubShortlist.recommended+HubShortlist.experimental),
            "limitations":["Fresh public API metadata only, with stored credentials disabled. Repository format tags do not prove loading, fit, quality or iPhone recommendations. No model weight transfer or inference."]],options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name="native-live-shortlist.json";attachment.lifetime = .keepAlways;add(attachment)
    }
}
