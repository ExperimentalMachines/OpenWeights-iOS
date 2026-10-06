import Foundation

public enum HubRuntime: String, CaseIterable, Codable, Sendable {
    case gguf, executorch, mlx
    public var label: String { switch self { case .gguf: return "GGUF"; case .executorch: return "ExecuTorch"; case .mlx: return "MLX" } }
}
public enum HubSort: String, CaseIterable, Codable, Sendable {
    case trending = "trendingScore", downloads, likes, recent = "lastModified"
    public var label: String { switch self { case .trending: return "Trending"; case .downloads: return "Downloads"; case .likes: return "Likes"; case .recent: return "Recent" } }
}
public enum HubTask: String, CaseIterable, Codable, Sendable {
    case any = "", chat = "text-generation", vision = "image-text-to-text", audio = "audio-text-to-text", anyToAny = "any-to-any"
    public var label: String { switch self { case .any: return "Any task"; case .chat: return "Chat"; case .vision: return "Vision"; case .audio: return "Audio"; case .anyToAny: return "Any to any" } }
}
public enum HubParameterRange: String, CaseIterable, Codable, Sendable {
    case any, tiny, small, medium, large, huge
    public var label: String { switch self { case .any: return "Any size"; case .tiny: return "Up to 2B"; case .small: return "2B to 4B"; case .medium: return "4B to 8B"; case .large: return "8B to 16B"; case .huge: return "16B or more" } }
    var band: String? { switch self { case .any: return nil; case .tiny: return "max:2B"; case .small: return "min:2B,max:4B"; case .medium: return "min:4B,max:8B"; case .large: return "min:8B,max:16B"; case .huge: return "min:16B" } }
    func contains(_ value: Double) -> Bool {
        switch self {
        case .any: return true
        case .tiny: return value <= 2
        case .small: return value >= 2 && value <= 4
        case .medium: return value >= 4 && value <= 8
        case .large: return value >= 8 && value <= 16
        case .huge: return value >= 16
        }
    }
}
public struct HubQuery: Equatable, Sendable {
    public var shortlistOnly = false
    public var text = ""
    public var runtimes: Set<HubRuntime> = Set(HubRuntime.allCases)
    public var sort = HubSort.trending
    public var task = HubTask.any
    public var author = ""
    public var parameters = HubParameterRange.any
    public var maximumParametersBillions: Int? = nil
    public var hideGated = false
    public var organisationsOnly = false
    public init() {}
    public var activeCount: Int {
        [task != .any, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         parameters != .any || maximumParametersBillions != nil, hideGated, organisationsOnly].filter { $0 }.count
    }
    public var effectiveRuntimes: Set<HubRuntime> { runtimes.isEmpty ? Set(HubRuntime.allCases) : runtimes }
}
public struct HubModel: Decodable, Identifiable, Sendable {
    public var id: String
    public var downloads: Int?
    public var likes: Int?
    public var tags: [String]?
    public var pipelineTag: String?
    public var gated: Bool
    public var runtimes: Set<HubRuntime> = []
    public var experimental = false
    public var lastModified: String?
    public var libraryName: String?
    public var owner: String { String(id.split(separator: "/", maxSplits: 1).first ?? "") }
    enum CodingKeys: String, CodingKey { case id, downloads, likes, tags, pipelineTag = "pipeline_tag", gated, lastModified, libraryName = "library_name" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        experimental = HubShortlist.experimental.contains(id)
        downloads = try values.decodeIfPresent(Int.self, forKey: .downloads)
        likes = try values.decodeIfPresent(Int.self, forKey: .likes)
        tags = try values.decodeIfPresent([String].self, forKey: .tags)
        pipelineTag = try values.decodeIfPresent(String.self, forKey: .pipelineTag)
        lastModified = try values.decodeIfPresent(String.self, forKey: .lastModified)
        libraryName = try values.decodeIfPresent(String.self, forKey: .libraryName)
        if let value = try? values.decode(Bool.self, forKey: .gated) { gated = value }
        else { gated = (try? values.decode(String.self, forKey: .gated)).map { $0 != "false" } ?? false }
    }
    public var namedParametersBillions: Double? {
        let expression = try! NSRegularExpression(pattern: "(?i)(?:^|[-_])([0-9]+(?:\\.[0-9]+)?)([bm])(?:[-_]|$)")
        let name = String(id.split(separator: "/").last ?? "") as NSString
        guard let match = expression.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)),
              let count = Double(name.substring(with: match.range(at: 1))) else { return nil }
        return name.substring(with: match.range(at: 2)).lowercased() == "m" ? count / 1000 : count
    }
}
public struct HubCursor: Equatable, Sendable {
    public let runtime: HubRuntime
    public let value: String
    public init(runtime: HubRuntime, value: String) { self.runtime = runtime; self.value = value }
}
public struct HubSearchPage: Sendable {
    public var models: [HubModel]
    public var cursors: [HubCursor]
    public var unavailableRuntimes: [HubRuntime]
    public var unavailableRepositories: [String] = []
    public init(models: [HubModel], cursors: [HubCursor] = [], unavailableRuntimes: [HubRuntime] = []) { self.models = models; self.cursors = cursors; self.unavailableRuntimes = unavailableRuntimes }
}
public struct HubAPIResponse: Sendable {
    public let status: Int
    public let data: Data
    public let link: String?
    public init(status: Int, data: Data, link: String? = nil) { self.status = status; self.data = data; self.link = link }
}
public protocol HubDiscoveryTransport: Sendable {
    func get(_ url: URL) async throws -> HubAPIResponse
}

