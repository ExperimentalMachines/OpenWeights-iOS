import Foundation
import SwiftSoup

public struct WebSearchHit: Codable, Equatable, Sendable {
    public let title: String
    public let snippet: String
    public let url: String
    public init(title: String, snippet: String, url: String) { self.title = title; self.snippet = snippet; self.url = url }
}
public struct WebSearchEvidence: Codable, Equatable, Sendable {
    public let query: String
    public let engine: SearchEngine
    public let hits: [WebSearchHit]
    public init(query: String, engine: SearchEngine, hits: [WebSearchHit]) { self.query = query; self.engine = engine; self.hits = hits }
}
public struct WebSearchSettings: Sendable {
    public var enabled = true
    public var engines: Set<SearchEngine> = [.duckduckgo, .brave, .yahoo]
    public var documentation = false
    public var resultCount = 3
    public init() {}
    public var providers: [SearchEngine] {
        (documentation ? [.context7] : []) + [.duckduckgo, .brave, .yahoo].filter { engines.contains($0) }
    }
}
public struct WebSearchAnswer: Sendable {
    public let engine: SearchEngine
    public let hits: [WebSearchHit]
}
public struct WebSearchProviders: Sendable {
    private let transport: any SearchHTTPTransport
    public init(transport: any SearchHTTPTransport = SearchHTTPClient()) { self.transport = transport }
    public func search(query: String, settings: WebSearchSettings) async throws -> WebSearchAnswer? {
        guard settings.enabled else { throw PublicWebError.refused("Web search is switched off.") }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf16.count <= 120 else { throw PublicWebError.refused("Search for a few words, at most 120 characters.") }
        let limit = min(5, max(1, settings.resultCount))
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        for engine in settings.providers {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            let hits = try await search(engine, query: query, limit: limit, deadline: deadline)
            try Task.checkCancellation()
            if let hits {
                // Empty is an authoritative API answer. Unparsed HTML is a provider failure.
                return WebSearchAnswer(engine: engine, hits: hits)
            }
        }
        return nil
    }
    public func search(_ engine: SearchEngine, query: String, limit: Int = 3, deadline: TimeInterval? = nil) async throws -> [WebSearchHit]? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf16.count <= 120 else { throw PublicWebError.refused("Search for a few words, at most 120 characters.") }
        let end = deadline ?? ProcessInfo.processInfo.systemUptime + 60
        let limit = min(5, max(1, limit))
        let browser = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
        let browserHeaders = ["user-agent": browser, "accept": "text/html"]
        func page(_ url: String, method: SearchHTTPRequest.Method = .get, headers: [String: String], body: Data = Data()) async throws -> String? {
            try Task.checkCancellation()
            let remaining = end - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            let request = try SearchHTTPRequest(engine: engine, url: url, method: method, headers: headers, body: body)
            do {
                let response = try await transport.send(request, timeout: min(30, remaining))
                try Task.checkCancellation()
                guard response.status == 200, response.body.count <= 1_048_576,
                      response.headers["content-encoding"].map({ $0.lowercased().trimmingCharacters(in: .whitespaces) == "identity" }) ?? true,
                      let text = String(data: response.body, encoding: .utf8) else { return nil }
                return text
            } catch { if error is CancellationError || Task.isCancelled { throw CancellationError() }; return nil }
        }
        let encoded = SearchHTTPRequest.form([(engine == .yahoo ? "p" : engine == .context7 ? "query" : "q", query)])
        switch engine {
        case .duckduckgo:
            _ = try await page("https://duckduckgo.com/?" + encoded, headers: browserHeaders)
            var headers = browserHeaders; headers["referer"] = "https://duckduckgo.com/"; headers["content-type"] = "application/x-www-form-urlencoded"
            for (url, lite) in [("https://html.duckduckgo.com/html/", false), ("https://lite.duckduckgo.com/lite/", true)] {
                if let html = try await page(url, method: .post, headers: headers, body: Data(encoded.utf8)),
                   let hits = try? SearchResultParser.duckDuckGo(html, lite: lite, limit: limit), !hits.isEmpty { return hits }
            }
            return nil
        case .brave:
            var headers = browserHeaders; headers["cookie"] = "useLocation=0; safesearch=off"
            guard let html = try await page("https://search.brave.com/search?" + encoded + "&source=web", headers: headers),
                  let hits = try? SearchResultParser.brave(html, limit: limit), !hits.isEmpty else { return nil }
            return hits
        case .yahoo:
            guard let html = try await page("https://search.yahoo.com/search?" + encoded, headers: browserHeaders),
                  let hits = try? SearchResultParser.yahoo(html, limit: limit), !hits.isEmpty else { return nil }
            return hits
        case .context7:
            guard let text = try await page("https://context7.com/api/v1/search?" + encoded, headers: ["user-agent": "OpenWeights/0.1 (https://github.com/ExperimentalMachines/openweights)", "accept": "application/json"]) else { return nil }
            return SearchResultParser.context7(text, query: query, limit: limit)
        }
    }
}

