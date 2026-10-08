import XCTest
@testable import OpenWeightsBench

final class BenchmarkTests: XCTestCase {
    #if GGUF_ONLY
    private func publicationInputs() throws -> (Artifact, MultiTurnWorkload) {
        let environment = ProcessInfo.processInfo.environment
        let artifactJSON = try XCTUnwrap(environment["OW_PUBLICATION_ARTIFACT"])
        let workloadJSON = try XCTUnwrap(environment["OW_PUBLICATION_WORKLOAD"])
        let artifact = try JSONDecoder().decode(Artifact.self, from: Data(artifactJSON.utf8))
        let workload = try JSONDecoder().decode(MultiTurnWorkload.self, from: Data(workloadJSON.utf8))
        guard artifact.files.count == 1, artifact.files[0].file.hasSuffix(".gguf"),
              !artifact.files[0].file.contains("/"), workload.turns.count == 6,
              workload.interruptionBeforeTurn == nil else {
            throw BenchmarkFailure.message("Invalid publication artifact or six-turn workload")
        }
        return (artifact, workload)
    }

    func testPublicationAcquire() async throws {
        let (artifact, _) = try publicationInputs()
        let previousIdle = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = previousIdle } }
        _ = try await ModelStore.prepare(artifact, cancellation: Cancellation(), progress: { print($0) })
    }

    func testPublicationConversation() async throws {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            throw BenchmarkFailure.message("Turn Low Power Mode off before publication measurements")
        }
        let (artifact, workload) = try publicationInputs()
        let environment = ProcessInfo.processInfo.environment
        let runtime = try XCTUnwrap(environment["OW_PUBLICATION_RUNTIME"])
        guard ["llama.cpp CPU", "llama.cpp Metal"].contains(runtime),
              let repetition = Int(environment["OW_PUBLICATION_REPETITION"] ?? ""), repetition >= 0 else {
            throw BenchmarkFailure.message("Invalid publication runtime or repetition")
        }
        let configuration = EngineConfiguration(name: runtime, artifactID: artifact.id, reusesPrefix: true,
            factory: { LlamaEngine(gpuLayers: runtime == "llama.cpp CPU" ? 0 : 99, filename: artifact.files[0].file) })
        let metadata = StudyMetadata(protocolID: "openweights-ios-publication-v1", block: repetition,
            scenario: workload.id, runtimeOrder: [runtime])
        let cancellation = Cancellation()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 600)
        timer.setEventHandler { cancellation.cancel() }
        timer.resume()
        defer { timer.cancel() }
        let url = try await runAndAttach(.multiTurn, configurations: [configuration], workload: workload,
            study: metadata, publicationArtifact: artifact, cancellation: cancellation)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        XCTAssertTrue(report.completed)
        XCTAssertFalse(report.lowPowerMode)
        XCTAssertEqual(report.rows.count, 1)
        let row = try XCTUnwrap(report.rows.first)
        XCTAssertNil(row.error)
        XCTAssertEqual(row.samples.compactMap(\.turn), [1, 2, 3, 4, 5, 6])
        for sample in row.samples {
            XCTAssertEqual(sample.workload, "multi-turn")
            XCTAssertGreaterThan(sample.generatedTokens, 0)
            XCTAssertNotNil(sample.firstCallbackMs)
            XCTAssertTrue(["eos", "length"].contains(sample.stopReason))
            if let tokens = sample.totalPromptTokens { XCTAssertLessThanOrEqual(tokens + 64, 2048) }
        }
    }

    func testPublicationCloudConversation() async throws {
        // A Firebase execution starts with an empty app container. Acquisition precedes
        // the unchanged measurement method and does not load an inference engine.
        let (artifact, _) = try publicationInputs()
        let previousIdle = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        var acquisitions: [AcquisitionEvent] = []
        defer {
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = previousIdle }
            if let data = try? JSONEncoder().encode(acquisitions) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "publication-cloud-acquisition.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        _ = try await ModelStore.prepare(artifact, cancellation: Cancellation(),
            progress: { print($0) }, observe: { acquisitions.append($0) })
        try await testPublicationConversation()
    }
    #endif

    func testPilotBenchmark() async throws {
        let url = try await runAndAttach(.pilot)
        try validatePilot(url, expectedRows: BenchmarkRunner.expectedRows)
    }

    func testFirebaseSmoke() async throws {
        try validatePilot(try await runAndAttach(.smoke), expectedRows: 1)
    }

    func testColdPinnedGGUFAcquisition() async throws {
        let manifestURL = try XCTUnwrap(Bundle.main.url(forResource: "model-manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let artifact = try XCTUnwrap(manifest.artifacts.first { $0.id == "gguf" })
        let file = try XCTUnwrap(artifact.files.first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousIdle = await MainActor.run {
            let previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            return previous
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = previousIdle }
        }
        var events: [AcquisitionEvent] = []
        defer {
            if let data = try? JSONEncoder().encode(events) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "cold-pinned-GGUF-acquisition"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let destination = root.appendingPathComponent(file.file)
        // This unique directory bypasses the app model cache without removing user data.
        try await ModelStore.downloadVerified(file, artifactID: artifact.id, destination: destination,
            cancellation: Cancellation(), progress: { print($0) }, observe: { events.append($0) })
        try ModelStore.verify(destination, file: file)
        XCTAssertEqual(events.last?.outcome, "download-verified")
        XCTAssertEqual(events.last?.receivedFileBytes, file.bytes)
        XCTAssertEqual(events.last?.statusCode, 200)
    }

    func testArtifactVerificationRejectsCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        let wrongHash = ArtifactFile(file: "fixture", sha256: String(repeating: "0", count: 64), bytes: 7, url: nil)
        XCTAssertThrowsError(try ModelStore.verify(url, file: wrongHash))
        let wrongSize = ArtifactFile(file: "fixture", sha256: try ModelStore.hash(url), bytes: 8, url: nil)
        XCTAssertThrowsError(try ModelStore.verify(url, file: wrongSize))
        try ModelStore.verify(url, file: ArtifactFile(file: "fixture", sha256: try ModelStore.hash(url), bytes: 7, url: nil))
    }

    private func validatePilot(_ url: URL, expectedRows: Int) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        XCTAssertTrue(report.completed)
        XCTAssertEqual(report.rows.count, expectedRows)
        for row in report.rows {
            XCTAssertNil(row.error, row.engine)
            XCTAssertTrue(row.cancellationPassed, row.engine)
            XCTAssertEqual(row.samples.filter { $0.workload == "short" }.count, 3, row.engine)
            for sample in row.samples where sample.workload != "cancel" {
                XCTAssertGreaterThan(sample.generatedTokens, 0, row.engine)
                XCTAssertLessThanOrEqual(sample.generatedTokens, report.maxOutputTokens, row.engine)
                XCTAssertFalse(sample.output.isEmpty, row.engine)
                XCTAssertNotNil(sample.firstCallbackMs, row.engine)
                XCTAssertNotEqual(sample.stopReason, "error", row.engine)
            }
        }
    }

    func testStudyBlock() async throws {
        let environment = ProcessInfo.processInfo.environment
        let block = Int(environment["OW_STUDY_BLOCK"] ?? "0") ?? -1
        XCTAssertGreaterThanOrEqual(block, 0)
        let scenario = environment["OW_STUDY_SCENARIO"] ?? "S2-workshop-corrections"
        let workload: MultiTurnWorkload
        if scenario == "S2-workshop-corrections" {
            workload = try MultiTurnWorkload.load()
        } else {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "study-workloads", withExtension: "json"))
            let fixtures = try JSONDecoder().decode([MultiTurnWorkload].self, from: Data(contentsOf: url))
            workload = try XCTUnwrap(fixtures.first { $0.id == scenario })
        }
        var configurations = BenchmarkRunner.configurations
        if let name = environment["OW_STUDY_RUNTIME"] {
            configurations = configurations.filter { $0.name == name }
        } else {
            configurations = configurations.filter { $0.name != "ExecuTorch Core ML" }
        }
        XCTAssertFalse(configurations.isEmpty)
        guard block >= 0, !configurations.isEmpty else { return }
        let offset = block % configurations.count
        configurations = Array(configurations.dropFirst(offset)) + Array(configurations.prefix(offset))
        var metadata = StudyMetadata(protocolID: "openweights-ios-artifact-study-v1", block: block,
            scenario: scenario, runtimeOrder: configurations.map(\.name))
        metadata.attempt = Int(environment["OW_STUDY_ATTEMPT"] ?? "0") ?? -1
        XCTAssertGreaterThanOrEqual(metadata.attempt, 0)
        let url = try await runAndAttach(.multiTurn, configurations: configurations, workload: workload, study: metadata)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        validateMultiTurn(report, expectedRows: configurations.count)
        if workload.interruptionBeforeTurn != nil {
            XCTAssertTrue(report.rows.allSatisfy { $0.cancellationPassed })
            XCTAssertTrue(report.rows.allSatisfy { $0.samples.filter { $0.workload == "interruption" }.count == 1 })
        }
    }

    func testMultiTurnBenchmark() async throws {
        let url = try await runAndAttach(.multiTurn)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        validateMultiTurn(report, expectedRows: BenchmarkRunner.expectedRows)
    }

    #if EXECUTORCH_DELEGATES
    func testMultiTurnExecuTorchCoreML() async throws {
        let configuration = try XCTUnwrap(BenchmarkRunner.configurations.first { $0.name == "ExecuTorch Core ML" })
        let url = try await runAndAttach(.multiTurn, configurations: [configuration])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        validateMultiTurn(report, expectedRows: 1)
    }

    func testMultiTurnExecuTorchMLX() async throws {
        let configuration = try XCTUnwrap(BenchmarkRunner.configurations.first { $0.name == "ExecuTorch MLX" })
        let url = try await runAndAttach(.multiTurn, configurations: [configuration])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(BenchmarkReport.self, from: Data(contentsOf: url))
        validateMultiTurn(report, expectedRows: 1)
    }
    #endif

    private func validateMultiTurn(_ report: BenchmarkReport, expectedRows: Int) {
        XCTAssertTrue(report.completed)
        XCTAssertEqual(report.rows.count, expectedRows)
        XCTAssertEqual(report.multiTurnWorkload?.turns.count, 6)
        for row in report.rows {
            XCTAssertNil(row.error, row.engine)
            let conversation = row.samples.filter { $0.workload == "multi-turn" }
            XCTAssertEqual(conversation.map { $0.turn }, [1, 2, 3, 4, 5, 6].map(Optional.some), row.engine)
            XCTAssertEqual(conversation.compactMap { $0.memoryProbePassed }.count, 3, row.engine)
            for sample in row.samples where sample.workload != "interruption" {
                XCTAssertEqual(sample.messages.count, 2 * (sample.turn ?? 0), row.engine)
                XCTAssertGreaterThan(sample.generatedTokens, 0, row.engine)
                XCTAssertLessThanOrEqual(sample.generatedTokens, report.maxOutputTokens, row.engine)
                XCTAssertFalse(sample.output.isEmpty, row.engine)
                XCTAssertNotNil(sample.firstCallbackMs, row.engine)
                XCTAssertNotEqual(sample.stopReason, "error", row.engine)
                if let tokens = sample.totalPromptTokens { XCTAssertLessThanOrEqual(tokens + report.maxOutputTokens, report.contextTokens, row.engine) }
            }
            if conversation.first?.cachePolicy == "retain-prefix" {
                let replay = row.samples.filter { $0.workload == "multi-turn-replay" }
                XCTAssertEqual(replay.count, conversation.count, row.engine)
                XCTAssertTrue(conversation.dropFirst().contains { ($0.cachedTokens ?? 0) > 0 }, row.engine)
                for (warm, cold) in zip(conversation, replay) {
                    XCTAssertEqual(warm.messages, cold.messages, row.engine)
                    XCTAssertEqual(cold.cachedTokens, 0, row.engine)
                }
                if row.engine.hasPrefix("llama.cpp") {
                    // Turn 5 answers "vegetarian", also present in the initial user turn.
                    // Splicing there used to change token 72 and discard most of the cache.
                    let previousLength = conversation[4].totalPromptTokens ?? 0
                    XCTAssertGreaterThanOrEqual(conversation[5].cachedTokens ?? 0, previousLength - 8, row.engine)
                    XCTAssertEqual(replay[0].totalPromptTokens, conversation[0].totalPromptTokens, row.engine)
                }
            } else {
                XCTAssertEqual(row.samples.count, 6 + (report.multiTurnWorkload?.interruptionBeforeTurn == nil ? 0 : 1), row.engine)
                XCTAssertTrue(conversation.allSatisfy { $0.cachedTokens == 0 }, row.engine)
            }
        }
    }

    func testMultiTurnProbeGrading() throws {
        let workload = try MultiTurnWorkload.load()
        let final = workload.turns[5]
        XCTAssertEqual(final.grade("{\"codename\":\"Cedar\",\"venue\":\"Osaka\",\"budget\":730,\"diet\":\"vegetarian\"}"), true)
        XCTAssertEqual(final.grade("{\"codename\":\"Cedar\",\"venue\":\"Kyoto\",\"budget\":480,\"diet\":\"vegetarian\"}"), false)
        XCTAssertEqual(final.grade("{\"codename\":\"Cedar\",\"budget\":730}"), false)
        XCTAssertEqual(final.grade("The budget is 730"), false)
        XCTAssertEqual(workload.turns[4].grade(" vegetarian\n"), true)
        XCTAssertEqual(workload.turns[4].grade("non-vegetarian"), false)
    }

    private func runAndAttach(_ suite: BenchmarkSuite, configurations: [EngineConfiguration]? = nil,
                              workload: MultiTurnWorkload? = nil, study: StudyMetadata? = nil,
                              publicationArtifact: Artifact? = nil,
                              cancellation: Cancellation = Cancellation()) async throws -> URL {
        let beganAt = Date()
        let url: URL
        do {
            if let configurations {
                url = try await MultiTurnRunner.run(cancellation: cancellation, configurations: configurations,
                    workload: workload, study: study, publicationArtifact: publicationArtifact) { print($0) }
            } else {
                url = try await BenchmarkRunner.run(cancellation: cancellation, suite: suite) { print($0) }
            }
        } catch {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let reports = try FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("benchmark-") && $0.pathExtension == "json"
                    && ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= beganAt }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast) }
            if let partial = reports.first { attachReport(partial) }
            throw error
        }
        attachReport(url)
        return url
    }

    private func attachReport(_ url: URL) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "benchmark-results.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