public actor HubDiscoveryClient {
    private let transport: any HubDiscoveryTransport
    private var organisations: [String: Bool] = [:]
    public init(transport: any HubDiscoveryTransport) { self.transport = transport }
    public static func validRepositoryID(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 128 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) } }
    }
    public static func searchURL(query: HubQuery, runtime: HubRuntime, cursor: String? = nil, limit: Int = 30) throws -> URL {
        guard query.text.utf8.count <= 512, query.author.utf8.count <= 128,
              cursor?.utf8.count ?? 0 <= 8192,
              query.maximumParametersBillions.map({ (1...1024).contains($0) }) ?? true else { throw ModelError.unsupported("Keep the model search and size limit within their supported bounds.") }
        var parts = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [URLQueryItem(name: runtime == .gguf ? "apps" : "filter", value: runtime == .gguf ? "llama.cpp" : runtime == .executorch ? "executorch" : "mlx"),
            URLQueryItem(name: "limit", value: String(min(100, max(1, limit)))),
            URLQueryItem(name: "sort", value: query.sort.rawValue), URLQueryItem(name: "direction", value: "-1")]
        func add(_ name: String, _ value: String?) { if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) } }
        add("search", query.text.trimmingCharacters(in: .whitespacesAndNewlines))
        add("author", query.author.trimmingCharacters(in: .whitespacesAndNewlines))
        add("pipeline_tag", query.task.rawValue)
        // Compiled exports have no Hub parameter metadata. Do not filter them out server-side.
        if runtime != .executorch { add("num_parameters", query.maximumParametersBillions.map { "max:\($0)B" } ?? query.parameters.band) }
        if query.hideGated { add("gated", "false") }
        add("cursor", cursor)
        parts.queryItems = items
        return parts.url!
    }
    public static func nextCursor(link: String?, runtime: HubRuntime) throws -> HubCursor? {
        guard let link else { return nil }
        guard link.utf8.count <= 16_384 else { throw ModelError.unsupported("The Hub pagination header is oversized.") }
        let expression = try! NSRegularExpression(pattern: "<([^>]+)>\\s*;\\s*rel=\"?next\"?", options: [.caseInsensitive])
        let source = link as NSString
        guard let match = expression.firstMatch(in: link, range: NSRange(location: 0, length: source.length)) else { return nil }
        guard let parts = URLComponents(string: source.substring(with: match.range(at: 1))),
              parts.scheme == "https", parts.host == "huggingface.co", parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.percentEncodedPath == "/api/models", parts.fragment == nil,
              let items = parts.queryItems else { throw ModelError.unsupported("The Hub returned an unsafe pagination address.") }
        let values = items.filter { $0.name == "cursor" }
        guard values.count == 1, let value = values[0].value, !value.isEmpty, value.utf8.count <= 8192 else { throw ModelError.unsupported("The Hub pagination cursor is invalid.") }
        return HubCursor(runtime: runtime, value: value)
    }
    public static func merged(_ models: [HubModel]) -> [HubModel] {
        var order: [String] = [], entries: [String: HubModel] = [:]
        for model in models {
            if var existing = entries[model.id] { existing.runtimes.formUnion(model.runtimes); entries[model.id] = existing }
            else { order.append(model.id); entries[model.id] = model }
        }
        return order.compactMap { entries[$0] }
    }
    public func search(_ query: HubQuery, cursors: [HubCursor]? = nil, limit: Int = 30) async throws -> HubSearchPage {
        let wanted = HubRuntime.allCases.filter { query.effectiveRuntimes.contains($0) }
        var models: [HubModel] = [], next: [HubCursor] = [], failures: [HubRuntime] = []
        var succeeded = 0
        for runtime in wanted {
            if let cursors, !cursors.contains(where: { $0.runtime == runtime }) { continue }
            try Task.checkCancellation()
            do {
                var cursor = cursors?.first { $0.runtime == runtime }?.value
                var visited = Set<String>()
                if let cursor { visited.insert(cursor) }
                // Organisation and compiled-size filters can empty a server page.
                // Scan a bounded number, then return a continuation for explicit loading.
                for scan in 0..<4 {
                    let response = try await transport.get(Self.searchURL(query: query, runtime: runtime, cursor: cursor, limit: limit))
                    try Task.checkCancellation()
                    guard response.status == 200, response.data.count <= 2_097_152 else { throw ModelError.unsupported("The Hub model search failed or exceeded its response limit.") }
                    var page = try JSONDecoder().decode([HubModel].self, from: response.data)
                    guard page.count <= 100 else { throw ModelError.unsupported("The Hub returned too many repositories in one page.") }
                    page = page.filter { Self.validRepositoryID($0.id) && (!query.hideGated || !$0.gated) }
                    // Hub size filtering may leave repositories without parameter metadata.
                    // Apply known name hints across formats and disclose unknown sizes.
                    if query.parameters != .any || query.maximumParametersBillions != nil {
                        page = page.filter { model in
                            guard let value = model.namedParametersBillions else { return true }
                            return query.maximumParametersBillions.map { value <= Double($0) } ?? query.parameters.contains(value)
                        }
                    }
                    for index in page.indices { page[index].runtimes = [runtime] }
                    if query.organisationsOnly {
                        var filtered: [HubModel] = []
                        for model in page where try await isOrganisation(model.owner) { filtered.append(model) }
                        page = filtered
                    }
                    let continuation = try Self.nextCursor(link: response.link, runtime: runtime)
                    let fresh = continuation.flatMap { visited.insert($0.value).inserted ? $0 : nil }
                    if page.isEmpty, let fresh, scan < 3, query.organisationsOnly || query.parameters != .any || query.maximumParametersBillions != nil {
                        cursor = fresh.value
                        continue
                    }
                    if let fresh { next.append(fresh) }
                    models += page; succeeded += 1
                    break
                }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); failures.append(runtime) }
        }
        guard succeeded > 0 else { throw ModelError.unsupported("Hugging Face could not load the selected searches. Check connectivity and access, then retry.") }
        return HubSearchPage(models: Self.merged(models), cursors: next, unavailableRuntimes: failures)
    }
    private func isOrganisation(_ owner: String) async throws -> Bool {
        if let known = organisations[owner] { return known }
        let url = URL(string: "https://huggingface.co/api/organizations")!.appendingPathComponent(owner).appendingPathComponent("avatar")
        let response = try await transport.get(url)
        try Task.checkCancellation()
        if response.status == 404 { cacheOrganisation(owner, value: false); return false }
        guard response.status == 200, response.data.count <= 16_384,
              (try JSONSerialization.jsonObject(with: response.data)) is [String: Any] else { throw ModelError.unsupported("Publisher account information is unavailable. Retry the organisation filter.") }
        cacheOrganisation(owner, value: true)
        return true
    }
    private func cacheOrganisation(_ owner: String, value: Bool) {
        if organisations.count >= 512 { organisations.removeAll(keepingCapacity: true) }
        organisations[owner] = value
    }
}

