import SwiftUI
import OpenWeightsCore

struct MLXPreviewScreen: View {
    let details: HubDetails
    @ObservedObject var downloads: ModelDownloads
    @State private var model: LocalModel?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var installing = false
    var body: some View {
        List {
            Section("Artifact") {
                Text(details.id).font(OWTheme.metric(14)).textSelection(.enabled)
                Text("Revision \(details.sha)").font(OWTheme.metric(12)).textSelection(.enabled)
            }
            if let model {
                Section("Compatibility") {
                    LabeledContent("Declared family", value: model.family ?? "Unspecified")
                    LabeledContent("Backend", value: model.backend.label)
                    Text("The repository declares an MLX model folder. Its selected files and metadata are pinned. Actual loading and model behavior are checked when you use it.").font(OWTheme.interface(13))
                }
                Section("Download files") {
                    ForEach(model.files, id: \.path) { component in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(component.path).font(OWTheme.metric(13))
                            Text(ByteCountFormatter.string(fromByteCount: component.bytes ?? 0, countStyle: .file)).foregroundStyle(OWTheme.secondary)
                            Text(component.sha256 != nil ? "Published SHA-256" : "Published Git blob checksum").font(OWTheme.interface(12)).foregroundStyle(OWTheme.secondary)
                        }
                    }
                    Text("Every selected file is downloaded from this revision and checked against its published size and checksum. Weight size does not include cache or runtime allocations and cannot guarantee that the model fits in memory.").font(OWTheme.interface(13))
                }
                Button(installing ? "Starting download" : "Download model") {
                    Task {
                        guard !installing else { return }
                        installing = true
                        await downloads.install(model)
                        installing = false
                    }
                }.disabled(installing || downloads.models.contains { $0.repository == model.repository && $0.revision == model.revision && $0.entryFile == model.entryFile && $0.backend == model.backend })
            } else if let failure {
                Section { Text(failure).foregroundStyle(OWTheme.danger); Button("Retry folder inspection") { attempt += 1 } }
            } else { ProgressView("Checking MLX folder on Hugging Face") }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas)
            .navigationTitle("MLX model preview").navigationBarTitleDisplayMode(.inline)
            .task(id: attempt) {
                model = nil; failure = nil
                do { let selected = try await HubClient.mlx(details); try Task.checkCancellation(); model = selected }
                catch is CancellationError { }
                catch { if !Task.isCancelled { failure = (error as? ModelError)?.localizedDescription ?? "The folder could not be inspected. Check connectivity and repository access, then retry." } }
            }
            .alert("Download", isPresented: Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })) {
                Button("OK") { downloads.error = nil }
            } message: { Text(downloads.error ?? "") }
    }
}
