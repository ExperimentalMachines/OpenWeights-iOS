import SwiftUI
import OpenWeightsCore

struct SettingsScreen: View {
    @ObservedObject var memory: MemoryController
    @ObservedObject var chat: ChatController
    @ObservedObject var files: WorkspaceController
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("compactAtPercent") private var compactAtPercent = 75.0
    @State private var token = ""
    @StateObject private var credentials = HubCredentialController()
    @StateObject private var diagnostics = DeviceDiagnosticsController()
    var body: some View {
        Form {
            Section("This device") {
                NavigationLink("Usage and storage") { DashboardScreen(chat: chat, downloads: chat.downloads) }
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            }
            Section("Memory") {
                NavigationLink("Saved facts") { MemoryScreen(memory: memory).disabled(chat.busy || chat.loading) }
                    .disabled(chat.busy || chat.loading)
            }
            Section {
                Slider(value: $compactAtPercent, in: 10...99, step: 1) {
                    Text("Summarize at \(Int(compactAtPercent))% of context")
                }
                Text("Summarize at \(Int(compactAtPercent))% of context").font(OWTheme.metric())
            } header: { Text("Conversation context") } footer: {
                Text("Earlier turns are summarized when the model needs room. Full history stays saved. The latest turns and interrupted-action warnings are retained. You can also fold earlier turns from chat.")
            }.disabled(chat.busy || chat.loading)
            Section("Tools") {
                NavigationLink("File tools and folder access") { ToolsScreen(files: files, chat: chat) }
                    .disabled(chat.busy || chat.loading)
            }
            Section {
                Toggle("Let chat read saved facts", isOn: $memory.readEnabled)
                Toggle("Let chat request memory changes", isOn: $memory.writeEnabled)
                if chat.loadedModel != nil && !chat.supportsTools && (memory.readEnabled || memory.writeEnabled) {
                    Text("The loaded model cannot use these tools. Select a tool-capable model or turn them off before sending.")
                        .foregroundStyle(OWTheme.secondary)
                }
            } header: { Text("Chat memory tools") } footer: {
                Text("Both start off. Reading happens only when the model requests it. Every save, edit or deletion requires your approval of the exact arguments.")
            }.disabled(chat.busy || chat.loading)
            credentialSection
            DeviceDiagnosticsSections(diagnostics: diagnostics)
            Section {
                Text("Messages, saved conversations and inference stay on this device. Discovery and model downloads connect to Hugging Face. There are no accounts or telemetry.")
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Settings")
        .task { credentials.refresh(); diagnostics.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in diagnostics.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in diagnostics.refresh() }
    }
    var credentialSection: some View {
            Section {
                SecureField("Hugging Face access token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(credentials.busy)
                Button(credentials.busy ? "Checking…" : "Save and verify") {
                    let candidate = token
                    Task { if await credentials.save(candidate) { token = "" } }
                }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentials.busy)
                if credentials.hasToken {
                    Button("Remove credential", role: .destructive) { if credentials.remove() { token = "" } }
                        .disabled(credentials.busy)
                }
                if let status = credentials.status { Text(status).font(OWTheme.interface(13)) }
            } header: { Text("Hugging Face") } footer: {
                Text("Optional for gated models. The credential stays in Keychain on this device. Save verifies it with Hugging Face. Rejected credentials are removed. Network failures keep the saved credential.")
            }
    }
}

struct DeviceDiagnosticsSections: View {
    @ObservedObject var diagnostics: DeviceDiagnosticsController
    var body: some View { Group { computeSection; deviceSection } }
    var computeSection: some View {
        Section {
            if let snapshot = diagnostics.snapshot {
                ForEach(snapshot.compute.devices) { device in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.kind)
                        if device.kind != "Processor" || device.description.caseInsensitiveCompare("CPU") != .orderedSame {
                            Text(device.description).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                        }
                        if device.kind != "Processor", device.totalMemoryBytes > 0 {
                            Text("Reported memory: " + bytes(device.totalMemoryBytes)).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                        }
                    }
                }
                if snapshot.compute.devices.isEmpty { Text("No GGUF compute devices were reported.") }
                if !snapshot.compute.features.backends.isEmpty {
                    LabeledContent("GGUF backends", value: snapshot.compute.features.backends.map { ["MTL":"Metal","BLAS":"Accelerate"][$0] ?? $0 }.joined(separator: ", "))
                }
                if !snapshot.compute.features.enabled.isEmpty {
                    Text("Enabled GGUF features").font(OWTheme.interface().weight(.semibold))
                    Text(snapshot.compute.features.enabled.joined(separator: " · ")).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
                }
            }
        } header: { Text("Compute") } footer: {
            Text("Devices and features come from the linked GGUF engine. Apple GPU memory is shared with the system. This does not guarantee a model fits or identify Neural Engine placement.")
        }
    }
    var deviceSection: some View {
        Section("Device") {
            if let snapshot = diagnostics.snapshot {
                LabeledContent("Processor cores", value: snapshot.processorCount.formatted())
                LabeledContent("Memory", value: bytes(snapshot.physicalMemoryBytes))
                LabeledContent("Current app headroom", value: snapshot.appHeadroomBytes.map(bytes) ?? "Unknown")
                LabeledContent("Free storage", value: snapshot.freeStorageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
                LabeledContent("System", value: snapshot.system)
                LabeledContent("Low Power Mode", value: snapshot.lowPowerMode ? "On" : "Off")
                LabeledContent("Thermal state", value: thermalLabel(snapshot.thermalState))
                Text("Observed " + snapshot.observedAt.formatted(date: .omitted, time: .standard)).font(OWTheme.metric()).foregroundStyle(OWTheme.secondary)
            }
            if let failure = diagnostics.failure { Text(failure).foregroundStyle(OWTheme.danger) }
            Button("Refresh device information") { diagnostics.refresh() }
        }
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
    private func thermalLabel(_ value: ProcessInfo.ThermalState) -> String {
        switch value { case .nominal: return "Nominal"; case .fair: return "Fair"; case .serious: return "Serious"; case .critical: return "Critical"; @unknown default: return "Unknown" }
    }
}
struct ModelSettingsScreen: View {
    @State var model: LocalModel
    @ObservedObject var downloads: ModelDownloads
    @ObservedObject var chat: ChatController
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        Form {
            Section("Runtime") {
                if model.entryFile.hasSuffix(".gguf") {
                    Picker("Backend", selection: $model.backend) {
                        Text("Metal").tag(ModelBackend.llamaMetal); Text("CPU").tag(ModelBackend.llamaCPU)
                    }
                } else { LabeledContent("Backend", value: model.backend.label) }
                Picker("Context tokens", selection: $model.settings.contextTokens) {
                    Text("2,048").tag(2048)
                    if !([.xnnpack, .executorchMLX].contains(model.backend)) { Text("4,096").tag(4096); Text("8,192").tag(8192) }
                }
                if model.backend == .llamaCPU || model.backend == .llamaMetal {
                    Stepper("CPU threads: \(model.settings.threads)", value: $model.settings.threads, in: 1...max(1, ProcessInfo.processInfo.activeProcessorCount))
                }
            }
            Section {
                Stepper("Output limit: \(model.settings.outputTokens)", value: $model.settings.outputTokens, in: 64...2048, step: 64)
                LabeledContent("Temperature", value: String(format: "%.2f", model.settings.temperature))
                Slider(value: $model.settings.temperature, in: 0...2, step: 0.05)
                if !([.xnnpack, .executorchMLX].contains(model.backend)) {
                    LabeledContent("Top P", value: String(format: "%.2f", model.settings.topP))
                    Slider(value: $model.settings.topP, in: 0.1...1, step: 0.05)
                    Toggle("Use backend default Top K", isOn: Binding(
                        get: { model.settings.topK == nil },
                        set: { model.settings.topK = $0 ? nil : (model.backend == .mlx ? 0 : 40) }))
                    if model.settings.topK != nil {
                        Stepper("Top K: \(model.settings.topK ?? 0)", value: Binding(
                            get: { model.settings.topK ?? 0 }, set: { model.settings.topK = $0 }), in: 0...100)
                        Text("Zero disables the Top K filter.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                    }
                    Toggle("Use backend default Min P", isOn: Binding(
                        get: { model.settings.minP == nil },
                        set: { model.settings.minP = $0 ? nil : (model.backend == .mlx ? 0 : 0.05) }))
                    if let minP = model.settings.minP {
                        LabeledContent("Min P", value: String(format: "%.2f", minP))
                        Slider(value: Binding(get: { model.settings.minP ?? 0 }, set: { model.settings.minP = $0 }), in: 0...1, step: 0.01)
                    }
                    LabeledContent("Repeat penalty", value: String(format: "%.2f", model.settings.repeatPenalty))
                    Slider(value: $model.settings.repeatPenalty, in: 1...1.5, step: 0.05)
                }
                if !([.xnnpack, .executorchMLX].contains(model.backend)) || CompiledModelFamily(rawValue: model.family ?? "")?.supportsThinking != false {
                    Toggle("Thinking", isOn: $model.settings.thinking)
                } else {
                    Text("This model does not support a thinking switch.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                }
                if !([.xnnpack, .executorchMLX].contains(model.backend)) {
                    Picker("Reasoning effort", selection: Binding(
                        get: { model.settings.reasoningEffort ?? .default },
                        set: { model.settings.reasoningEffort = $0 == .default ? nil : $0 })) {
                        ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if chat.loadedModel?.id == model.id {
                        Text(chat.supportsReasoningEffort ? "This model's template supports reasoning effort." : "This model's template uses its own effort. The preference stays saved for models that support it.")
                            .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                    } else {
                        Text("Load this model to check its reasoning effort support.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                    }
                }
            } header: { Text("Generation") } footer: {
                Text("Generation preferences are shared across models. Context, backend and CPU threads stay with this model.")
            }
            instructionControls
            Section {
                Text("Larger contexts use more memory. Backend and context changes reload the model. Compiled exports keep their exported window.").font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                if [.xnnpack, .executorchMLX].contains(model.backend) {
                    Text("This compiled adapter uses a fixed 2,048-token window. Top P, Top K, Min P, repeat penalty and reasoning effort are not applied.")
                        .font(OWTheme.interface(13)).foregroundStyle(OWTheme.secondary)
                } else {
                    LabeledContent("Effective Top K", value: String(model.settings.topK ?? (model.backend == .mlx ? 0 : 40)))
                    LabeledContent("Effective Min P", value: String(format: "%.2f", model.settings.minP ?? (model.backend == .mlx ? 0 : 0.05)))
                }
                if let failure { Text(failure).foregroundStyle(OWTheme.danger) }
            }
        }.scrollContentBackground(.hidden).background(OWTheme.canvas).navigationTitle("Model settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do {
                            try await chat.saveModelSettings(model)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                        saving = false
                    }
                }.disabled(saving || chat.busy || chat.loading)
            }
        }
    }
    private func instructionBinding(_ path: WritableKeyPath<ModelSettings, String?>) -> Binding<String> {
        Binding(get: { model.settings[keyPath: path] ?? "" }, set: { model.settings[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private var instructionControls: some View {
        Section {
            Picker("Answer length", selection: $model.settings.answerLength) {
                Text("Existing instructions").tag(Optional<AnswerLength>.none)
                ForEach(AnswerLength.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            Text("Standing instructions").font(OWTheme.interface().weight(.semibold))
            TextEditor(text: instructionBinding(\.systemPrompt)).frame(minHeight: 90)
                .accessibilityLabel("Standing instructions")
            Text("Tool instructions").font(OWTheme.interface().weight(.semibold))
            TextEditor(text: instructionBinding(\.toolPrompt)).frame(minHeight: 90)
                .accessibilityLabel("Tool instructions")
            Button("Reset defaults") {
                model.settings = ModelSettings()
                if model.entryFile.hasSuffix(".gguf") { model.backend = .llamaMetal }
            }
        } header: { Text("Instructions") } footer: {
            Text("These preferences are shared across models. Answer length guides the response without changing the token limit. Tool instructions apply when tools are available. Tool mode still controls approval. Reset changes this draft until you save.")
        }
    }
}
