import SwiftUI
import UniformTypeIdentifiers
import OpenWeightsCore

struct ToolsScreen: View {
    @ObservedObject var files: WorkspaceController
    @ObservedObject var chat: ChatController
    @State private var choosing = false
    @State private var removing = false
    @State private var confirmingYolo = false
    @State private var yoloText = ""
    var body: some View {
        Form {
            Section {
                if let name = files.folderName { LabeledContent("Shared folder", value: name) }
                else { Text("No shared folder").foregroundStyle(OWTheme.secondary) }
                Button(files.folderName == nil ? "Choose folder" : "Change folder") { choosing = true }
                    .accessibilityIdentifier("tools.chooseFolder")
                if files.folderName != nil { Button("Remove folder access", role: .destructive) { removing = true } }
                if files.folderName != nil && !files.acceptsWrites { Text("This folder is read-only.").foregroundStyle(OWTheme.secondary) }
            } header: { Text("File access") } footer: {
                Text("Only the folder you choose is available to chat. Removing access keeps your files. File tools start off.")
            }
            Section {
                ForEach(FileToolDefinitions.all, id: \.name) { definition in
                    Toggle(label(definition.name), isOn: Binding(get: { files.enabled.contains(definition.name) }, set: { enabled in
                        if enabled { files.enabled.insert(definition.name) } else { files.enabled.remove(definition.name) }
                    })).disabled(!files.acceptsWrites && ["write_file", "delete_file"].contains(definition.name))
                }
            } header: { Text("File tools") } footer: {
                Text("Read and search text files, save notes and delete files. Writes are limited to 2,000 characters. Links cannot be followed outside your folder.")
            }.disabled(files.folderName == nil)
            Section {
                ForEach(CanvasToolDefinitions.all, id: \.name) { definition in
                    Toggle(definition.name == "show_website" ? "Show websites" : definition.name == "show_document" ? "Show documents" : "Show slides", isOn: Binding(get: { files.canvasEnabled.contains(definition.name) }, set: { enabled in
                        if enabled { files.canvasEnabled.insert(definition.name) } else { files.canvasEnabled.remove(definition.name) }
                    }))
                }
            } header: { Text("Canvas") } footer: {
                Text("Preview files in your shared folder. Websites run local JavaScript. Documents use A4 pages and slides use 16:9. Nothing loads from the network. Preview assets are limited to 8 MiB each.")
            }.disabled(files.folderName == nil)
            Section {
                Toggle("Run scripts", isOn: $chat.scriptEnabled).disabled(!chat.scriptsAvailable)
                    .accessibilityIdentifier("tools.scripts.run")
                if !chat.scriptsAvailable { Text("Scripts require iOS 26 or later.").foregroundStyle(OWTheme.secondary) }
            } header: { Text("Computation") } footer: {
                Text("JavaScript runs on this device for calculations, dates and JSON. Scripts start off. They can read up to three files from your chosen folder. Ask first approves chat scripts. Scheduled checks use Auto and skip calls that need approval.")
            }
            if let web = chat.web { WebToolControls(web: web) }
            if chat.loadedModel != nil && !chat.supportsTools && (!files.definitions.isEmpty || (chat.scriptsAvailable && chat.scriptEnabled) || chat.web?.definitions.isEmpty == false || files.mode == .plan || chat.current?.plan?.isFinished == false) {
                Section { Text("The loaded model cannot use these tools. Choose a tool-capable model, or clear the plan and turn tools off in Auto mode.").foregroundStyle(OWTheme.secondary) }
            }
            Section {
                Picker("Tool mode", selection: Binding(get: { files.mode }, set: { mode in
                    if mode == .yolo { yoloText = ""; confirmingYolo = true }
                    else { files.mode = mode }
                })) {
                    Text("Auto").tag(AgentMode.auto); Text("Ask first").tag(AgentMode.ask)
                    Text("Plan").tag(AgentMode.plan); Text("Yolo").tag(AgentMode.yolo)
                }
                Text(modeDescription).font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            } header: { Text("Chat behavior") } footer: {
                Text("Memory changes and changes to existing user files still require approval. Yolo resets when the app restarts.")
            }
            if let error = files.error { Section { Text(error).foregroundStyle(OWTheme.danger) } }
            if files.busy { Section { ProgressView("Updating folder access…") } }
        }.disabled(chat.busy || chat.loading || chat.boardUpdating || chat.goalActive || files.busy)
            .scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Tools")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { Task { await files.choose(url) } }
                case .failure(let error): files.error = error.localizedDescription
                }
            }
            .confirmationDialog("Remove access to this folder?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove access", role: .destructive) { Task { await files.revoke() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Chat will no longer be able to read or change its files.") }
            .alert("Enable Yolo for this session?", isPresented: $confirmingYolo) {
                TextField("Type yolo", text: $yoloText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Enable") { if yoloText == "yolo" { files.mode = .yolo } }.disabled(yoloText != "yolo")
                Button("Cancel", role: .cancel) {}
            } message: { Text("Yolo can send private file and memory text without another approval and follow URLs suggested by pages. Lasting changes still ask. This mode resets when the app restarts.") }
    }
    private func label(_ name: String) -> String {
        switch name { case "find_files": return "Find files"; case "read_file": return "Read text files"; case "write_file": return "Write files"; default: return "Delete files" }
    }
    private var modeDescription: String {
        switch files.mode {
        case .auto: return "Run ordinary tools automatically and show each result in chat."
        case .ask: return "Ask before each tool runs."
        case .plan: return "Ask for missing details and propose a short plan. File and memory actions do not run."
        case .yolo: return "Run ordinary tools automatically for this app session. Persistent and destructive changes still ask."
        }
    }
}

private struct WebToolControls: View {
    @ObservedObject var web: WebController
    var body: some View {
        Section {
            Toggle("Search the web", isOn: $web.searchEnabled)
                .accessibilityIdentifier("tools.web.search")
            Toggle("Show pictures and clips", isOn: $web.mediaEnabled)
                .accessibilityIdentifier("tools.web.showPictures")
            Toggle("Fetch public pages", isOn: $web.fetchEnabled)
                .accessibilityIdentifier("tools.web.fetchURL")
        } header: { Text("Web access") } footer: {
            Text("Web search and pictures start on. Page fetching starts off. Picture queries go to DuckDuckGo and download up to eight thumbnails from public HTTPS hosts. Reopening shows cached previews without sending another request. Tapping a result opens its source page. Searches send a short query to enabled providers. Page fetching sends requested URLs to their public HTTPS websites. Page redirects can reach other public websites. Page fetching sends no cookies or credentials. Readable pages can be searched or saved into your chosen folder, up to 512 KiB.")
        }
        Section {
            ForEach([SearchEngine.duckduckgo, .brave, .yahoo], id: \.self) { engine in
                Toggle(engine.label, isOn: Binding(get: { web.searchEngines.contains(engine) }, set: { enabled in
                    web.setEngine(engine, enabled: enabled)
                })).disabled(web.searchEngines.count == 1 && web.searchEngines.contains(engine)).accessibilityIdentifier("tools.web.provider." + engine.rawValue)
            }
            Toggle("Search library documentation first", isOn: $web.documentation)
                .accessibilityIdentifier("tools.web.documentation")
            Stepper("Results: \(web.resultCount)", value: $web.resultCount, in: 1...5)
        } header: { Text("Search providers") } footer: {
            Text("Try DuckDuckGo, Brave, then Yahoo, stopping at the first answer. Context7 goes first when documentation search is on. Search cookies stay in app memory. Keep at least one provider selected, or turn web search off to stop all search requests.")
        }.disabled(!web.searchEnabled)
        SearchProxyControls(web: web)
    }
}

struct SearchProxyControls: View {
    @ObservedObject var web: WebController
    @State private var address = ""
    @State private var authenticated = false
    @State private var username = ""
    @State private var password = ""
    @State private var status: String?
    @State private var failed = false
    var body: some View {
        Section {
            TextField("http://host:port", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .accessibilityLabel("Search proxy address").accessibilityIdentifier("tools.web.proxy.address")
            Toggle("Proxy authentication", isOn: $authenticated).accessibilityIdentifier("tools.web.proxy.authentication")
            if authenticated {
                SecureField("Proxy username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Proxy password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                if web.proxyHasCredentials { Text("Credentials are saved in Keychain. Leave both fields empty to keep them for the same address.").foregroundStyle(OWTheme.secondary) }
            }
            Button("Save proxy") {
                do {
                    let credentials = authenticated && (!username.isEmpty || !password.isEmpty) ? try SearchProxyCredentials(username: username, password: password) : nil
                    try web.saveProxy(address: address, credentials: credentials, keepSavedCredentials: authenticated && credentials == nil)
                    address = web.proxyAddress; username = ""; password = ""; authenticated = web.proxyHasCredentials
                    status = web.proxyAddress.isEmpty ? "Search connects directly." : "Proxy saved."; failed = false
                } catch { status = error.localizedDescription; failed = true }
            }.accessibilityIdentifier("tools.web.proxy.save")
            if !web.proxyAddress.isEmpty {
                Button("Remove proxy", role: .destructive) {
                    do { try web.saveProxy(address: ""); address = ""; username = ""; password = ""; authenticated = false; status = "Search connects directly."; failed = false }
                    catch { status = error.localizedDescription; failed = true }
                }.accessibilityIdentifier("tools.web.proxy.remove")
            }
            if let status { Text(status).foregroundStyle(failed ? OWTheme.danger : OWTheme.secondary) }
        } header: { Text("Search proxy") } footer: {
            Text("Optional HTTP CONNECT, HTTPS CONNECT or SOCKS5 proxy for search providers and picture queries. Page fetching, thumbnails, source links and model downloads keep their own connections. Origin names are resolved on this device and only checked public IPs are sent through the proxy. Authentication stays in Keychain. A failed proxy stops search without a direct retry. Proxies may also be blocked by providers.")
        }.onAppear { address = web.proxyAddress; authenticated = web.proxyHasCredentials }
    }
}
