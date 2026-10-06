import SwiftUI
import Metal
import OpenWeightsCore

struct GGUFPreviewScreen: View {
    let details: HubDetails
    let file: HubDetails.File
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var chat: ChatController
    @State private var usageRecords: [UsageRecord] = []
    @State private var calibrationModels: [LocalModel] = []
    @State private var calibrationError: String?
    @State private var calibrationRefresh = UUID()
    @State private var model: LocalModel?
    @State private var metadata: GGUFMetadata?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var context = 2048
    @State private var backend = ModelBackend.llamaMetal
    @State private var installing = false
    @State private var projector = ""
    private var architectures: Set<String> { Set(OWRuntimeSession.registeredArchitectureNames()) }
    private var issue: String? { metadata?.standaloneIssue(registeredArchitectures: architectures) }
    private var contexts: [Int] {
        let limit = metadata?.trainingContext ?? 0
        return [1024, 2048, 4096, 8192].filter { limit == 0 || $0 <= limit }
    }
    var body: some View {
        List {
            Section("Artifact") {
                Text(file.rfilename).font(OWTheme.metric(14)).textSelection(.enabled)
                LabeledContent("File size", value: bytes(model?.files.first?.bytes ?? file.lfs?.size ?? file.size))
                if let hint = GGUFFileName.quantization(file.rfilename) { LabeledContent("Filename quantization", value: hint) }
                Text("Revision \(details.sha)").font(OWTheme.metric(12)).textSelection(.enabled)
                if let checksum = model?.files.first?.sha256 {
                    Text("Published SHA-256: \(checksum)").font(OWTheme.metric(12)).textSelection(.enabled)
                } else { Text("No published SHA-256 is available. The download can check its byte count, but cannot verify it against a published checksum.").font(OWTheme.interface(13)) }
            }
            if let metadata {
                Section("Header inspection") {
                    LabeledContent("Architecture", value: metadata.architecture)
                    LabeledContent("Training context", value: metadata.trainingContext > 0 ? String(metadata.trainingContext) : "Unknown")
                    LabeledContent("Blocks", value: metadata.blocks > 0 ? String(metadata.blocks) : "Unknown")
                    Text("Read \(bytes(Int64(metadata.fetchedBytes))) from Hugging Face. This is a partial header check. Tensor data and checksum verification happen after download.").font(OWTheme.interface(13))
                    if let issue { Text(issue).foregroundStyle(OWTheme.danger) }
                    else { Text("The engine recognizes this architecture. Loading, chat templates and model capabilities are checked after download.").font(OWTheme.interface(13)) }
                }
                if issue == nil {
                    let projectors = details.siblings.filter { ($0.rfilename as NSString).lastPathComponent.lowercased().hasPrefix("mmproj") && $0.rfilename.lowercased().hasSuffix(".gguf") }
                    if !projectors.isEmpty {
                        Section("Multimodal projector") {
                            Picker("Paired file", selection: $projector) {
                                Text("None, text only").tag("")
                                ForEach(projectors) { Text($0.rfilename).tag($0.rfilename) }
                            }.disabled(installing)
                            Text("Select the projector published for this base model. Both files are pinned and verified. Actual image/audio support is checked when loaded.").font(OWTheme.interface(13))
                        }
                    }
                    Section("Runtime") {
                        Picker("Backend", selection: $backend) {
                            Text("Metal").tag(ModelBackend.llamaMetal)
                            Text("CPU").tag(ModelBackend.llamaCPU)
                        }
                        Picker("Context tokens", selection: $context) { ForEach(contexts, id: \.self) { Text($0.formatted()).tag($0) } }
                        if contexts.isEmpty { Text("This model's declared context is smaller than the supported preview choices.").foregroundStyle(OWTheme.danger) }
                        if backend == .llamaMetal && MTLCreateSystemDefaultDevice() == nil { Text("Metal is unavailable. Select CPU.").foregroundStyle(OWTheme.danger) }
                    }
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        let preview = memory(metadata)
                        Section("Memory estimate") {
                            LabeledContent("Weights plus F16 KV cache", value: bytes(preview.weightsAndKVBytes))
                            LabeledContent("KV cache at this context", value: bytes(preview.kvBytes))
                            LabeledContent("Current app headroom", value: bytes(preview.headroomBytes))
                            LabeledContent("Free storage", value: bytes(preview.storageBytes))
                            if preview.exceedsCurrentHeadroom { Text("Weights and estimated cache exceed current app headroom. Choose a smaller model or context.").foregroundStyle(OWTheme.danger) }
                            if preview.insufficientStorage { Text("There is insufficient storage for the file and its download staging range.").foregroundStyle(OWTheme.danger) }
                            Text("This estimate excludes runtime buffers, recurrent state and other allocations. Memory headroom changes as iOS runs. Loading can still fail even when the estimate is below headroom.").font(OWTheme.interface(13))
                        }
                    }
                    Section("Speed estimate for " + backend.label) {
                        if let error = chat.usageError { Text(error).foregroundStyle(OWTheme.danger) }
                        if let calibrationError { Text(calibrationError).foregroundStyle(OWTheme.secondary) }
                        ThroughputEstimateView(estimates: ThroughputEstimates(records: usageRecords, installed: calibrationModels, backend: backend),
                            weightBytes: model?.files.first?.bytes ?? file.lfs?.size ?? file.size, backend: backend)
                    }
                    Button(installing ? "Starting download" : "Download model") { Task { await install(metadata) } }
                        .disabled(installing || model == nil || contexts.isEmpty || (backend == .llamaMetal && MTLCreateSystemDefaultDevice() == nil))
                }
            } else if let failure {
                Section { Text(failure).foregroundStyle(OWTheme.danger); Button("Retry header inspection") { attempt += 1 } }
            } else { ProgressView("Inspecting GGUF header on Hugging Face") }
        }
        .scrollContentBackground(.hidden).background(OWTheme.canvas)
        .navigationTitle("Model preview").navigationBarTitleDisplayMode(.inline)
        .task(id: chat.usageRevision) { await refreshCalibration() }
        .onChange(of: downloads.models) { Task { await refreshCalibration() } }
        .task(id: attempt) {
            failure = nil
            do {
                var selected = try HubClient.gguf(details, file: file)
                let source = try HubGGUFRangeSource(model: selected)
                let inspected = try await GGUFHeaderParser(source: source).parse()
                selected.files[0].bytes = await source.totalBytes
                try Task.checkCancellation()
                model = selected; metadata = inspected
                context = [1024, 2048].filter { inspected.trainingContext == 0 || $0 <= inspected.trainingContext }.last ?? 1024
                if MTLCreateSystemDefaultDevice() == nil { backend = .llamaCPU }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { failure = (error as? ModelError)?.localizedDescription ?? "The header could not be inspected. Check connectivity and repository access, then retry." }
            }
        }
        .onChange(of: projector) { _, name in
            do { model = try HubClient.gguf(details, file: file, projector: name.isEmpty ? nil : details.siblings.first { $0.rfilename == name }) }
            catch { model = nil; failure = error.localizedDescription }
        }
        .alert("Download", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
            Button("OK") { downloads.error = nil }
        } message: { Text(downloads.error ?? "") }
    }
    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown"
    }
    private func refreshCalibration() async {
        let epoch = UUID(); calibrationRefresh = epoch
        let models = downloads.models, records = await chat.usage?.list() ?? []
        do {
            let snapshot = try await ModelStorageInspector().snapshot(root: downloads.root, models: models)
            guard calibrationRefresh == epoch, !Task.isCancelled else { return }
            usageRecords = records; calibrationModels = snapshot.modelsWithKnownWeights(models); calibrationError = nil
        } catch {
            guard calibrationRefresh == epoch, !Task.isCancelled else { return }
            usageRecords = records; calibrationModels = []; calibrationError = "Installed weight files could not be inspected, so local speed estimates are unavailable."
        }
    }
    private func memory(_ metadata: GGUFMetadata) -> GGUFMemoryPreview {
        let storage = try? downloads.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        return GGUFMemoryPreview(metadata: metadata, weightBytes: model.flatMap { value in value.files.allSatisfy { $0.bytes != nil } ? value.files.reduce(0) { $0 + ($1.bytes ?? 0) } : nil }, context: context,
            headroomBytes: OWRuntimeSession.availableMemoryBytes().int64Value, storageBytes: storage)
    }
    private func install(_ metadata: GGUFMetadata) async {
        guard var selected = model, issue == nil, contexts.contains(context), !installing else { return }
        guard !memory(metadata).insufficientStorage else { downloads.error = "Free storage is too low for this download."; return }
        selected.backend = backend; selected.settings.contextTokens = context
        selected.settings.outputTokens = min(selected.settings.outputTokens, context / 4)
        installing = true
        await downloads.install(selected)
        installing = false
    }
}