extension HubDiscoveryClient {
    public func shortlist(_ query: HubQuery) async throws -> HubSearchPage {
        // Fetch exact IDs so typing and filters cannot introduce uncurated rows.
        _ = try Self.searchURL(query: query, runtime: .gguf)
        let ids = HubShortlist.recommended + HubShortlist.experimental
        let replies = try await withThrowingTaskGroup(of: (Int, HubModel?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { [transport] in
                    do {
                        let url = URL(string: "https://huggingface.co/api/models")!.appendingPathComponent(id)
                        let response = try await transport.get(url)
                        try Task.checkCancellation()
                        guard response.status == 200, response.data.count <= 2_097_152 else { return (index, nil) }
                        var model = try JSONDecoder().decode(HubModel.self, from: response.data)
                        guard model.id == id else { return (index, nil) }
                        let tags = Set((model.tags ?? []).map { $0.lowercased() })
                        model.runtimes = Set(HubRuntime.allCases.filter { runtime in
                            switch runtime {
                            case .gguf: return tags.contains("gguf") || model.libraryName == "gguf"
                            case .executorch: return tags.contains("executorch") || model.libraryName == "executorch"
                            case .mlx: return tags.contains("mlx") || model.libraryName == "mlx"
                            }
                        })
                        model.experimental = HubShortlist.experimental.contains(id)
                        return (index, model)
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation(); return (index, nil) }
                }
            }
            var result: [(Int, HubModel?)] = []
            for try await reply in group { result.append(reply) }
            return result.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        guard replies.contains(where: { $0.1 != nil }) else {
            throw ModelError.unsupported("Hugging Face could not load the shortlist. Check connectivity and access, then retry.")
        }
        var models: [HubModel] = []
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = query.author.trimmingCharacters(in: .whitespacesAndNewlines)
        for (_, candidate) in replies {
            guard var model = candidate else { continue }
            model.runtimes.formIntersection(query.effectiveRuntimes)
            guard !model.runtimes.isEmpty, text.isEmpty || model.id.localizedCaseInsensitiveContains(text),
                  author.isEmpty || model.owner.caseInsensitiveCompare(author) == .orderedSame,
                  query.task == .any || model.pipelineTag == query.task.rawValue,
                  !query.hideGated || !model.gated else { continue }
            if let size = model.namedParametersBillions {
                guard query.maximumParametersBillions.map({ size <= Double($0) }) ?? query.parameters.contains(size) else { continue }
            }
            if query.organisationsOnly, try await !isOrganisation(model.owner) { continue }
            models.append(model)
        }
        // Curated order is the trending view. Experimental rows remain last.
        models.sort { lhs, rhs in
            if lhs.experimental != rhs.experimental { return !lhs.experimental }
            switch query.sort {
            case .trending: return ids.firstIndex(of: lhs.id)! < ids.firstIndex(of: rhs.id)!
            case .downloads: if lhs.downloads != rhs.downloads { return (lhs.downloads ?? 0) > (rhs.downloads ?? 0) }
            case .likes: if lhs.likes != rhs.likes { return (lhs.likes ?? 0) > (rhs.likes ?? 0) }
            case .recent: if lhs.lastModified != rhs.lastModified { return (lhs.lastModified ?? "") > (rhs.lastModified ?? "") }
            }
            return lhs.id < rhs.id
        }
        var page = HubSearchPage(models: models)
        page.unavailableRepositories = replies.compactMap { $0.1 == nil ? ids[$0.0] : nil }
        return page
    }
}