public enum SearchResultParser {
    private static func hit(title: String, snippet: String, rawURL: String) -> WebSearchHit? {
        guard rawURL.utf8.count <= 8192, let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WebSearchHit(title: WebPageSearch.prefix(title, maximum: 256), snippet: WebPageSearch.prefix(snippet, maximum: 900), url: url.absoluteString)
    }
    public static func duckDuckGo(_ html: String, lite: Bool, limit: Int) throws -> [WebSearchHit] {
        let document = try SwiftSoup.parse(html)
        let anchors = try document.select(lite ? "a.result-link" : "a.result__a").array()
        var hits: [WebSearchHit] = []
        for anchor in anchors {
            try Task.checkCancellation()
            var destination = try anchor.attr("href")
            if destination.contains("uddg="), let wrapper = URLComponents(string: destination.hasPrefix("//") ? "https:" + destination : destination),
               let target = wrapper.queryItems?.first(where: { $0.name == "uddg" })?.value { destination = target }
            var snippet = ""
            if lite {
                // A snippet belongs only to the rows before the next result anchor.
                var row: Element? = anchor.parent()
                while let candidate = row, candidate.tagName() != "tr" { row = candidate.parent() }
                var next = try row?.nextElementSibling()
                while let candidate = next {
                    if try !candidate.select("a.result-link").isEmpty() { break }
                    if let found = try candidate.select("td.result-snippet").first() { snippet = try found.text(); break }
                    next = try candidate.nextElementSibling()
                }
            } else {
                var parent = anchor.parent()
                for _ in 0..<5 {
                    guard let candidate = parent else { break }
                    if try candidate.select("a.result__a").size() > 1 { break }
                    if let found = try candidate.select(".result__snippet").first() { snippet = try found.text(); break }
                    parent = candidate.parent()
                }
            }
            if let result = hit(title: try anchor.text(), snippet: snippet, rawURL: destination) { hits.append(result) }
            if hits.count >= min(5, max(1, limit)) { break }
        }
        return hits
    }
    public static func brave(_ html: String, limit: Int) throws -> [WebSearchHit] {
        let document = try SwiftSoup.parse(html); var hits: [WebSearchHit] = []
        for block in try document.select("div[data-type=web]").array() {
            try Task.checkCancellation()
            guard let anchor = try block.select("a[href^=http]").first() else { continue }
            let candidate = try block.select("div.title").first()?.text() ?? ""
            let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? try anchor.text() : candidate
            if let result = hit(title: title, snippet: try block.select("div.snippet").first()?.text() ?? "", rawURL: try anchor.attr("href")) { hits.append(result) }
            if hits.count >= min(5, max(1, limit)) { break }
        }
        return hits
    }
    public static func yahoo(_ html: String, limit: Int) throws -> [WebSearchHit] {
        let document = try SwiftSoup.parse(html); var hits: [WebSearchHit] = []
        for anchor in try document.select("a[href*=/RU=]").array() {
            try Task.checkCancellation()
            guard let heading = try anchor.select("h3.title").first() else { continue }
            let href = try anchor.attr("href")
            guard let range = href.range(of: "/RU="), let encoded = href[range.upperBound...].split(separator: "/").first,
                  let destination = String(encoded).removingPercentEncoding, !destination.contains("bing.com/aclick") else { continue }
            var snippet = ""; var parent = anchor.parent()
            for _ in 0..<4 {
                guard let candidate = parent else { break }
                if let found = try candidate.select("p[class*=fc-dustygray]").first(), try !found.text().isEmpty { snippet = try found.text(); break }
                parent = candidate.parent()
            }
            if let result = hit(title: try heading.text(), snippet: snippet, rawURL: destination) { hits.append(result) }
            if hits.count >= min(5, max(1, limit)) { break }
        }
        return hits
    }
    public static func context7(_ json: String, query: String, limit: Int) -> [WebSearchHit]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let results = object["results"] as? [Any] else { return nil }
        var hits: [WebSearchHit] = []
        for entry in results {
            guard let result = entry as? [String: Any], let title = result["title"] as? String, let id = result["id"] as? String, looksLikeMatch(query: query, title: title), id.hasPrefix("/"), !id.hasPrefix("//"),
                  let hit = hit(title: title, snippet: result["description"] as? String ?? "", rawURL: "https://context7.com" + id) else { continue }
            hits.append(hit); if hits.count >= min(5, max(1, limit)) { break }
        }
        return hits
    }
    static func looksLikeMatch(query: String, title: String) -> Bool {
        func words(_ value: String) -> [String] { value.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.+#").inverted).filter { !$0.isEmpty } }
        let asked = query.lowercased(); let lowered = title.lowercased()
        if Set(words(query).filter { $0.count >= 5 }).filter({ lowered.contains($0) }).count >= 2 { return true }
        let named = words(title)
        return !named.isEmpty && named.allSatisfy { $0.count >= 5 && asked.contains($0) }
    }
}
