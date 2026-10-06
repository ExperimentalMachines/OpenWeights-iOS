import Foundation
import Combine
import OpenWeightsCore

@MainActor final class WebController: ObservableObject {
    @Published var mediaEnabled: Bool { didSet { defaults.set(mediaEnabled, forKey: "tools.web.show_pictures.enabled"); if !mediaEnabled && activeName == "show_pictures" { cancel() } } }
    let mediaCache: MediaPreviewCache
    @Published var fetchEnabled: Bool { didSet { defaults.set(fetchEnabled, forKey: "tools.web.fetch_url.enabled") } }
    @Published var searchEnabled: Bool { didSet { defaults.set(searchEnabled, forKey: "tools.web.web_search.enabled") } }
    @Published private(set) var searchEngines: Set<SearchEngine> { didSet { defaults.set(searchEngines.map(\.rawValue).sorted(), forKey: "tools.web.engines") } }
    @Published var documentation: Bool { didSet { defaults.set(documentation, forKey: "tools.web.documentation") } }
    @Published var resultCount: Int { didSet { let bounded = min(5, max(1, resultCount)); if resultCount != bounded { resultCount = bounded }; defaults.set(bounded, forKey: "tools.web.resultCount") } }
    private let defaults: UserDefaults
    private let tools: WebTools
    private let searchRoute: SearchProxyTransport
    private let proxyCredentials: any SearchProxyCredentialStoring
    @Published private(set) var proxyAddress: String
    @Published private(set) var proxyHasCredentials: Bool
    private var active: Task<ToolResult, Never>?
    private var activeName: String?
    init(defaults: UserDefaults = .standard, client: PublicWebClient = PublicWebClient(), searchTransport: (any SearchHTTPTransport)? = nil, mediaCache: MediaPreviewCache = MediaPreviewCache(), proxyCredentials: any SearchProxyCredentialStoring = AppleSearchProxyCredentialStore(), searchRoute: SearchProxyTransport? = nil) {
        self.defaults = defaults; self.mediaCache = mediaCache; self.proxyCredentials = proxyCredentials
        let route = searchRoute ?? searchTransport.map { transport in SearchProxyTransport(factory: { _ in transport }) } ?? SearchProxyTransport()
        self.searchRoute = route; tools = WebTools(client: client, searchTransport: route, previews: mediaCache)
        proxyAddress = defaults.string(forKey: "tools.web.proxy.address") ?? ""
        proxyHasCredentials = defaults.bool(forKey: "tools.web.proxy.authenticated")
        mediaEnabled = defaults.object(forKey: "tools.web.show_pictures.enabled") == nil || defaults.bool(forKey: "tools.web.show_pictures.enabled")
        searchEnabled = defaults.object(forKey: "tools.web.web_search.enabled") == nil || defaults.bool(forKey: "tools.web.web_search.enabled")
        let restoredEngines = Set((defaults.stringArray(forKey: "tools.web.engines") ?? ["duckduckgo", "brave", "yahoo"]).compactMap(SearchEngine.init(rawValue:))).intersection([SearchEngine.duckduckgo, .brave, .yahoo])
        searchEngines = restoredEngines.isEmpty ? [.duckduckgo] : restoredEngines
        documentation = defaults.bool(forKey: "tools.web.documentation")
        resultCount = min(5, max(1, defaults.object(forKey: "tools.web.resultCount") == nil ? 3 : defaults.integer(forKey: "tools.web.resultCount")))
        fetchEnabled = defaults.bool(forKey: "tools.web.fetch_url.enabled")
    }
    var definitions: [AgentToolDefinition] {
        (searchEnabled ? [WebToolDefinitions.search] : []) + (fetchEnabled ? [WebToolDefinitions.fetch] : []) + (mediaEnabled ? [WebToolDefinitions.pictures] : [])
    }
    func setEngine(_ engine: SearchEngine, enabled: Bool) {
        guard [.duckduckgo, .brave, .yahoo].contains(engine) else { return }
        if enabled { searchEngines.insert(engine) }
        else if searchEngines.count > 1 { searchEngines.remove(engine) }
    }
    var providerLabels: String {
        var settings = WebSearchSettings(); settings.engines = searchEngines; settings.documentation = documentation
        return settings.providers.map(\.label).joined(separator: ", ")
    }
    var proxyDisclosure: String {
        proxyAddress.isEmpty ? "Search connects directly." : "Search provider requests use your selected proxy, \((try? SearchProxyEndpoint(proxyAddress))?.description ?? "invalid address"). Page fetching, thumbnails and model downloads keep their own connections. A proxy failure stops search without switching to a direct connection."
    }
    func saveProxy(address: String, credentials: SearchProxyCredentials? = nil, keepSavedCredentials: Bool = false) throws {
        guard active == nil else { throw PublicWebError.refused("Wait for the running web request before changing its proxy.") }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = text.isEmpty ? nil : try SearchProxyEndpoint(text)
        var saved = credentials
        if keepSavedCredentials {
            guard let endpoint, endpoint.description == proxyAddress, proxyHasCredentials, let prior = try proxyCredentials.read(for: endpoint) else {
                throw PublicWebError.refused("Enter fresh credentials when changing the proxy address.")
            }
            saved = prior
        }
        guard endpoint != nil || saved == nil else { throw PublicWebError.refused("Enter a proxy address before saving credentials.") }
        try proxyCredentials.save(saved, for: endpoint)
        proxyAddress = endpoint?.description ?? ""; proxyHasCredentials = saved != nil
        defaults.set(proxyAddress, forKey: "tools.web.proxy.address"); defaults.set(proxyHasCredentials, forKey: "tools.web.proxy.authenticated")
    }
    private func configuredProxy() throws -> SearchProxy? {
        guard !proxyAddress.isEmpty else { return nil }
        let endpoint = try SearchProxyEndpoint(proxyAddress)
        let credentials = proxyHasCredentials ? try proxyCredentials.read(for: endpoint) : nil
        guard !proxyHasCredentials || credentials != nil else { throw PublicWebError.refused("The saved proxy credential is unavailable. Save or remove it under Tools. Search will not switch to a direct connection.") }
        return SearchProxy(endpoint: endpoint, credentials: credentials)
    }
    func watchAuthorization(pages: [String], queries: [String]) throws -> WatchWebAuthorization? {
        if pages.isEmpty && queries.isEmpty { return nil }
        var search = WebSearchSettings(); search.engines = searchEngines; search.documentation = documentation
        return try WatchWebAuthorization(pages: pages, queries: queries, providers: queries.isEmpty ? [] : search.providers, proxyAddress: queries.isEmpty ? "" : proxyAddress)
    }
    func beginTurn(carriesUntrustedText: Bool, carriesPrivateData: Bool = false) async { await tools.beginTurn(carriesUntrustedText: carriesUntrustedText, carriesPrivateData: carriesPrivateData) }
    func notePrivateRead() async { await tools.notePrivateRead() }
    func noteUntrustedRead() async { await tools.noteUntrustedRead() }
    func requiresApproval(_ call: AgentToolCall, mode: AgentMode) async -> Bool { await tools.requiresApproval(call, mode: mode) }
    func cancel() { active?.cancel() }
    func execute(_ call: AgentToolCall, mode: AgentMode, approval: ApprovedToolCall?, workspace: Workspace?, unattended: Bool = false, watchAuthorization: WatchWebAuthorization? = nil, research: Bool = false) async -> ToolResult {
        guard active == nil else { return ToolResult(text: "A web request is already running.", rejected: true) }
        var settings = WebToolSettings(); settings.fetchEnabled = fetchEnabled; settings.mediaEnabled = mediaEnabled; settings.mode = mode
        settings.research = research
        settings.search.enabled = searchEnabled; settings.search.engines = searchEngines
        settings.search.documentation = documentation; settings.search.resultCount = resultCount
        let task = Task { [self] in
            do {
                if unattended, let watchAuthorization, call.name == "web_search" {
                    guard watchAuthorization.proxyAddress == proxyAddress else { return ToolResult(text: "The watch's search proxy changed. Edit and approve its sources again.", rejected: true) }
                }
                if ["web_search", "show_pictures"].contains(call.name) { await searchRoute.configure(try configuredProxy()) }
                try Task.checkCancellation()
                return await tools.execute(call, settings: settings, approval: approval, workspace: workspace, unattended: unattended, watchAuthorization: watchAuthorization)
            } catch { return ToolResult(text: error.localizedDescription, rejected: true) }
        }
        active = task; activeName = call.name
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        active = nil; activeName = nil
        return result
    }
}
