import XCTest
@testable import OpenWeightsCore

private actor SearchFixtureTransport: SearchHTTPTransport {
    var requests: [SearchHTTPRequest] = []
    var responses: [SearchEngine: [WebHTTPResponse]]
    init(_ responses: [SearchEngine: [WebHTTPResponse]]) { self.responses = responses }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests.append(request)
        guard !(responses[request.engine]?.isEmpty ?? true) else { throw PublicWebError.refused("Fixture provider failed.") }
        return responses[request.engine]!.removeFirst()
    }
}
private struct SearchFixtureResolver: PublicWebResolving {
    let addresses: [String]
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { addresses }
}
private actor SearchFixtureConnector: SearchHTTPConnecting {
    var requests: [SearchHTTPRequest] = []
    var ips: [String] = []
    var responses: [WebHTTPResponse]
    init(_ responses: [WebHTTPResponse]) { self.responses = responses }
    func exchangeSearch(_ request: SearchHTTPRequest, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        requests.append(request); ips.append(ip)
        guard !responses.isEmpty else { throw PublicWebError.refused("No fixture response.") }
        return responses.removeFirst()
    }
}
final class SearchTests: XCTestCase {
    func fixture(_ name: String) throws -> String { try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")), encoding: .utf8) }
    func page(_ body: String, status: Int = 200) -> WebHTTPResponse { WebHTTPResponse(status: status, headers: ["content-type": "text/html"], body: Data(body.utf8)) }
    func testCapturedAndroidDuckDuckGoAndYahooPagesProduceRealDestinations() throws {
        for (name, lite) in [("duckduckgo-search.html", false), ("duckduckgo-lite.html", true)] {
            let hits = try SearchResultParser.duckDuckGo(fixture(name), lite: lite, limit: 3)
            XCTAssertEqual(hits.count, 3, name)
            XCTAssertTrue(hits.allSatisfy { !$0.title.isEmpty && $0.url.hasPrefix("http") && !$0.url.contains("uddg=") })
            let expected = lite ? "lfm2" : "linus"
            XCTAssertTrue(hits.contains { ($0.title + " " + $0.snippet).lowercased().contains(expected) }, name)
            XCTAssertTrue(hits.allSatisfy { !$0.snippet.isEmpty && !$0.snippet.contains("<") && !$0.snippet.contains("&amp;") }, name)
        }
        let yahoo = try SearchResultParser.yahoo(fixture("yahoo-search.html"), limit: 3)
        XCTAssertEqual(yahoo.count, 3); XCTAssertTrue(yahoo.allSatisfy { !$0.url.contains("r.search.yahoo.com") && !$0.url.contains("bing.com/aclick") })
        XCTAssertTrue(yahoo.contains { $0.snippet.lowercased().contains("ulaanbaatar") })
    }
    func testLiteAdvertisementDoesNotStealFollowingOrganicSnippet() throws {
        let html = "<table><tr><td><a class='result-link' href='https://ads.example/buy'>Buy now</a></td></tr><tr><td><a class='result-link' href='https://one.example/'>One</a></td></tr><tr><td class='result-snippet'>About one.</td></tr><tr><td><a class='result-link' href='https://two.example/'>Two</a></td></tr><tr><td class='result-snippet'>About two.</td></tr></table>"
        let hits = try SearchResultParser.duckDuckGo(html, lite: true, limit: 5)
        XCTAssertEqual(hits.map(\.snippet), ["", "About one.", "About two."])
    }
    func testBraveEntitiesAndUnsafeResultLinks() throws {
        let html = "<div data-type='web'><a href='https://example.com/'><div class='title'>Cedar &amp; Osaka</div></a><div class='snippet'>Vegetarian &lt; vegan</div></div><div data-type='web'><a href='https://user:secret@example.com/'>bad</a></div><div data-type='web'><a href='javascript:alert(1)'>bad</a></div>"
        let hits = try SearchResultParser.brave(html, limit: 5)
        XCTAssertEqual(hits, [WebSearchHit(title: "Cedar & Osaka", snippet: "Vegetarian < vegan", url: "https://example.com/")])
    }
    func testContext7CapturedMatchFilteringAndMalformedVersusEmptyAnswers() throws {
        let hits = try XCTUnwrap(SearchResultParser.context7(fixture("context7-library.json"), query: "kotlin coroutines", limit: 3))
        XCTAssertFalse(hits.isEmpty); XCTAssertTrue(hits.allSatisfy { $0.url.hasPrefix("https://context7.com/") })
        XCTAssertTrue(SearchResultParser.looksLikeMatch(query: "react hooks", title: "React"))
        XCTAssertFalse(SearchResultParser.looksLikeMatch(query: "what is the weather in Manila right now", title: "PHP: The Right Way"))
        XCTAssertNil(SearchResultParser.context7("not JSON", query: "react", limit: 3))
        XCTAssertEqual(SearchResultParser.context7("{\"results\":[]}", query: "react", limit: 3), [])
        let unrelated = try XCTUnwrap(SearchResultParser.context7(fixture("context7-unrelated.json"), query: "what is the weather in Manila right now", limit: 5))
        XCTAssertFalse(unrelated.contains { $0.title == "Now in Android" || $0.title == "PHP: The Right Way" })
    }
    func testProviderRequestBoundsInjectionAndFormEncoding() throws {
        XCTAssertEqual(SearchHTTPRequest.form([("q", "C++ 旅行 & x=1")]), "q=C%2B%2B+%E6%97%85%E8%A1%8C+%26+x%3D1")
        for url in ["https://evilduckduckgo.com/", "https://duckduckgo.com.evil.example/", "https://127.0.0.1/", "https://duckduckgo.com:8443/"] { XCTAssertThrowsError(try SearchHTTPRequest(engine: .duckduckgo, url: url)) }
        for headers in [["cookie": "x\r\nInjected: y"], ["authorization": "secret"], ["host": "attacker.example"], ["referer": "https://evil.example/"]] { XCTAssertThrowsError(try SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/", headers: headers)) }
        let request = try SearchHTTPRequest(engine: .duckduckgo, url: "https://html.duckduckgo.com/html/", method: .post, headers: ["content-type": "application/x-www-form-urlencoded"], body: Data("q=C%2B%2B".utf8))
        let text = String(decoding: request.encoded, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /html/ HTTP/1.1\r\nHost: html.duckduckgo.com\r\n")); XCTAssertTrue(text.contains("Content-Length: 9\r\n")); XCTAssertTrue(text.hasSuffix("\r\n\r\nq=C%2B%2B"))
    }
    func testSameHostRedirectRetainsProviderPreferencesAnd303DropsTheBody() async throws {
        let connector = SearchFixtureConnector([WebHTTPResponse(status: 303, headers: ["location": "/next"], body: Data()), page("done")])
        let client = SearchHTTPClient(resolver: SearchFixtureResolver(addresses: ["8.8.8.8"]), connector: connector)
        _ = try await client.send(SearchHTTPRequest(engine: .brave, url: "https://search.brave.com/search", method: .post, headers: ["cookie": "useLocation=0; safesearch=off", "content-type": "application/x-www-form-urlencoded"], body: Data("q=Cedar".utf8)))
        let requests = await connector.requests
        XCTAssertEqual(requests[1].method, .get); XCTAssertTrue(requests[1].body.isEmpty)
        XCTAssertNil(requests[1].headers["content-type"]); XCTAssertEqual(requests[1].headers["cookie"], "useLocation=0; safesearch=off")
    }
    func testBlankBraveTitleFallsBackAndMalformedContextEntriesDoNotDiscardGoodHits() throws {
        let brave = try SearchResultParser.brave("<div data-type='web'><a href='https://example.com/'>Cedar<div class='title'> </div></a><div class='snippet'>Status</div></div>", limit: 3)
        XCTAssertEqual(brave.first?.title, "Cedar")
        let context = SearchResultParser.context7("{\"results\":[4,{\"title\":\"React\",\"id\":\"/facebook/react\"},null]}", query: "react hooks", limit: 3)
        XCTAssertEqual(context?.first?.title, "React")
    }
    func testHeaderDecoderPreservesSeparateSetCookiesIncludingExpiresCommas() throws {
        var decoder = WebHTTPResponseDecoder()
        let response = try XCTUnwrap(decoder.append(Data("HTTP/1.1 200 OK\r\nSet-Cookie: a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT\r\nSet-Cookie: b=2; Path=/\r\nContent-Length: 0\r\n\r\n".utf8)))
        XCTAssertEqual(response.setCookieHeaders.count, 2); XCTAssertTrue(response.setCookieHeaders[0].contains("Wed, 21 Oct"))
    }
    func testCookiesAreScopedToProviderDomainHostPathAndExpiry() async throws {
        let cookies = ["shared=1; Domain=duckduckgo.com; Path=/; Secure", "hostOnly=2; Path=/", "wrong=3; Domain=evil.example; Path=/", "narrow=4; Domain=duckduckgo.com; Path=/private", "expired=5; Domain=duckduckgo.com; Max-Age=0"]
        let connector = SearchFixtureConnector([WebHTTPResponse(status: 200, headers: [:], body: Data(), setCookieHeaders: cookies), page(""), page("")])
        let client = SearchHTTPClient(resolver: SearchFixtureResolver(addresses: ["127.0.0.1", "8.8.8.8"]), connector: connector)
        _ = try await client.send(SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/"))
        _ = try await client.send(SearchHTTPRequest(engine: .duckduckgo, url: "https://html.duckduckgo.com/html/"))
        _ = try await client.send(SearchHTTPRequest(engine: .brave, url: "https://search.brave.com/search"))
        let requests = await connector.requests; let ips = await connector.ips
        XCTAssertEqual(ips, ["8.8.8.8", "8.8.8.8", "8.8.8.8"])
        XCTAssertEqual(requests[1].headers["cookie"], "shared=1"); XCTAssertNil(requests[2].headers["cookie"])
    }
    func testProviderRedirectsRefuseForeignAndPrivateHostsAndNeverDialPrivateDNS() async throws {
        for destination in ["https://example.com/", "https://127.0.0.1/", "https://duckduckgo.com.evil.example/"] {
            let connector = SearchFixtureConnector([WebHTTPResponse(status: 302, headers: ["location": destination], body: Data())])
            let client = SearchHTTPClient(resolver: SearchFixtureResolver(addresses: ["8.8.8.8"]), connector: connector)
            do { _ = try await client.send(SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/")); XCTFail(destination) } catch {}
            let count = await connector.requests.count; XCTAssertEqual(count, 1)
        }
        let connector = SearchFixtureConnector([])
        let client = SearchHTTPClient(resolver: SearchFixtureResolver(addresses: ["10.1.1.1"]), connector: connector)
        do { _ = try await client.send(SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/")); XCTFail("Private provider DNS connected.") } catch {}
        let count = await connector.requests.count; XCTAssertEqual(count, 0)
    }
    func testRateLimitedDuckDuckGoFallsBackAndEmptyDocumentationIsAnAnswer() async throws {
        let transport = SearchFixtureTransport([.duckduckgo: [page("landing"), page("challenge", status: 202), page("challenge", status: 202)], .brave: [page("<div data-type='web'><a href='https://example.com/'>Cedar</a><div class='snippet'>A useful result.</div></div>")]])
        let result = try await WebSearchProviders(transport: transport).search(query: "Cedar status", settings: WebSearchSettings())
        XCTAssertEqual(result?.engine, .brave)
        let requests = await transport.requests; XCTAssertEqual(requests.map(\.engine), [.duckduckgo,.duckduckgo,.duckduckgo,.brave]); XCTAssertEqual(requests[1].method, .post); XCTAssertEqual(String(decoding: requests[1].body, as: UTF8.self), "q=Cedar+status")
        var settings = WebSearchSettings(); settings.documentation = true
        let empty = SearchFixtureTransport([.context7: [page("{\"results\":[]}")]])
        let answer = try await WebSearchProviders(transport: empty).search(query: "react hooks", settings: settings)
        XCTAssertEqual(answer?.hits, []); let count = await empty.requests.count; XCTAssertEqual(count, 1)
    }
    func testSearchToolPrivateDataApprovalSingleUseAndDurableStructuredSources() async throws {
        let html = "<div data-type='web'><a href='https://example.com/'>Cedar</a><div class='snippet'>A useful long snippet for the latest public Cedar information.</div></div>"
        let transport = SearchFixtureTransport([.brave: [page(html)]])
        let tools = WebTools(searchTransport: transport)
        var settings = WebToolSettings(); settings.search.engines = [.brave]
        let call = AgentToolCall(id: "search", name: "web_search", argumentsJSON: "{\"query\":\"Cedar status\"}")
        await tools.beginTurn(carriesUntrustedText: true)
        var needs = await tools.requiresApproval(call, mode: .auto); XCTAssertFalse(needs)
        await tools.notePrivateRead(); needs = await tools.requiresApproval(call, mode: .auto); XCTAssertTrue(needs)
        var result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        let ticket = ApprovedToolCall(displayedCall: call)
        result = await tools.execute(call, settings: settings, approval: ticket)
        XCTAssertFalse(result.rejected); XCTAssertTrue(result.untrustedText); XCTAssertEqual(result.searchEvidence?.engine, .brave); XCTAssertEqual(result.searchEvidence?.query, "Cedar status"); XCTAssertEqual(result.searchEvidence?.hits.count, 1)
        result = await tools.execute(call, settings: settings, approval: ticket); XCTAssertTrue(result.rejected)
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    func testOffPlanAllProvidersOffLongQueryAndCancellationMakeNoRequests() async throws {
        let transport = SearchFixtureTransport([:]); let tools = WebTools(searchTransport: transport)
        let call = AgentToolCall(id: "search", name: "web_search", argumentsJSON: "{\"query\":\"Cedar\"}")
        var settings = WebToolSettings(); settings.search.enabled = false
        var result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.search.enabled = true; settings.mode = .plan
        result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.mode = .auto; settings.search.engines = []
        result = await tools.execute(call, settings: settings); XCTAssertTrue(result.rejected)
        settings.search.engines = [.brave]
        let long = AgentToolCall(id: "long", name: "web_search", argumentsJSON: "{\"query\":\"" + String(repeating: "x", count: 121) + "\"}")
        result = await tools.execute(long, settings: settings); XCTAssertTrue(result.rejected)
        let captured = settings
        let stopped = Task { withUnsafeCurrentTask { $0?.cancel() }; return await tools.execute(call, settings: captured) }
        result = await stopped.value; XCTAssertTrue(result.rejected)
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
}
