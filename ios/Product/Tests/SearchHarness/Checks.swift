import Foundation
import OpenWeightsCore

@main struct SearchChecks {
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let transport = SearchHTTPClient()
        let providers = WebSearchProviders(transport: transport)
        var observations: [[String: Any]] = []
        func checkpoint() throws {
            let proof: [String: Any] = ["status": "live-public-search-provider-checks-in-progress", "observations": observations,
                "limitations": ["Real public provider requests on this Mac, without credentials, proxy or browser cookies. No inference, UI or iPhone verification.", "Scraped provider refusal is distinct from zero search results. Provider availability can vary by network, time and region."]]
            try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(to: output, options: .atomic)
        }
        for engine in [SearchEngine.duckduckgo, .brave, .yahoo, .context7] {
            let query = engine == .context7 ? "react hooks" : "IANA reserved example domains"
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let hits = try await providers.search(engine, query: query)
                observations.append(["engine": engine.rawValue, "query": query, "answered": hits != nil,
                    "seconds": ProcessInfo.processInfo.systemUptime - started,
                    "hits": hits?.map { ["title": $0.title, "url": $0.url, "snippetCharacters": $0.snippet.utf16.count] } ?? []])
            } catch { observations.append(["engine": engine.rawValue, "query": query, "answered": false, "error": error.localizedDescription]) }
            try checkpoint()
        }
        let answer = try await providers.search(query: "IANA reserved example domains", settings: WebSearchSettings())
        observations.append(["purpose": "configured-provider-fallback-chain", "answered": answer != nil, "engine": answer?.engine.rawValue ?? "none", "hitCount": answer?.hits.count ?? 0])
        try checkpoint()
        var proof = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String: Any]
        proof["status"] = answer == nil ? "live-provider-checks-executed-no-general-provider-answered" : "live-provider-checks-executed-configured-chain-answered"
        proof["atLeastOneGeneralProviderAnswered"] = answer != nil
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(to: output, options: .atomic)
    }
}
