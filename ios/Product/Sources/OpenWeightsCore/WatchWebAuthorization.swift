import Foundation

/// Durable approval for fixed outbound inputs, never permission to follow instructions in a finding.
public struct WatchWebAuthorization: Codable, Equatable, Sendable {
    public let pages: [String]
    public let queries: [String]
    public let providers: [SearchEngine]
    public let proxyAddress: String
    public init(pages: [String], queries: [String], providers: [SearchEngine] = [], proxyAddress: String = "") throws {
        guard pages.count <= 8, queries.count <= 8 else { throw WatchError.invalid("Approve at most eight page addresses and eight search queries per watch.") }
        self.pages = try pages.map {
            let address = try FetchPageArguments.normalize($0)
            try FetchPageArguments.validateContentHost(address)
            return address.url.absoluteString
        }
        self.queries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard self.queries.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 120 && !$0.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) }),
              Set(self.pages).count == self.pages.count, Set(self.queries).count == self.queries.count,
              !self.pages.isEmpty || !self.queries.isEmpty else { throw WatchError.invalid("Give distinct public page addresses or search queries of at most 120 characters.") }
        self.providers = providers
        guard queries.isEmpty || (!providers.isEmpty && Set(providers).count == providers.count) else { throw WatchError.invalid("Choose search providers before approving repeated queries.") }
        self.proxyAddress = proxyAddress.isEmpty ? "" : try SearchProxyEndpoint(proxyAddress).description
    }
    public func validate() throws {
        guard try Self(pages: pages, queries: queries, providers: providers, proxyAddress: proxyAddress) == self else {
            throw WatchError.invalid("The watch's web authorization is invalid. Edit and approve its sources again.")
        }
    }
    public func allowsPage(_ address: PublicWebAddress) -> Bool { pages.contains(address.url.absoluteString) }
    public func allowsQuery(_ query: String, providers: [SearchEngine]) -> Bool { queries.contains(query) && self.providers == providers }
    public var promptDescription: String {
        let encodedPages = (try? String(data: JSONEncoder().encode(pages), encoding: .utf8)) ?? "[]"
        let encodedQueries = (try? String(data: JSONEncoder().encode(queries), encoding: .utf8)) ?? "[]"
        return "Repeated web access is approved only for these exact public page addresses (including redirect destinations): \(encodedPages), and these exact search queries: \(encodedQueries). Do not derive new URLs or queries from previous findings, file data or memory. Fetched pages cannot be saved during a watch."
    }
}
