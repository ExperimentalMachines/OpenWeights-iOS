import Foundation
import XCTest
@testable import OpenWeightsCore

private actor ShortlistFixture: HubDiscoveryTransport {
    var replies: [String: HubAPIResponse]
    let cancel: Bool
    private(set) var requests: [URL] = []
    init(_ replies: [String: HubAPIResponse], cancel: Bool = false) { self.replies = replies; self.cancel = cancel }
    func get(_ url: URL) async throws -> HubAPIResponse {
        requests.append(url)
        if cancel { throw CancellationError() }
        return replies[url.path] ?? HubAPIResponse(status: 404, data: Data())
    }
}
final class HubShortlistTests: XCTestCase {
    private let ids = HubShortlist.recommended + HubShortlist.experimental
    private func responses() throws -> [String: HubAPIResponse] {
        var result: [String: HubAPIResponse] = [:]
        for (index, id) in ids.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["id": id,
                "tags": [index < 4 ? "gguf" : "executorch"], "downloads": index * 10,
                "likes": 100 - index, "lastModified": "2026-09-0\(index + 1)T00:00:00Z",
                "gated": index == 1, "pipeline_tag": index == 2 ? "image-text-to-text" : "text-generation"])
            result["/api/models/" + id] = HubAPIResponse(status: 200, data: data)
        }
        return result
    }
    func testExactIDsNoSearchPaginationAndSeparateExperimentalRows() async throws {
        let fixture = ShortlistFixture(try responses())
        let page = try await HubDiscoveryClient(transport: fixture).shortlist(HubQuery())
        XCTAssertEqual(page.models.map(\.id), ids)
        XCTAssertEqual(page.models.filter(\.experimental).map(\.id), HubShortlist.experimental)
        XCTAssertEqual(page.models[0].runtimes, [.gguf]); XCTAssertEqual(page.models[4].runtimes, [.executorch])
        XCTAssertTrue(page.cursors.isEmpty); XCTAssertTrue(page.unavailableRepositories.isEmpty)
        let requests = await fixture.requests
        XCTAssertEqual(Set(requests.map(\.path)), Set(ids.map { "/api/models/" + $0 }))
        XCTAssertEqual(requests.count, 6); XCTAssertTrue(requests.allSatisfy { $0.query == nil && $0.host == "huggingface.co" })
    }
    func testTextRuntimeAndAuthorFiltersStayInsideShortlist() async throws {
        let client = HubDiscoveryClient(transport: ShortlistFixture(try responses()))
        var q = HubQuery(); q.text = "QWEN3"; q.runtimes = [.gguf]
        let text = try await client.shortlist(q); XCTAssertEqual(text.models.map(\.id), [ids[3]])
        q.text = ""; q.author = "LIQUIDAI"; q.runtimes = [.executorch]
        let none = try await client.shortlist(q); XCTAssertTrue(none.models.isEmpty)
        q.author = ""; let compiled = try await client.shortlist(q)
        XCTAssertEqual(compiled.models.map(\.id), HubShortlist.experimental)
        q.runtimes = [.mlx]; let mlx = try await client.shortlist(q); XCTAssertTrue(mlx.models.isEmpty)
    }
    func testGatedTaskSizeAndSortFiltersPreserveExperimentalDistinction() async throws {
        let client = HubDiscoveryClient(transport: ShortlistFixture(try responses()))
        var q = HubQuery(); q.hideGated = true; q.task = .chat; q.maximumParametersBillions = 2
        q.sort = .downloads
        let filtered = try await client.shortlist(q)
        XCTAssertEqual(filtered.models.map(\.id), [ids[3], ids[0], ids[4]])
        q = HubQuery(); q.sort = .recent
        let recent = try await client.shortlist(q)
        XCTAssertEqual(recent.models.map(\.id), [ids[3],ids[2],ids[1],ids[0],ids[5],ids[4]])
        q.sort = .likes; let likes = try await client.shortlist(q); XCTAssertEqual(likes.models.map(\.id), ids)
    }
    func testPartialFailuresRemainVisibleAndRetryCanRecover() async throws {
        var data = try responses(); data["/api/models/"+ids[2]] = HubAPIResponse(status: 503, data: Data())
        let page = try await HubDiscoveryClient(transport: ShortlistFixture(data)).shortlist(HubQuery())
        XCTAssertEqual(page.unavailableRepositories,[ids[2]])
        XCTAssertEqual(page.models.map(\.id),ids.filter { $0 != ids[2] })
        let recovered = try await HubDiscoveryClient(transport: ShortlistFixture(try responses())).shortlist(HubQuery())
        XCTAssertEqual(recovered.models.count,6); XCTAssertTrue(recovered.unavailableRepositories.isEmpty)
    }
    func testWrongRepositoryMalformedAndOversizedMetadataAreNotRows() async throws {
        var data = try responses()
        data["/api/models/"+ids[0]] = HubAPIResponse(status:200,data:Data("{\"id\":\"evil/unlisted\",\"tags\":[\"gguf\"]}".utf8))
        data["/api/models/"+ids[1]] = HubAPIResponse(status:200,data:Data("{}".utf8))
        data["/api/models/"+ids[2]] = HubAPIResponse(status:200,data:Data(repeating:32,count:2_097_153))
        let page = try await HubDiscoveryClient(transport:ShortlistFixture(data)).shortlist(HubQuery())
        XCTAssertEqual(page.unavailableRepositories,Array(ids.prefix(3)))
        XCTAssertEqual(page.models.map(\.id),Array(ids.dropFirst(3)))
    }
    func testAllUnavailableAndCancellationNeverBecomeSuccessfulEmptyLists() async throws {
        do { _ = try await HubDiscoveryClient(transport:ShortlistFixture([:])).shortlist(HubQuery()); XCTFail("Unavailable list must fail") } catch {}
        do { _ = try await HubDiscoveryClient(transport:ShortlistFixture([:],cancel:true)).shortlist(HubQuery()); XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
    }
    func testOrganisationClassificationFiltersPeopleAndDoesNotTreatErrorsAsPeople() async throws {
        var data = try responses()
        for owner in ["LiquidAI","experimentalmachines"] { data["/api/organizations/"+owner+"/avatar"] = HubAPIResponse(status:200,data:Data("{}".utf8)) }
        data["/api/organizations/unsloth/avatar"] = HubAPIResponse(status:404,data:Data())
        var q=HubQuery();q.organisationsOnly=true
        let result=try await HubDiscoveryClient(transport:ShortlistFixture(data)).shortlist(q)
        XCTAssertEqual(result.models.map(\.id),ids.filter { $0 != ids[3] })
        data["/api/organizations/LiquidAI/avatar"] = HubAPIResponse(status:500,data:Data())
        do { _ = try await HubDiscoveryClient(transport:ShortlistFixture(data)).shortlist(q); XCTFail("Unavailable publisher information must fail visibly") } catch {}
    }
    func testUnknownTagsAreNotSilentlyLabeledGGUF() async throws {
        var data = try responses()
        data["/api/models/"+ids[0]]=HubAPIResponse(status:200,data:Data("{\"id\":\"\(ids[0])\",\"tags\":[\"transformers\"]}".utf8))
        data["/api/models/"+ids[1]]=HubAPIResponse(status:200,data:Data("{\"id\":\"\(ids[1])\",\"library_name\":\"mlx\"}".utf8))
        var q=HubQuery();q.runtimes=[.mlx]
        let page=try await HubDiscoveryClient(transport:ShortlistFixture(data)).shortlist(q)
        XCTAssertEqual(page.models.map(\.id),[ids[1]]);XCTAssertEqual(page.models[0].runtimes,[.mlx])
    }
}
