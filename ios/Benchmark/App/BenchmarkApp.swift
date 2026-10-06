import SwiftUI

@main
struct BenchmarkApp: App {
    var body: some Scene {
        WindowGroup { BenchmarkView() }
    }
}

struct BenchmarkView: View {
    @State private var status = "Ready"
    @State private var running = false
    @State private var report: URL?
    @State private var cancellation = Cancellation()
    @State private var suite = BenchmarkSuite.pilot

    var body: some View {
        NavigationStack {
            List {
                Section("Local benchmark") {
                    #if EXECUTORCH_DELEGATES
                    Text("Qwen3 0.6B on ExecuTorch Core ML and ExecuTorch MLX.")
                    Text("Verified model exports are bundled before installation. Results stay on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #elseif GGUF_ONLY
                    Text("Qwen3 0.6B GGUF on CPU, full Metal, and partial Metal. iOS 16.6 benchmark variant.")
                    Text("The pinned model downloads from Hugging Face before timing begins. Results stay on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #else
                    Text("Qwen3 0.6B on llama.cpp CPU, Metal, partial offload, ExecuTorch, and MLX.")
                    Text("Model files download from Hugging Face before timing begins. Results stay on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    #endif
                }
                Section("Progress") { Text(status).textSelection(.enabled) }
                Section {
                    Picker("Workload", selection: $suite) {
                        Text("Pilot").tag(BenchmarkSuite.pilot)
                        Text("Six-turn conversation").tag(BenchmarkSuite.multiTurn)
                    }.disabled(running)
                    Button(running ? "Running" : "Run benchmark") {
                        running = true
                        report = nil
                        cancellation = Cancellation()
                        Task {
                            do {
                                report = try await BenchmarkRunner.run(cancellation: cancellation, suite: suite) { update in
                                    Task { @MainActor in status = update }
                                }
                                status = "Complete. Export the raw JSON report below."
                            } catch { status = error.localizedDescription }
                            running = false
                        }
                    }.disabled(running)
                    if running { Button("Cancel", role: .destructive) { cancellation.cancel() } }
                    if let report { ShareLink("Export results", item: report) }
                }
            }.navigationTitle("OpenWeights Bench")
        }
    }
}
