import SwiftUI
import WebKit
import Network
import SafariServices
import OpenWeightsCore

@MainActor final class CanvasLocalServer {
    let session: CanvasHTTPSession
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private(set) var port: UInt16?
    private var failure: Error?
    private(set) var acceptedConnectionCount = 0
    private let observeRequest: ((String) -> Void)?
    init(canvas: CanvasDescriptor, workspace: Workspace, bundle: Bundle = .main, observeRequest: ((String) -> Void)? = nil, browserFrame: URL? = nil) throws {
        self.observeRequest = observeRequest
        var assets: [String: Data] = [:]
        for name in CanvasHTTPSession.assetNames {
            guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Canvas") else { throw WorkspaceError.operation("The bundled preview viewer is missing.") }
            assets[name] = try Data(contentsOf: url)
        }
        session = try CanvasHTTPSession(canvas: canvas, workspace: workspace, assets: assets, browserFrame: browserFrame)
    }
    func start() async throws -> URL {
        if let port { return session.url(port: port) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let candidate = try NWListener(using: parameters)
        listener = candidate
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            Task { @MainActor in
                guard let self, self.listener === candidate else { return }
                switch state { case .ready: self.port = candidate?.port?.rawValue; case .failed(let error): self.failure = error; default: break }
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in Task { @MainActor in
            guard let self else { connection.cancel(); return }; self.accept(connection)
        } }
        candidate.start(queue: .main)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        do {
            while port == nil {
                if let failure { throw failure }
                guard listener === candidate, ProcessInfo.processInfo.systemUptime < deadline else { throw WorkspaceError.interrupted }
                try await Task.sleep(for: .milliseconds(20))
            }
            return session.url(port: port!)
        } catch { stop(); throw error }
    }
    func stop() {
        listener?.cancel(); listener = nil; port = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        Task { await session.revoke() }
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 4 else { connection.cancel(); return }
        acceptedConnectionCount += 1
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close(id)
        }
        receive(id, buffer: Data())
    }
    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                let received = buffer + (data ?? Data())
                if received.count > 16384 || error != nil { self.close(id); return }
                if received.range(of: Data("\r\n\r\n".utf8)) != nil, let port = self.port {
                    if let line = String(data: received, encoding: .utf8)?.components(separatedBy: "\r\n").first,
                       let target = line.split(separator: " ").dropFirst().first { self.observeRequest?(String(target)) }
                    let response = await self.session.answer(received, port: port)
                    guard self.connections[id] != nil else { return }
                    connection.send(content: response.wire, completion: .contentProcessed { _ in Task { @MainActor in self.close(id) } })
                } else if complete { self.close(id) }
                else { self.receive(id, buffer: received) }
            }
        }
    }
    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }
}

