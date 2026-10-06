import CryptoKit
import Foundation
import UIKit

func clockMilliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

struct ArtifactFile: Codable, Sendable {
    let file: String
    let sha256: String
    let bytes: Int64
    let url: URL?
}
struct Artifact: Codable, Sendable {
    let id: String
    let repo: String
    let revision: String
    let quantization: String
    let files: [ArtifactFile]
}
struct Manifest: Codable, Sendable {
    let upstream: String
    let artifacts: [Artifact]
}
struct BenchmarkSample: Codable, Sendable {
    let workload: String
    let repetition: Int
    let messages: [[String: String]]
    let renderedPromptSHA256: String?
    let elapsedMs: Double
    let firstCallbackMs: Double?
    let streamTokensPerSecond: Double?
    let generatedTokens: Int
    let promptTokens: Int?
    let cachedTokens: Int?
    let enginePrefillMs: Double?
    let engineDecodeMs: Double?
    let output: String
    let stopReason: String
    let peakFootprintBytes: UInt64
    let thermalStart: Int
    let thermalEnd: Int
    let cancellationLatencyMs: Double?
    var conversationID: String? = nil
    var turn: Int? = nil
    var cachePolicy: String? = nil
    var promptUTF8Bytes: Int? = nil
    var totalPromptTokens: Int? = nil
    var memoryProbePassed: Bool? = nil
}
struct BenchmarkRow: Codable, Sendable {
    let engine: String
    let artifact: Artifact
    var backend = ""
    var loadMs: Double = 0
    var loadPeakFootprintBytes: UInt64 = 0
    var phase = "loading"
    var cancellationPassed = false
    var samples: [BenchmarkSample] = []
    var error: String?
}
struct BenchmarkReport: Codable, Sendable {
    let schemaVersion: Int
    let runID: String
    let startedAt: Date
    let purpose: String
    let device: String
    let operatingSystem: String
    let physicalMemoryBytes: UInt64
    let availableMemoryAtStart: UInt64
    let lowPowerMode: Bool
    let contextTokens: Int
    let maxOutputTokens: Int
    let runtimeVersions: [String: String]
    let measurementNotes: [String]
    var rows: [BenchmarkRow]
    var completed: Bool
    var multiTurnWorkload: MultiTurnWorkload? = nil
    var study: StudyMetadata? = nil
    var acquisitions: [AcquisitionEvent]? = nil
}

struct EngineReply: Sendable {
    var output: String
    var generatedTokens: Int
    var promptTokens: Int?
    var cachedTokens: Int?
    var prefillMs: Double?
    var decodeMs: Double?
    var stopReason: String
    var cancellationRequestedAt: Double? = nil
}

protocol BenchmarkEngine: AnyObject {
    var backend: String { get }
    func load(directory: URL) async throws
    func generate(messages: [[String: String]], maxTokens: Int,
                  cancelAfter: Int?, cancellation: Cancellation,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> EngineReply
    func reset() async
    func unload() async
}

// The fixed pilot uses text-only Qwen3 messages, thinking disabled and no tools.
// This string is recorded for the explicit-prompt runtimes; llama.cpp renders its GGUF template.
func renderPrompt(_ messages: [[String: String]]) -> String {
    messages.map { "<|im_start|>\($0["role"]!)\n\($0["content"]!)<|im_end|>\n" }.joined()
        + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
}

enum BenchmarkFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    private var last: Double?
    private var callbacks = 0
    private var peak: UInt64 = OWFootprintBytes()
    private let timer: DispatchSourceTimer
    init() {
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sampleMemory() }
        timer.resume()
    }
    deinit { timer.cancel() }
    func sampleMemory() { let value = OWFootprintBytes(); lock.lock(); peak = max(peak, value); lock.unlock() }
    func token(_ text: String) {
        let now = clockMilliseconds()
        lock.lock(); if first == nil { first = now }; last = now; callbacks += 1; lock.unlock()
    }
    func finish() -> (Double?, Double?, UInt64) {
        timer.cancel(); sampleMemory(); lock.lock(); defer { lock.unlock() }
        return (first, last, peak)
    }
}

