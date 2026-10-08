import CryptoKit
import Foundation
import UIKit

enum BenchmarkSuite: String, CaseIterable, Identifiable {
    case pilot, multiTurn, smoke
    var id: String { rawValue }
}

struct StudyMetadata: Codable, Sendable {
    let protocolID: String
    let block: Int
    let scenario: String
    let runtimeOrder: [String]
    var attempt: Int = 0
}

struct EngineConfiguration {
    let name: String
    let artifactID: String
    let reusesPrefix: Bool
    let factory: () -> BenchmarkEngine
}

struct MultiTurnWorkload: Codable, Sendable {
    struct Turn: Codable, Sendable {
        let user: String
        let padding: String?
        let paddingRepeats: Int?
        let expectedText: String?
        let expectedFields: [String: String]?
        var content: String { String(repeating: padding ?? "", count: paddingRepeats ?? 0) + user }

        func grade(_ output: String) -> Bool? {
            if let expectedText {
                return output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedText.lowercased()
            }
            if let expectedFields {
                guard let data = output.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return expectedFields.allSatisfy { key, expected in
                    guard let value = result[key] else { return false }
                    return String(describing: value).lowercased() == expected.lowercased()
                }
            }
            return nil
        }
    }
    let id: String
    let version: Int
    let system: String
    let turns: [Turn]
    var interruptionBeforeTurn: Int? = nil

    static func load() throws -> MultiTurnWorkload {
        guard let url = Bundle.main.url(forResource: "multiturn-workload", withExtension: "json") else {
            throw BenchmarkFailure.message("Multi-turn workload missing")
        }
        let workload = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard workload.turns.count == 6 else { throw BenchmarkFailure.message("Expected six conversation turns") }
        return workload
    }
}

