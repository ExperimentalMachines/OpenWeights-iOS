import SwiftUI
import UniformTypeIdentifiers
import OpenWeightsCore

struct ModelsScreen: View {
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var catalogue: [LocalModel] = []
    @State private var importing = false
    @State private var importingFolder = false
    @State private var folderFormat = ModelFolderFormat.mlx
    @State private var deleting: LocalModel?
    @State private var settings: LocalModel?
    var body: some View {
        List {
            Section("On this device") {
                if downloads.models.isEmpty {
                    Text("Download a model below, search Hugging Face, or import a model from Files.").foregroundStyle(OWTheme.secondary)
                }
                ForEach(downloads.models) { model in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.name).font(OWTheme.interface().weight(.semibold)).lineLimit(3)
                        Text(model.backend.label).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                        if let value = downloads.progress[model.id] { ProgressView(value: value).tint(OWTheme.signal) }
                        if let failure = model.failure { Text(failure).font(OWTheme.interface(13)).foregroundStyle(OWTheme.danger) }
                        HStack {
                            if model.state == .ready {
                                Button(chat.loadedModel?.id == model.id ? "Loaded" : "Use model") {
                                    Task { await chat.load(model); if chat.loadedModel?.id == model.id { dismiss() } }
                                }.buttonStyle(OWActionStyle()).disabled(chat.busy || chat.loading)
                                Button("Settings") { settings = model }.buttonStyle(.bordered).disabled(chat.busy || chat.loading)
                            } else if model.state == .downloading {
                                Button("Pause") { Task { await downloads.pause(model) } }.buttonStyle(.bordered)
                            } else {
                                Button(model.state == .paused ? "Resume" : "Retry") { Task { await downloads.resume(model) } }.buttonStyle(.bordered)
                            }
                            Spacer()
                            Button { deleting = model } label: { Image(systemName: "trash") }.accessibilityLabel("Delete \(model.name)")
                                .disabled(chat.busy || chat.loading || chat.loadedModel?.id == model.id)
                        }
                    }.padding(.vertical, 8)
                }
            }
            Section {
                ForEach(catalogue) { model in
                    Button { Task { await downloads.install(model) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.name).font(OWTheme.interface())
                            Text(ByteCountFormatter.string(fromByteCount: model.files.reduce(0) { $0 + ($1.bytes ?? 0) }, countStyle: .file))
                                .font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                        }.frame(minHeight: 44)
                    }.disabled(downloads.models.contains(where: { $0.repository == model.repository && $0.backend == model.backend }))
                }
            } header: { Text("Pinned benchmark artifacts") } footer: { Text("These artifacts were validated in the iPhone pilot. The multi-device study is still in progress.") }
            Section {
                NavigationLink("Search Hugging Face") { DiscoverScreen(downloads: downloads, chat: chat) }
                Button("Import GGUF model or model/projector pair") { importing = true }.disabled(downloads.importingName != nil)
                Button("Import MLX model folder") { folderFormat = .mlx; importingFolder = true }.disabled(downloads.importingName != nil)
                Button("Import ExecuTorch CPU folder") { folderFormat = .xnnpack; importingFolder = true }.disabled(downloads.importingName != nil)
                Button("Import ExecuTorch MLX folder") { folderFormat = .executorchMLX; importingFolder = true }.disabled(downloads.importingName != nil)
                if let name = downloads.importingName {
                    ProgressView("Importing \(name)")
                    Button("Stop import") { downloads.cancelFolderImport() }
                }
            } footer: {
                Text("Folder imports copy model files into OpenWeights. MLX needs its config, safetensors weights and tokenizer files. Compiled imports need one Qwen3 or Qwen2.5 Instruct XNNPACK 2,048-token export with config.json export facts and a top-level tokenizer.json. The runtime checks loading compatibility when you use the model.")
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Models")
        .task { do { catalogue = try HubClient.pinnedCatalogue() } catch { downloads.error = error.localizedDescription } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let base = urls.filter { GGUFFileName.exclusion($0.lastPathComponent) == nil }
                let projectors = urls.filter { $0.lastPathComponent.lowercased().hasPrefix("mmproj") && $0.pathExtension.lowercased() == "gguf" }
                if base.count == 1, projectors.count <= 1, urls.count == base.count + projectors.count {
                    Task { await downloads.importGGUF(base[0], projector: projectors.first) }
                } else { downloads.error = "Select one base GGUF and, optionally, its matching mmproj GGUF." }
            case .failure(let error): downloads.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let source): Task { await downloads.importFolder(source, format: folderFormat) }
            case .failure(let error): downloads.error = error.localizedDescription
            }
        }
        .sheet(item: $settings) { model in NavigationStack { ModelSettingsScreen(model: model, downloads: downloads, chat: chat) } }
        .alert("Model operation failed", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
            Button("Dismiss", role: .cancel) { downloads.error = nil }
        } message: { Text(downloads.error ?? "") }
        .alert("Delete model?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let model = deleting { Task { do { try await downloads.remove(model) } catch { downloads.error = error.localizedDescription } } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("The model files will be removed. Your conversations remain stored.") }
    }
}
struct DiscoverScreen: View {
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var chat: ChatController
    @StateObject private var discovery = DiscoveryController()
    @State private var text = ""
    @State private var filters = false
    @State private var draft = HubQuery()
    var body: some View {
        List {
            Section {
                Text(discovery.query.shortlistOnly ? "Shortlist metadata is fetched from Hugging Face. Text and filters are applied on this device. Messages are never sent." : "Search sends your query and filters to Hugging Face. Messages are never sent.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                Toggle("Android shortlist", isOn: Binding(get: { discovery.query.shortlistOnly }, set: { enabled in
                    var query = discovery.query; query.shortlistOnly = enabled; query.text = text; discovery.search(query)
                }))
                if discovery.query.shortlistOnly {
                    Text("Curated by the Android app. Its measurements do not establish iPhone performance or fit. Typing narrows this list. Experimental models have modified refusal behavior and are not recommendations.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                }
                Picker("Sort", selection: Binding(get: { discovery.query.sort }, set: { sort in
                    var query = discovery.query; query.sort = sort; query.text = text; discovery.search(query)
                })) { ForEach(HubSort.allCases, id: \.self) { Text(discovery.query.shortlistOnly && $0 == .trending ? "Curated order" : $0.label).tag($0) } }
                Button(discovery.query.activeCount == 0 ? "Filters" : "Filters (\(discovery.query.activeCount))") {
                    draft = discovery.query; filters = true
                }
                HStack { ForEach(HubRuntime.allCases, id: \.self) { runtime in
                    if discovery.query.effectiveRuntimes.contains(runtime) { Text(runtime.label).font(OWTheme.metric(12)) }
                } }.foregroundStyle(OWTheme.secondary)
            }
            if discovery.busy { ProgressView("Searching Hugging Face") }
            if let failure = discovery.error { Text(failure).foregroundStyle(OWTheme.danger); Button("Retry") { discovery.retry() } }
            if !discovery.unavailableRuntimes.isEmpty {
                Text("Unavailable searches: " + discovery.unavailableRuntimes.map(\.label).joined(separator: ", ")).foregroundStyle(OWTheme.secondary)
                Button("Retry search") { discovery.search(discovery.query) }
            }
            if !discovery.unavailableRepositories.isEmpty {
                Text("Unavailable shortlist repositories: " + discovery.unavailableRepositories.joined(separator: ", ")).font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                Button("Retry shortlist") { discovery.search(discovery.query) }
            }
            ForEach(discovery.models) { model in
                NavigationLink { HubFilesScreen(id: model.id, downloads: downloads, chat: chat) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.id).font(OWTheme.metric(14)).lineLimit(3)
                        if model.experimental { Text("Experimental: modified refusals").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary) }
                        if discovery.query.shortlistOnly, let file = HubShortlist.androidMeasuredFiles[model.id] {
                            Text("Measured on Android: " + file).font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }
                        Text(HubRuntime.allCases.filter { model.runtimes.contains($0) }.map(\.label).joined(separator: " · ")).font(OWTheme.metric(12)).foregroundStyle(OWTheme.secondary)
                        if let count = model.downloads { Text("\(count.formatted()) downloads").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary) }
                        if model.gated { Text("Access approval and a token may be required.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary) }
                    }.frame(minHeight: 44)
                }
            }
            if discovery.hasMore { Button { discovery.loadMore() } label: { if discovery.loadingMore { ProgressView("Loading more") } else { Text("Load more") } }.disabled(discovery.loadingMore || discovery.busy) }
            if !discovery.busy && discovery.error == nil && discovery.models.isEmpty {
                Text(discovery.hasMore ? "No matches on this page. Load more to continue with these filters." : "No matching models. Try another query or change the filters.").foregroundStyle(OWTheme.secondary)
            }
            Text("Repository tags identify published formats and tasks. File compatibility is checked separately. A parameter-size filter is not a memory-fit guarantee.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Discover")
            .searchable(text: $text, prompt: "Model name").onSubmit(of: .search) {
                var query = discovery.query; query.text = text; discovery.search(query)
            }
            .task { if discovery.models.isEmpty && !discovery.busy { discovery.search(discovery.query) } }
            .onDisappear { discovery.cancel() }
            .sheet(isPresented: $filters) {
                NavigationStack {
                    Form {
                        Section("Runtime") {
                            ForEach(HubRuntime.allCases, id: \.self) { runtime in
                                Toggle(runtime.label, isOn: Binding(get: { draft.runtimes.contains(runtime) }, set: { selected in
                                    if selected { draft.runtimes.insert(runtime) } else { draft.runtimes.remove(runtime) }
                                }))
                            }
                            Text("Selecting no runtimes searches all formats. File selection checks compatibility. MLX folders need published model metadata, matching tokenizer files and weights.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }
                        Section("Task") { Picker("Published task", selection: $draft.task) { ForEach(HubTask.allCases, id: \.self) { Text($0.label).tag($0) } } }
                        Section("Size") {
                            Picker("Parameter count", selection: $draft.parameters) { ForEach(HubParameterRange.allCases, id: \.self) { Text($0.label).tag($0) } }.onChange(of: draft.parameters) { draft.maximumParametersBillions = nil }
                            Toggle("Custom parameter ceiling", isOn: Binding(get: { draft.maximumParametersBillions != nil }, set: { draft.maximumParametersBillions = $0 ? 4 : nil }))
                            if draft.maximumParametersBillions != nil {
                                Stepper("Up to \(draft.maximumParametersBillions!)B", value: Binding(get: { draft.maximumParametersBillions ?? 4 }, set: { draft.maximumParametersBillions = $0 }), in: 1...128)
                            }
                            Text("Size filters check repository-name hints as well as the Hub query. Models with unstated sizes remain visible. This does not estimate loading memory.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }
                        Section("Publisher and access") {
                            TextField("Publisher, for example unsloth", text: $draft.author).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Toggle("Organisation publishers only", isOn: $draft.organisationsOnly)
                            Toggle("Open repositories only", isOn: $draft.hideGated)
                            Text("Organisation means an organisation account on Hugging Face. It does not imply a model endorsement.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }
                        Button("Reset filters") { draft = HubQuery() }
                    }.navigationTitle("Discovery filters").toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { filters = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Apply") {
                            draft.text = text; discovery.search(draft); filters = false
                        } }
                    }
                }
            }
    }
}
struct HubFilesScreen: View {
    let id: String
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var chat: ChatController
    @State private var details: HubDetails?
    @State private var failure: String?
    var body: some View {
        List {
            if let details {
                if !details.siblings.contains(where: { GGUFFileName.exclusion($0.rfilename) == nil || $0.rfilename.hasSuffix(".pte") }) && !(details.library_name == "mlx" || details.tags?.contains("mlx") == true) {
                    Text("No complete base GGUF, compiled .pte export or declared MLX folder is offered here.").foregroundStyle(OWTheme.secondary)
                }
                ForEach(details.siblings.filter { GGUFFileName.exclusion($0.rfilename) == nil }) { file in
                    NavigationLink { GGUFPreviewScreen(details: details, file: file, downloads: downloads, chat: chat) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.rfilename).font(OWTheme.metric(14)).lineLimit(3)
                            if let size = file.lfs?.size ?? file.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(OWTheme.secondary) }
                        }.frame(minHeight: 44)
                    }
                }
                if details.library_name == "mlx" || details.tags?.contains("mlx") == true {
                    Section("MLX folder") {
                        NavigationLink { MLXPreviewScreen(details: details, downloads: downloads) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Preview MLX model folder").font(OWTheme.interface(14))
                                Text("Inspect pinned metadata and selected weight files before downloading.").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                Section("Compiled exports") {
                    ForEach(details.siblings.filter { $0.rfilename.hasSuffix(".pte") }) { file in
                        NavigationLink { CompiledPreviewScreen(details: details, file: file, downloads: downloads) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(file.rfilename).font(OWTheme.metric(14)).lineLimit(3)
                                if let size = file.lfs?.size ?? file.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(OWTheme.secondary) }
                            }.frame(minHeight: 44)
                        }
                    }
                }
                Text("Downloads pin revision \(details.sha). Compiled and MLX selection check declared metadata and matching companion files before downloading weights.")
                    .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
            } else if let failure { Text(failure).foregroundStyle(OWTheme.danger) }
            else { ProgressView("Loading repository files") }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle(id).navigationBarTitleDisplayMode(.inline)
            .task { do { details = try await HubClient.details(id) } catch { failure = error.localizedDescription } }
    }
}
