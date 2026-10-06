import XCTest
@testable import OpenWeightsCore

private actor HubFixture: HubDiscoveryTransport {
    enum Reply { case response(HubAPIResponse), failure, cancelled }
    var replies: [Reply]
    var requests: [URL] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func get(_ url: URL) async throws -> HubAPIResponse {
        requests.append(url)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .failure: throw URLError(.timedOut)
        case .cancelled: throw CancellationError()
        }
    }
}

final class HubDiscoveryTests: XCTestCase {
    private func page(_ ids: [String], cursor: String? = nil) throws -> HubFixture.Reply {
        let data = try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] })
        return .response(HubAPIResponse(status: 200, data: data, link: cursor.map { "<https://huggingface.co/api/models?cursor=\($0)>; rel=\"next\"" }))
    }
    private func values(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    func testQueriesKeepUserTextAsDataAndRouteRuntimeAndSizeFilters() throws {
        var query = HubQuery()
        query.text = "  Cedar & cursor=evil  "; query.author = " LiquidAI "; query.sort = .recent
        query.task = .chat; query.parameters = .small; query.hideGated = true
        let gguf = try HubDiscoveryClient.searchURL(query: query, runtime: .gguf, cursor: "opaque+/=", limit: 1000)
        let items = values(gguf)
        XCTAssertEqual(gguf.host, "huggingface.co"); XCTAssertEqual(gguf.path, "/api/models")
        XCTAssertEqual(items["search"], "Cedar & cursor=evil"); XCTAssertEqual(items["author"], "LiquidAI")
        XCTAssertEqual(items["cursor"], "opaque+/="); XCTAssertEqual(items["limit"], "100")
        XCTAssertEqual(items["apps"], "llama.cpp"); XCTAssertEqual(items["pipeline_tag"], "text-generation")
        XCTAssertEqual(items["gated"], "false"); XCTAssertEqual(items["num_parameters"], "min:2B,max:4B")
        XCTAssertEqual(items["sort"], "lastModified"); XCTAssertEqual(query.activeCount, 4)
        let compiled = values(try HubDiscoveryClient.searchURL(query: query, runtime: .executorch))
        XCTAssertEqual(compiled["filter"], "executorch"); XCTAssertNil(compiled["num_parameters"])
        query.maximumParametersBillions = 3
        XCTAssertEqual(values(try HubDiscoveryClient.searchURL(query: query, runtime: .mlx))["num_parameters"], "max:3B")
        query.runtimes = []; XCTAssertEqual(query.effectiveRuntimes, Set(HubRuntime.allCases))
    }
    func testQueryBoundsAndRepositoryTraversalAreRejected() throws {
        var query = HubQuery(); query.text = String(repeating: "x", count: 513)
        XCTAssertThrowsError(try HubDiscoveryClient.searchURL(query: query, runtime: .gguf))
        query.text = ""; query.author = String(repeating: "x", count: 129)
        XCTAssertThrowsError(try HubDiscoveryClient.searchURL(query: query, runtime: .gguf))
        query.author = ""; query.maximumParametersBillions = 0
        XCTAssertThrowsError(try HubDiscoveryClient.searchURL(query: query, runtime: .gguf))
        query.maximumParametersBillions = nil
        XCTAssertThrowsError(try HubDiscoveryClient.searchURL(query: query, runtime: .gguf, cursor: String(repeating: "x", count: 8193)))
        for id in ["../model", "owner/..", "owner/model/path", "owner/m%2Fsecret", "owner/m?token", "/model", "owner/", "旅行/model"] { XCTAssertFalse(HubDiscoveryClient.validRepositoryID(id), id) }
        XCTAssertTrue(HubDiscoveryClient.validRepositoryID("owner/Qwen-0.6B_GGUF"))
    }
    func testPaginationExtractsOnlyCursorAndRejectsUnsafeLinks() throws {
        let result = try HubDiscoveryClient.nextCursor(link: "<https://huggingface.co/api/models?author=untrusted&cursor=opaque%2B%2F%3D>; rel=\"next\"", runtime: .mlx)
        XCTAssertEqual(result, HubCursor(runtime: .mlx, value: "opaque+/="))
        XCTAssertNil(try HubDiscoveryClient.nextCursor(link: nil, runtime: .gguf))
        XCTAssertNil(try HubDiscoveryClient.nextCursor(link: "<https://evil.example/>; rel=\"prev\"", runtime: .gguf))
        for address in ["http://huggingface.co/api/models?cursor=x", "https://huggingface.co.evil.example/api/models?cursor=x", "https://u:p@huggingface.co/api/models?cursor=x", "https://huggingface.co:444/api/models?cursor=x", "https://huggingface.co/api/%6dodels?cursor=x", "https://huggingface.co/api/models?cursor=x#fragment", "https://huggingface.co/api/models?cursor=x&cursor=y", "https://huggingface.co/api/models?cursor="] {
            XCTAssertThrowsError(try HubDiscoveryClient.nextCursor(link: "<\(address)>; rel=next", runtime: .gguf), address)
        }
        XCTAssertThrowsError(try HubDiscoveryClient.nextCursor(link: String(repeating: "x", count: 16385), runtime: .gguf))
    }
    func testDuplicateRepositoriesMergeRuntimeLabelsWithoutReplacingFirstMetadata() async throws {
        let first = HubFixture.Reply.response(HubAPIResponse(status: 200, data: Data("[{\"id\":\"org/shared\",\"downloads\":7}]".utf8)))
        let fixture = HubFixture([first, try page(["org/shared", "org/compiled"]), try page(["org/shared", "org/mlx"])])
        let result = try await HubDiscoveryClient(transport: fixture).search(HubQuery())
        XCTAssertEqual(result.models.map(\.id), ["org/shared", "org/compiled", "org/mlx"])
        XCTAssertEqual(result.models[0].runtimes, Set(HubRuntime.allCases)); XCTAssertEqual(result.models[0].downloads, 7)
        XCTAssertTrue(result.unavailableRuntimes.isEmpty)
    }
    func testLaterPageRequestsOnlyRuntimesWithTypedCursorsAndKeepsQuery() async throws {
        let fixture = HubFixture([try page(["org/second"], cursor: "again")])
        var query = HubQuery(); query.text = "Cedar"; query.author = "org"
        let result = try await HubDiscoveryClient(transport: fixture).search(query, cursors: [HubCursor(runtime: .mlx, value: "next")])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(values(requests[0])["filter"], "mlx")
        XCTAssertEqual(values(requests[0])["cursor"], "next"); XCTAssertEqual(values(requests[0])["search"], "Cedar")
        XCTAssertEqual(values(requests[0])["author"], "org"); XCTAssertEqual(result.cursors, [HubCursor(runtime: .mlx, value: "again")])
    }
    func testPartialFailureIsVisibleAndAllFailuresThrow() async throws {
        let fixture = HubFixture([.failure, try page(["org/compiled"]), .response(HubAPIResponse(status: 403, data: Data()))])
        let result = try await HubDiscoveryClient(transport: fixture).search(HubQuery())
        XCTAssertEqual(result.models.map(\.id), ["org/compiled"]); XCTAssertEqual(result.unavailableRuntimes, [.gguf, .mlx])
        let failed = HubFixture([.failure, .failure, .failure])
        do { _ = try await HubDiscoveryClient(transport: failed).search(HubQuery()); XCTFail("All unavailable searches must throw") } catch {}
    }
    func testCancellationStopsBeforeLaterRuntimeRequests() async throws {
        let fixture = HubFixture([.cancelled, try page(["org/unused"])])
        do { _ = try await HubDiscoveryClient(transport: fixture).search(HubQuery()); XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
        let requests = await fixture.requests; XCTAssertEqual(requests.count, 1)
    }
    func testInvalidRepositoriesAndGatedVariantsAreFiltered() async throws {
        let data = Data("[{\"id\":\"org/open\",\"gated\":false},{\"id\":\"org/string-open\",\"gated\":\"false\"},{\"id\":\"org/manual\",\"gated\":\"manual\"},{\"id\":\"org/auto\",\"gated\":true},{\"id\":\"../escape\"}]".utf8)
        let fixture = HubFixture([.response(HubAPIResponse(status: 200, data: data))])
        var query = HubQuery(); query.runtimes = [.gguf]; query.hideGated = true
        let result = try await HubDiscoveryClient(transport: fixture).search(query)
        XCTAssertEqual(result.models.map(\.id), ["org/open", "org/string-open"])
    }
    func testCompiledNameHintsRespectBandAndKeepUnknownSizes() async throws {
        let fixture = HubFixture([try page(["org/Qwen-0.6B", "org/Qwen-3B", "org/Qwen-7B", "org/Smol-500M", "org/Unknown"]), try page(["org/Qwen-3B", "org/Qwen-7B", "org/Unknown"])])
        var query = HubQuery(); query.runtimes = [.executorch]; query.parameters = .small
        let client = HubDiscoveryClient(transport: fixture)
        let band = try await client.search(query)
        XCTAssertEqual(band.models.map(\.id), ["org/Qwen-3B", "org/Unknown"])
        query.maximumParametersBillions = 4
        let capped = try await client.search(query)
        XCTAssertEqual(capped.models.map(\.id), ["org/Qwen-3B", "org/Unknown"])
    }
    func testSizeHintsAlsoFilterGGUFAndMLXWhenHubReturnsOversizedModels() async throws {
        for runtime in [HubRuntime.gguf, .mlx] {
            let fixture = HubFixture([try page(["org/LFM-230M", "org/LFM-1.2B", "org/LFM-2.6B", "org/LFM-8B-A1B", "org/Unknown"])])
            var query = HubQuery(); query.runtimes = [runtime]; query.maximumParametersBillions = 2
            let result = try await HubDiscoveryClient(transport: fixture).search(query)
            XCTAssertEqual(result.models.map(\.id), ["org/LFM-230M", "org/LFM-1.2B", "org/Unknown"])
        }
    }
    func testOrganisationFilterSkipsEmptyPageAndCachesPublisherClassification() async throws {
        let fixture = HubFixture([try page(["person/one"], cursor: "second"), .response(HubAPIResponse(status: 404, data: Data())),
            try page(["person/two", "org/one", "org/two"]), .response(HubAPIResponse(status: 200, data: Data("{\"avatarUrl\":null}".utf8)))])
        var query = HubQuery(); query.runtimes = [.gguf]; query.organisationsOnly = true
        let result = try await HubDiscoveryClient(transport: fixture).search(query)
        XCTAssertEqual(result.models.map(\.id), ["org/one", "org/two"])
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4); XCTAssertEqual(requests.filter { $0.path.contains("/organizations/") }.count, 2)
        XCTAssertEqual(values(requests[2])["cursor"], "second")
    }
    func testOrganisationFailuresAreNotMisclassifiedOrCached() async throws {
        let fixture = HubFixture([try page(["org/one"]), .response(HubAPIResponse(status: 500, data: Data())), try page(["org/one"]), .response(HubAPIResponse(status: 200, data: Data("{}".utf8)))])
        var query = HubQuery(); query.runtimes = [.gguf]; query.organisationsOnly = true
        let client = HubDiscoveryClient(transport: fixture)
        do { _ = try await client.search(query); XCTFail("Unavailable publisher classification must fail") } catch {}
        let result = try await client.search(query); XCTAssertEqual(result.models.map(\.id), ["org/one"])
        let requests = await fixture.requests; XCTAssertEqual(requests.count, 4)
    }
    func testEmptyFilteredScanIsBoundedAndCursorCyclesStop() async throws {
        let fixture = HubFixture(try (1...4).map { try page(["org/Qwen-70B"], cursor: "next\($0)") })
        var query = HubQuery(); query.runtimes = [.executorch]; query.parameters = .tiny
        let result = try await HubDiscoveryClient(transport: fixture).search(query)
        XCTAssertTrue(result.models.isEmpty); XCTAssertEqual(result.cursors, [HubCursor(runtime: .executorch, value: "next4")])
        let requests = await fixture.requests; XCTAssertEqual(requests.count, 4)
        let cycle = HubFixture([try page(["org/Qwen-70B"], cursor: "again"), try page(["org/Qwen-70B"], cursor: "again")])
        let stopped = try await HubDiscoveryClient(transport: cycle).search(query)
        XCTAssertTrue(stopped.models.isEmpty); XCTAssertTrue(stopped.cursors.isEmpty)
        let cycleRequests = await cycle.requests; XCTAssertEqual(cycleRequests.count, 2)
    }
    func testMalformedOversizedAndExcessRepositoryResponsesFail() async throws {
        for reply in [HubFixture.Reply.response(HubAPIResponse(status: 200, data: Data("{}".utf8))), .response(HubAPIResponse(status: 200, data: Data(repeating: 32, count: 2_097_153))), try page((1...101).map { "org/model\($0)" })] {
            let fixture = HubFixture([reply]); var query = HubQuery(); query.runtimes = [.gguf]
            do { _ = try await HubDiscoveryClient(transport: fixture).search(query); XCTFail("Invalid bounded response must fail") } catch {}
        }
    }
}