@MainActor final class CanvasBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web = WKWebView(frame: UIScreen.main.bounds, configuration: CanvasBrowser.configuration())
    @Published private(set) var error: String?
    private(set) var report = CanvasPageReport()
    private var errors: [String] = [], missing: [String] = [], blocked: [String] = []
    private var port: UInt16 = 0
    private(set) var loaded = false
    private var closed = false
    private var rules: WKContentRuleList?
    override init() {
        super.init(); web.navigationDelegate = self
        web.configuration.userContentController.add(self, name: "owCanvasReport")
        web.configuration.userContentController.addUserScript(WKUserScript(source: Self.observer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web.allowsBackForwardNavigationGestures = true
    }
    private static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsAirPlayForMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        return config
    }
    func load(_ url: URL) async throws {
        guard let port = url.port, (1...65535).contains(port), !closed else { throw WorkspaceError.invalidPath }
        self.port = UInt16(port); loaded = false; error = nil
        // Navigation delegates cover links, but not every subresource or socket.
        // The content rule is installed before the first page can execute.
        let json = try JSONSerialization.data(withJSONObject: [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^http://127\\.0\\.0\\.1:\(port)/"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^blob:"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^about:blank$"], "action": ["type": "ignore-previous-rules"]]
        ])
        let identifier = "openweights-canvas-\(port)"
        let compiled: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: String(data: json, encoding: .utf8)!) { rules, error in
                if let rules { continuation.resume(returning: rules) }
                else { continuation.resume(throwing: error ?? WorkspaceError.operation("Preview network protection could not be installed.")) }
            }
        }
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        if let rules { web.configuration.userContentController.remove(rules) }
        rules = compiled; web.configuration.userContentController.add(compiled)
        // Compilation caches otherwise accumulate a file per ephemeral port.
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    func reload() {
        guard !closed else { return }
        // The Markdown viewers poll and preserve the current page or slide.
        web.reload()
    }
    func close() {
        closed = true; web.stopLoading(); web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "owCanvasReport")
        web.configuration.userContentController.removeAllUserScripts()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, CanvasHTTPSession.permitsNavigation(url, port: port), !closed else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "The preview process stopped. Reopen the preview to try again." }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, let body = message.body as? [String: String], let kind = body["kind"], let raw = body["text"] else { return }
        let text = String(raw.prefix(200))
        switch kind {
        case "error": if errors.count < 20 && !errors.contains(text) { errors.append(text) }
        case "missing": if missing.count < 20 && !missing.contains(text) { missing.append(text) }
        case "blocked": if blocked.count < 20 && !blocked.contains(text) { blocked.append(text) }
        default: return
        }
        report = CanvasPageReport(errors: errors, missing: missing, blocked: blocked)
    }
    private static let observer = #"""
    (() => {
      const post = (kind, text) => { try { window.webkit.messageHandlers.owCanvasReport.postMessage({kind, text: String(text).slice(0,200)}); } catch (_) {} };
      addEventListener('error', e => {
        if (e.target !== window) {
          const raw = e.target.src || e.target.href || '';
          try { const url = new URL(raw, location.href); if (url.origin === location.origin) post('missing', url.pathname.split('/').pop()); else post('blocked', url.host); } catch (_) {}
        } else post('error', e.message + ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')');
      }, true);
      addEventListener('unhandledrejection', e => post('error', e.reason));
      addEventListener('securitypolicyviolation', e => { try { const url = new URL(e.blockedURI); if (url.origin !== location.origin) post('blocked', url.host); } catch (_) {} });
      const previous = console.error.bind(console);
      console.error = (...args) => { post('error', args.join(' ')); previous(...args); };
    })();
    """#
}

@MainActor enum CanvasPageChecker {
    static func check(_ canvas: CanvasDescriptor, workspace: Workspace) async -> CanvasPageReport? {
        let browser = CanvasBrowser()
        var server: CanvasLocalServer?
        defer { browser.close(); server?.stop() }
        do {
            let candidate = try CanvasLocalServer(canvas: canvas, workspace: workspace); server = candidate
            let url = try await candidate.start(); try await browser.load(url)
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while !browser.loaded {
                guard browser.error == nil, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(1200))
            return browser.report
        } catch { return nil }
    }
}

private struct CanvasWebView: UIViewRepresentable {
    let browser: CanvasBrowser
    func makeUIView(context: Context) -> WKWebView { browser.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct CanvasScreen: View {
    @ObservedObject var files: WorkspaceController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var browser = CanvasBrowser()
    @State private var server: CanvasLocalServer?
    @State private var url: URL?
    @State private var failure: String?
    @State private var safari: CanvasSafariPreview?
    @State private var openingSafari = false
    @State private var safariTask: Task<Void, Never>?
    var body: some View {
        Group {
            if let failure = failure ?? browser.error { ContentUnavailableView("Preview unavailable", systemImage: "doc.badge.ellipsis", description: Text(failure)) }
            else { CanvasWebView(browser: browser) }
        }
        .navigationTitle(files.canvas?.entry ?? "Preview").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Safari previews stay live while OpenWeights is open. Switching apps ends the preview.")
                .font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary).padding(8).frame(maxWidth: .infinity).background(OWTheme.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Back to chat") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button { safariTask = Task { await openSafari() } } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Open Safari preview here").accessibilityIdentifier("canvas.openSafari").disabled(url == nil || openingSafari)
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Close preview", role: .destructive) { files.dismissCanvas(); dismiss() } }
        }
        .task(id: files.canvas?.id) {
            safari?.stop(); safari = nil; server?.stop(); url = nil
            guard let canvas = files.canvas, let workspace = files.workspaceForFetch(expectedGrantID: files.grantID) else { dismiss(); return }
            do {
                let candidate = try CanvasLocalServer(canvas: canvas, workspace: workspace); server = candidate
                let opened = try await candidate.start(); try await browser.load(opened); url = opened
            } catch { failure = error.localizedDescription }
        }
        .onChange(of: files.canvas?.revision) { _, _ in if files.canvas?.kind == .site { browser.reload() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { server?.stop(); url = nil; dismiss() } }
        .sheet(item: $safari, onDismiss: { safari?.stop(); safari = nil }) { preview in
            if let controller = preview.controller { CanvasSafariView(controller: controller).ignoresSafeArea().onDisappear { preview.stop() } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { safari?.stop(); safari = nil } }
        .onDisappear { safariTask?.cancel(); browser.close(); server?.stop(); safari?.stop() }
    }
    private func openSafari() async {
        guard !openingSafari, let canvas = files.canvas, let grant = files.grantID,
              let workspace = files.workspaceForFetch(expectedGrantID: grant) else { return }
        openingSafari = true; defer { openingSafari = false }
        let preview = CanvasSafariPreview(canvas: canvas, workspace: workspace)
        do {
            _ = try await preview.start()
            guard files.grantID == grant, files.canvas?.id == canvas.id, scenePhase == .active, !Task.isCancelled else { preview.stop(); return }
            preview.didFinish = { [weak preview] in preview?.stop(); safari = nil }
            safari = preview
        } catch { preview.stop(); failure = error.localizedDescription }
    }
}
