import Foundation

public enum MediaResultKind: String, Codable, Sendable { case images, videos }
public struct MediaSearchHit: Codable, Equatable, Sendable {
    public let title: String
    public let thumbnailURL: String
    public let targetURL: String
    public let sourceURL: String
    public let kind: MediaResultKind
    public let width: Int
    public let height: Int
    public var previewKey: String?
    public init(title: String, thumbnailURL: String, targetURL: String, sourceURL: String, kind: MediaResultKind, width: Int = 0, height: Int = 0, previewKey: String? = nil) {
        self.title = title; self.thumbnailURL = thumbnailURL; self.targetURL = targetURL; self.sourceURL = sourceURL
        self.kind = kind; self.width = width; self.height = height; self.previewKey = previewKey
    }
}
public struct MediaSearchEvidence: Codable, Equatable, Sendable {
    public let query: String
    public let kind: MediaResultKind
    public let hits: [MediaSearchHit]
    public init(query: String, kind: MediaResultKind, hits: [MediaSearchHit]) { self.query = query; self.kind = kind; self.hits = hits }
}
public struct DuckDuckGoMediaProvider: Sendable {
    private let transport: any SearchHTTPTransport
    public init(transport: any SearchHTTPTransport = SearchHTTPClient()) { self.transport = transport }
    public func search(query: String, kind: MediaResultKind) async throws -> [MediaSearchHit]? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf16.count <= 120 else { throw PublicWebError.refused("Give a short picture or clip query, at most 120 characters.") }
        let headers = ["user-agent": "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36", "referer": "https://duckduckgo.com/"]
        let home = try SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/?" + SearchHTTPRequest.form([("q", query)]), headers: headers)
        guard let page = try await read(home), let token = Self.token(in: page) else { return nil }
        let parameters = SearchHTTPRequest.form([("l", "us-en"), ("o", "json"), ("q", query), ("vqd", token), ("p", "-1")])
        let endpoint = kind == .images ? "i.js" : "v.js"
        let request = try SearchHTTPRequest(engine: .duckduckgo, url: "https://duckduckgo.com/" + endpoint + "?" + parameters, headers: headers)
        guard let body = try await read(request) else { return nil }
        try Task.checkCancellation()
        return Self.hits(in: body, kind: kind)
    }
    private func read(_ request: SearchHTTPRequest) async throws -> String? {
        try Task.checkCancellation()
        do {
            let response = try await transport.send(request, timeout: 20)
            try Task.checkCancellation()
            guard response.status == 200, response.body.count <= 1_048_576,
                  response.headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else { return nil }
            return String(data: response.body, encoding: .utf8)
        } catch { if error is CancellationError || Task.isCancelled { throw CancellationError() }; return nil }
    }
    static func token(in page: String) -> String? {
        guard page.utf8.count <= 1_048_576, let expression = try? NSRegularExpression(pattern: "vqd=[\"']?([A-Za-z0-9_-]{1,256})(?:[\"']|[^A-Za-z0-9_-]|$)"),
              let match = expression.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)), let range = Range(match.range(at: 1), in: page) else { return nil }
        return String(page[range])
    }
    static func hits(in body: String, kind: MediaResultKind) -> [MediaSearchHit]? {
        guard body.utf8.count <= 1_048_576, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any], let rows = object["results"] as? [Any] else { return nil }
        func address(_ value: Any?) -> String? {
            guard let text = value as? String, text.utf8.count <= 8192, let address = try? PublicWebAddress(text) else { return nil }
            return address.url.absoluteString
        }
        var results: [MediaSearchHit] = []; var seen: Set<String> = []
        for value in rows {
            guard let row = value as? [String: Any] else { continue }
            let thumbnail = kind == .images ? address(row["thumbnail"]) ?? address(row["image"]) : address((row["images"] as? [String: Any])?["medium"])
            guard let thumbnail, seen.insert(thumbnail).inserted else { continue }
            let target = address(row[kind == .images ? "image" : "content"]) ?? thumbnail
            let source = kind == .images ? address(row["url"]) ?? thumbnail : target
            let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            func dimension(_ name: String) -> Int { min(100_000, max(0, (row[name] as? NSNumber)?.intValue ?? Int(row[name] as? String ?? "") ?? 0)) }
            results.append(MediaSearchHit(title: title.isEmpty ? "Untitled" : WebPageSearch.prefix(title, maximum: 256), thumbnailURL: thumbnail, targetURL: target, sourceURL: source, kind: kind, width: dimension("width"), height: dimension("height")))
            if results.count == 8 { break }
        }
        // An undocumented scraper with no drawable rows cannot establish that the web has no pictures.
        return results.isEmpty ? nil : results
    }
}