enum BenchmarkRunner {
    #if GGUF_ONLY
    static let artifactComparisonNote = "The same pinned GGUF, template and cache policy are used for CPU/full/partial Metal. This iOS 16.6 variant excludes unused MLX/ExecuTorch frameworks, so its process footprint must not be pooled with the baseline package."
    #else
    static let artifactComparisonNote = "Quantizations differ: this compares packaged artifacts, not runtime-only effects."
    #endif
    #if GGUF_ONLY
    static let expectedRows = 3
    static let manifestName = "model-manifest"
    static let runtimeVersions = ["llama.cpp": "b2e5e9b28b2484fbf94b543432ece638996a8b97", "benchmarkVariant": "gguf-ios16.6-v1", "minimumIOS": "16.6"]
    #elseif EXECUTORCH_DELEGATES
    static let expectedRows = 2
    static let manifestName = "model-manifest-delegates"
    static let runtimeVersions = ["ExecuTorch": "1.5.0", "SwiftPM": "56cc93a96d5fb8d21554ec5f00fbad5a5b228bc4", "export source": "f7140a46ff38e919c557d45b102d3ff26097c8c9"]
    #else
    static let expectedRows = 5
    static let manifestName = "model-manifest"
    static let runtimeVersions = ["llama.cpp": "b2e5e9b28b2484fbf94b543432ece638996a8b97", "ExecuTorch": "1.4.0", "mlx-swift-lm": "3.31.3", "mlx-swift": "0.31.4", "ET tokenizer addon": "a7855194f5bf55f792f8142282dd0ae3613b1d37", "PCRE2": "2e03e323339ab692640626f02f8d8d6f95bff9c6"]
    #endif
    static var configurations: [EngineConfiguration] {
        #if GGUF_ONLY
        return [
            EngineConfiguration(name: "llama.cpp CPU", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 0) }),
            EngineConfiguration(name: "llama.cpp Metal", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 99) }),
            EngineConfiguration(name: "llama.cpp partial Metal", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 14) })]
        #elseif EXECUTORCH_DELEGATES
        return [
            EngineConfiguration(name: "ExecuTorch Core ML", artifactID: "coreml", reusesPrefix: false,
                factory: { ExecuTorchEngine(modelFile: "model.pte", backend: "Core ML; CPU_AND_GPU compute units; FP16 KV cache; 2k context; static token steps; cache reset before each turn") }),
            EngineConfiguration(name: "ExecuTorch MLX", artifactID: "executorch-mlx", reusesPrefix: false,
                factory: { ExecuTorchEngine(modelFile: "model.pte", backend: "ExecuTorch MLX Metal delegate; 2k context; 2047-token dynamic prefill bound; cache reset before each turn") })]
        #else
        return [
            EngineConfiguration(name: "llama.cpp CPU", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 0) }),
            EngineConfiguration(name: "ExecuTorch XNNPACK", artifactID: "executorch", reusesPrefix: false, factory: { ExecuTorchEngine() }),
            EngineConfiguration(name: "llama.cpp Metal", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 99) }),
            EngineConfiguration(name: "MLX Metal", artifactID: "mlx", reusesPrefix: true, factory: { MLXEngine() }),
            EngineConfiguration(name: "llama.cpp partial Metal", artifactID: "gguf", reusesPrefix: true, factory: { LlamaEngine(gpuLayers: 14) })]
        #endif
    }

    static func run(cancellation: Cancellation, suite: BenchmarkSuite = .pilot,
                    progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        if suite == .multiTurn { return try await MultiTurnRunner.run(cancellation: cancellation, progress: progress) }
        let selected = suite == .smoke
            ? configurations.filter { $0.name == "llama.cpp Metal" || $0.name == "ExecuTorch MLX" }
            : configurations
        let previousIdleSetting = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = previousIdleSetting } }
        guard let manifestURL = Bundle.main.url(forResource: manifestName, withExtension: "json") else {
            throw BenchmarkFailure.message("Model manifest missing")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let runID = UUID().uuidString
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("benchmark-\(runID).json")
        var system = utsname(); uname(&system)
        let device = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        var report = BenchmarkReport(schemaVersion: 1, runID: runID, startedAt: Date(), purpose: suite == .smoke ? "firebase-smoke-validation" : "runner-validation-pilot",
            device: device, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, availableMemoryAtStart: OWAvailableMemoryBytes(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, contextTokens: 2048, maxOutputTokens: 64,
            runtimeVersions: runtimeVersions,
            measurementNotes: ["Release build, greedy decoding, repeat penalty disabled, thinking disabled.",
                artifactComparisonNote,
                "First callback latency includes prompt preparation and detokenization. It is not raw first-token latency.",
                "Stream throughput uses generated token count minus one over first-to-last callback interval.",
                "Footprint is sampled every 50 ms during load and generation and can miss shorter peaks. No power measurement is claimed.",
                "Fresh-context runs are not cold filesystem-cache measurements.",
                "llama.cpp uses its GGUF chat template. The recorded explicit prompt applies to MLX and ExecuTorch.",
                "Core ML compute units describe allowed devices, not verified Neural Engine placement.",
                "No increased-memory-limit entitlement is requested. Downloads and checksum verification are outside timing."],
            rows: [], completed: false)
        func persist() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: destination, options: .atomic)
        }
        try persist()
        var directories: [String: URL] = [:]
        for artifact in manifest.artifacts where selected.contains(where: { $0.artifactID == artifact.id }) {
            directories[artifact.id] = try await ModelStore.prepare(artifact, cancellation: cancellation, progress: progress) { event in
                report.acquisitions = (report.acquisitions ?? []) + [event]
                try persist()
            }
        }
        let systemMessage = ["role": "system", "content": "You are a helpful assistant. Follow the user's instructions precisely."]
        let short = [systemMessage, ["role": "user", "content": "Explain why leaves are green in three short sentences."]]
        let long = [systemMessage, ["role": "user", "content": String(repeating: "The garden has trees, flowers, and a pond. ", count: 40)
            + "Summarize this description in two short sentences."]]
        for configuration in selected {
            let name = configuration.name, artifactID = configuration.artifactID, factory = configuration.factory
            try cancellation.check()
            progress("Waiting for nominal thermal state before \(name)")
            let deadline = clockMilliseconds() + 180_000
            while ProcessInfo.processInfo.thermalState != .nominal {
                try cancellation.check()
                if clockMilliseconds() > deadline { throw BenchmarkFailure.message("Phone did not cool to nominal within three minutes. Partial report saved.") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let artifact = manifest.artifacts.first { $0.id == artifactID }!
            var row = BenchmarkRow(engine: name, artifact: artifact)
            report.rows.append(row)
            func checkpoint() throws { report.rows[report.rows.count - 1] = row; try persist() }
            try checkpoint()
            let engine = factory()
            do {
                progress("Loading \(name)")
                let loadStart = clockMilliseconds()
                let loadRecorder = SampleRecorder()
                try await engine.load(directory: directories[artifactID]!)
                row.loadMs = clockMilliseconds() - loadStart; row.backend = engine.backend
                row.loadPeakFootprintBytes = loadRecorder.finish().2; row.phase = "running"
                try checkpoint()
                for repetition in 0..<3 {
                    progress("\(name): short prompt \(repetition + 1)/3")
                    await engine.reset()
                    let sample = try await measure(engine, workload: "short", repetition: repetition, messages: short, cancellation: cancellation)
                    row.samples.append(sample)
                    try checkpoint()
                    let followup = short + [["role": "assistant", "content": sample.output],
                        ["role": "user", "content": "Now explain the same thing in one sentence."]]
                    row.samples.append(try await measure(engine, workload: "followup", repetition: repetition, messages: followup, cancellation: cancellation))
                    try checkpoint()
                }
                await engine.reset()
                row.samples.append(try await measure(engine, workload: "long", repetition: 0, messages: long, cancellation: cancellation))
                try checkpoint()
                await engine.reset()
                let cancelled = try await measure(engine, workload: "cancel", repetition: 0,
                    messages: [systemMessage, ["role": "user", "content": "Write a detailed, long story about a journey across the ocean."]],
                    cancellation: cancellation, cancelAfter: 3)
                row.samples.append(cancelled)
                row.cancellationPassed = cancelled.stopReason == "cancelled" && cancelled.generatedTokens <= 8
                try checkpoint()
                await engine.reset()
                row.samples.append(try await measure(engine, workload: "after-cancel", repetition: 0, messages: short, cancellation: cancellation))
                row.phase = "complete"
            } catch { row.error = error.localizedDescription; row.phase = "failed" }
            await engine.unload()
            try checkpoint()
            if row.error != nil { progress("\(name) failed. Saved diagnostic and continuing.") }
            try cancellation.check()
        }
        report.completed = true; try persist()
        return destination
    }

    static func measure(_ engine: BenchmarkEngine, workload: String, repetition: Int,
                                messages: [[String: String]], cancellation: Cancellation,
                                cancelAfter: Int? = nil) async throws -> BenchmarkSample {
        try cancellation.check()
        let recorder = SampleRecorder()
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let start = clockMilliseconds()
        let reply = try await engine.generate(messages: messages, maxTokens: 64,
            cancelAfter: cancelAfter, cancellation: cancellation) { recorder.token($0) }
        let end = clockMilliseconds()
        let (first, last, footprint) = recorder.finish()
        let throughput: Double? = if let first, let last, last > first, reply.generatedTokens > 1 {
            Double(reply.generatedTokens - 1) * 1000 / (last - first)
        } else { nil }
        let checksum = SHA256.hash(data: Data(renderPrompt(messages).utf8)).map { String(format: "%02x", $0) }.joined()
        #if EXECUTORCH_DELEGATES
        let promptHash: String? = checksum
        #else
        let promptHash: String? = engine is LlamaEngine ? nil : checksum
        #endif
        return BenchmarkSample(workload: workload, repetition: repetition, messages: messages, renderedPromptSHA256: promptHash,
            elapsedMs: end - start, firstCallbackMs: first.map { $0 - start }, streamTokensPerSecond: throughput,
            generatedTokens: reply.generatedTokens, promptTokens: reply.promptTokens, cachedTokens: reply.cachedTokens,
            enginePrefillMs: reply.prefillMs, engineDecodeMs: reply.decodeMs, output: reply.output, stopReason: reply.stopReason,
            peakFootprintBytes: footprint, thermalStart: thermal, thermalEnd: ProcessInfo.processInfo.thermalState.rawValue,
            cancellationLatencyMs: reply.cancellationRequestedAt.map { end - $0 })
    }
}