enum MultiTurnRunner {
    static func run(cancellation: Cancellation, configurations: [EngineConfiguration] = BenchmarkRunner.configurations,
                    workload suppliedWorkload: MultiTurnWorkload? = nil, study: StudyMetadata? = nil,
                    publicationArtifact: Artifact? = nil,
                    progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let previousIdle = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = previousIdle } }
        // iOS kills sustained CPU work in non-frontmost apps. Stop and checkpoint instead.
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { _ in cancellation.cancel() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let workload = try suppliedWorkload ?? MultiTurnWorkload.load()
        guard let manifestURL = Bundle.main.url(forResource: BenchmarkRunner.manifestName, withExtension: "json") else {
            throw BenchmarkFailure.message("Model manifest missing")
        }
        let bundledManifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let manifest = publicationArtifact.map { Manifest(upstream: $0.repo, artifacts: [$0]) } ?? bundledManifest
        let runID = UUID().uuidString
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("benchmark-\(runID).json")
        var system = utsname(); uname(&system)
        let device = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        var report = BenchmarkReport(schemaVersion: 2, runID: runID, startedAt: Date(), purpose: publicationArtifact != nil ? "publication-conversation-v1" : study == nil ? "multi-turn-scaling-pilot" : "repeated-conversation-artifact-study",
            device: device, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, availableMemoryAtStart: OWAvailableMemoryBytes(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, contextTokens: 2048, maxOutputTokens: 64,
            runtimeVersions: BenchmarkRunner.runtimeVersions,
            measurementNotes: [
                "One six-turn conversation per artifact per report block. Actual assistant outputs carry into subsequent turns.",
                publicationArtifact != nil ? "Publication profile retains prefix cache and performs no reset replay or interruption test. One configuration per fresh XCTest invocation." : "Prefix-enabled adapters retain cache, then replay identical recorded prompts with a reset before each turn.",
                "ExecuTorch adapters reset internally before each request. Their sole sequence uses rebuild-each-turn policy.",
                publicationArtifact != nil ? "Models must already be verified in the device cache. No downloads are permitted in measurement invocations. Fewer than eight generated tokens are excluded from headline throughput." : "Reset replays run after the retained-cache conversation. Fixed order and warm framework caches affect comparisons.",
                "Native totalPromptTokens is evaluated promptTokens plus cachedTokens. Explicit prompt counts can be reconstructed from recorded messages and the pinned tokenizer.",
                "First text includes prompt preparation and detokenization. Very short answers give noisy streaming throughput.",
                "Footprint is whole-process memory sampled every 50 ms, not isolated engine memory. No power measurement.",
                "Memory probes grade exact text or specified JSON values. Failures are model observations, not runtime execution failures.",
                "Release, greedy decoding, thinking disabled, 2k context and 64 output tokens. Downloads and hashes are outside timing.",
                "Foreground guard v1 waits for active application state and cancels if the app resigns active, preserving partial checkpoints.",
                BenchmarkRunner.artifactComparisonNote,
                "One conversation does not establish general conversational quality."],
            rows: [], completed: false, multiTurnWorkload: workload, study: study)
        if publicationArtifact != nil { report.processIdentifier = ProcessInfo.processInfo.processIdentifier }
        func persist() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: destination, options: .atomic)
        }
        try persist()
        let foregroundDeadline = clockMilliseconds() + 60_000
        while await MainActor.run(body: { UIApplication.shared.applicationState != .active }) {
            if clockMilliseconds() > foregroundDeadline { throw BenchmarkFailure.message("Benchmark app did not become active within one minute. Keep it visible during the run.") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        var directories: [String: URL] = [:]
        for artifact in manifest.artifacts where configurations.contains(where: { $0.artifactID == artifact.id }) {
            directories[artifact.id] = try await ModelStore.prepare(artifact, cancellation: cancellation, progress: progress,
                allowDownload: publicationArtifact == nil) { event in
                report.acquisitions = (report.acquisitions ?? []) + [event]
                try persist()
            }
        }
        for configuration in configurations {
            try cancellation.check()
            progress("Waiting for nominal thermal state before \(configuration.name)")
            let deadline = clockMilliseconds() + 180_000
            while ProcessInfo.processInfo.thermalState != .nominal {
                try cancellation.check()
                if clockMilliseconds() > deadline { throw BenchmarkFailure.message("Phone did not cool to nominal within three minutes. Partial report saved.") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard let artifact = manifest.artifacts.first(where: { $0.id == configuration.artifactID }),
                  let directory = directories[configuration.artifactID] else {
                throw BenchmarkFailure.message("Configuration artifact missing from manifest")
            }
            var row = BenchmarkRow(engine: configuration.name, artifact: artifact)
            report.rows.append(row)
            func checkpoint() throws { report.rows[report.rows.count - 1] = row; try persist() }
            try checkpoint()
            let engine = configuration.factory()
            do {
                let start = clockMilliseconds(), recorder = SampleRecorder()
                try await engine.load(directory: directory)
                row.loadMs = clockMilliseconds() - start
                row.loadPeakFootprintBytes = recorder.finish().2
                row.backend = engine.backend; row.phase = "running"
                try checkpoint()
                var messages = [["role": "system", "content": workload.system]]
                var recordedPrompts: [[[String: String]]] = []
                await engine.reset()
                for (index, turn) in workload.turns.enumerated() {
                    if workload.interruptionBeforeTurn == index + 1 {
                        let interruptedPrompt = messages + [["role": "user", "content": "Write a detailed long story about preparing a workshop."]]
                        let interrupted = try await BenchmarkRunner.measure(engine, workload: "interruption", repetition: study?.block ?? 0,
                            messages: interruptedPrompt, cancellation: cancellation, cancelAfter: 3)
                        row.samples.append(interrupted)
                        row.cancellationPassed = interrupted.stopReason == "cancelled" && interrupted.generatedTokens <= 8
                        try checkpoint()
                        guard row.cancellationPassed else { throw BenchmarkFailure.message("Interruption did not stop within the callback bound") }
                        // Discard the auxiliary request, then reconstruct the recorded conversation.
                        await engine.reset()
                    }
                    messages.append(["role": "user", "content": turn.content])
                    recordedPrompts.append(messages)
                    progress("\(configuration.name): conversation turn \(index + 1)/\(workload.turns.count)")
                    var sample = try await BenchmarkRunner.measure(engine, workload: "multi-turn", repetition: study?.block ?? 0,
                        messages: messages, cancellation: cancellation)
                    annotate(&sample, turn: index + 1, policy: configuration.reusesPrefix ? "retain-prefix" : "rebuild-each-turn", workload: workload)
                    row.samples.append(sample)
                    messages.append(["role": "assistant", "content": sample.output])
                    try checkpoint()
                }
                if configuration.reusesPrefix && publicationArtifact == nil {
                    for (index, prompt) in recordedPrompts.enumerated() {
                        await engine.reset()
                        progress("\(configuration.name): reset replay turn \(index + 1)/\(workload.turns.count)")
                        var sample = try await BenchmarkRunner.measure(engine, workload: "multi-turn-replay", repetition: study?.block ?? 0,
                            messages: prompt, cancellation: cancellation)
                        annotate(&sample, turn: index + 1, policy: "reset-each-turn", workload: workload)
                        row.samples.append(sample)
                        try checkpoint()
                    }
                }
                row.phase = "complete"
            } catch { row.error = error.localizedDescription; row.phase = "failed" }
            await engine.unload()
            try checkpoint()
            if row.error != nil { progress("\(configuration.name) failed. Saved diagnostic and continuing.") }
            try cancellation.check()
        }
        report.completed = true; try persist()
        return destination
    }

    private static func annotate(_ sample: inout BenchmarkSample, turn: Int, policy: String, workload: MultiTurnWorkload) {
        sample.conversationID = workload.id
        sample.turn = turn; sample.cachePolicy = policy
        sample.promptUTF8Bytes = renderPrompt(sample.messages).utf8.count
        sample.totalPromptTokens = sample.promptTokens.map { $0 + (sample.cachedTokens ?? 0) }
        sample.memoryProbePassed = workload.turns[turn - 1].grade(sample.output)
    }
}
