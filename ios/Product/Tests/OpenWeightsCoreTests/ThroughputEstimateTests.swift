import XCTest
@testable import OpenWeightsCore

final class ThroughputEstimateTests: XCTestCase {
    private func model(_ name: String = "Cedar", bytes: Int64 = 100, hash: String = String(repeating: "a", count: 64), backend: ModelBackend = .llamaCPU) -> LocalModel {
        var value = LocalModel(name: name, backend: backend, entryFile: "model.gguf", files: [ModelFile(path: "model.gguf", bytes: bytes, sha256: hash)])
        value.state = .ready; return value
    }
    private func row(_ model: LocalModel, prompt: Int = 20, generated: Int = 11, prefill: Double? = 1000, decode: Double? = 1000, decoded: Int? = 10, known: Bool = true) -> UsageRecord {
        UsageRecord(modelID: model.id, modelName: model.name, backend: model.backend,
            measurements: UsageMeasurements(promptTokens: prompt, generatedTokens: generated, cachedTokens: 200,
                inferenceMilliseconds: (prefill ?? 0) + (decode ?? 0), prefillMilliseconds: prefill, decodeMilliseconds: decode, decodeTokens: decoded),
            weights: known ? UsageWeights(model: model) : nil)
    }
    func testWeightIdentityCountsWeightsOnlyAndHandlesShardsAndBackends() throws {
        var gguf = model(); let cpu = try XCTUnwrap(UsageWeights(model: gguf))
        gguf.backend = .llamaMetal; XCTAssertEqual(UsageWeights(model: gguf), cpu)
        gguf.files.append(ModelFile(path: "tokenizer.json", bytes: 900)); XCTAssertEqual(UsageWeights(model: gguf), cpu)
        var mlx = model(backend: .mlx)
        mlx.files = [ModelFile(path: "b.safetensors", bytes: 200, sha256: String(repeating: "b", count: 64)),
                     ModelFile(path: "a.safetensors", bytes: 100, sha256: String(repeating: "a", count: 64)), ModelFile(path: "config.json", bytes: 900)]
        let shards = try XCTUnwrap(UsageWeights(model: mlx)); XCTAssertEqual(shards.bytes, 300)
        mlx.files.reverse(); XCTAssertEqual(UsageWeights(model: mlx), shards)
        var pte = model(backend: .xnnpack)
        pte.files = [ModelFile(path: "model.pte", bytes: 400, sha256: String(repeating: "a", count: 64)),
                     ModelFile(path: "weights.ptd", bytes: 600, sha256: String(repeating: "b", count: 64)), ModelFile(path: "tokenizer.bin", bytes: 900)]
        XCTAssertEqual(UsageWeights(model: pte)?.bytes, 1000)
    }
    func testUnreadyUnknownInvalidDuplicateAndOverflowWeightsCannotCalibrate() {
        var value = model(); value.state = .paused; XCTAssertNil(UsageWeights(model: value))
        value.state = .ready
        for file in [ModelFile(path: "model.gguf", bytes: 100), ModelFile(path: "model.gguf", bytes: 0, sha256: String(repeating: "a", count: 64)),
                     ModelFile(path: "../model.gguf", bytes: 100, sha256: String(repeating: "a", count: 64)),
                     ModelFile(path: "model.gguf", bytes: 100, sha256: String(repeating: "z", count: 64))] {
            value.files = [file]; XCTAssertNil(UsageWeights(model: value))
        }
        value = model(); value.files.append(value.files[0]); XCTAssertNil(UsageWeights(model: value))
        value = model(bytes: .max); value.files.append(ModelFile(path: "second.gguf", bytes: 1, sha256: String(repeating: "b", count: 64)))
        XCTAssertNil(UsageWeights(model: value))
    }
    func testWeightedMeasurementsSelectMostWorkIndependentlyForEachPhase() throws {
        let first = model("More decode", bytes: 100), second = model("More prompt", bytes: 200)
        let rows = [row(first, prompt: 20, generated: 101, prefill: 1000, decode: 10000, decoded: 100),
                    row(first, prompt: 2, generated: 11, prefill: 100, decode: 1000, decoded: 10),
                    row(second, prompt: 200, generated: 6, prefill: 10000, decode: 1000, decoded: 5),
                    row(first, prompt: 999, generated: 999, prefill: nil, decode: nil, decoded: nil)]
        let result = ThroughputEstimates(records: rows, installed: [first, second], backend: .llamaCPU)
        XCTAssertEqual(result.decode?.modelID, first.id); XCTAssertEqual(result.decode?.tokens, 110)
        XCTAssertEqual(result.decode?.measuredTokensPerSecond, 10)
        XCTAssertEqual(result.prefill?.modelID, second.id); XCTAssertEqual(result.prefill?.measuredTokensPerSecond, 20)
        let decode = try XCTUnwrap(result.decode)
        XCTAssertEqual(decode.predict(weightBytes: 200, backend: .llamaCPU), 5)
        XCTAssertEqual(decode.predict(weightBytes: 50, backend: .llamaCPU), 20)
        XCTAssertNil(decode.predict(weightBytes: 0, backend: .llamaCPU)); XCTAssertNil(decode.predict(weightBytes: -1, backend: .llamaCPU))
        XCTAssertNil(decode.predict(weightBytes: 100, backend: .llamaMetal)); XCTAssertNil(decode.predict(weightBytes: 100, backend: .mlx))
    }
    func testDeletedReplacedPausedAndOtherBackendMeasurementsAreNotReused() {
        let cpu = model(); var metal = cpu; metal.backend = .llamaMetal
        let rows = [row(cpu),row(metal)]
        XCTAssertNotNil(ThroughputEstimates(records: rows, installed: [metal], backend: .llamaCPU).decode)
        XCTAssertEqual(ThroughputEstimates(records: rows, installed: [metal], backend: .llamaMetal).decode?.backend, .llamaMetal)
        XCTAssertNil(ThroughputEstimates(records: [row(cpu)], installed: [metal], backend: .llamaMetal).decode)
        XCTAssertNil(ThroughputEstimates(records: rows, installed: [], backend: .llamaCPU).decode)
        var changed = cpu; changed.files[0].sha256 = String(repeating: "b", count: 64)
        XCTAssertNil(ThroughputEstimates(records: rows, installed: [changed], backend: .llamaCPU).decode)
        changed = cpu; changed.files[0].bytes = 200
        XCTAssertNil(ThroughputEstimates(records: rows, installed: [changed], backend: .llamaCPU).prefill)
        changed = cpu; changed.state = .paused
        XCTAssertNil(ThroughputEstimates(records: rows, installed: [changed], backend: .llamaCPU).decode)
    }
    func testLegacyLedgerReopensWithoutBackfillingWeightIdentity() async throws {
        let model = model(), old = row(model, known: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("usage.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String:Any])
        object.removeValue(forKey: "weights")
        let legacy = try JSONSerialization.data(withJSONObject: ["version":1,"records":[object]])
        try legacy.write(to: file)
        let store = try UsageStore(file: file), rows = await store.list()
        XCTAssertEqual(rows, [old]); XCTAssertEqual(try Data(contentsOf: file), legacy)
        XCTAssertEqual(UsageSummary(records: rows).totals.decodeTokensPerSecond, 10)
        XCTAssertNil(ThroughputEstimates(records: rows, installed: [model], backend: .llamaCPU).decode)
        let measured = row(model); try await store.record(measured)
        let reopened = try UsageStore(file: file), durable = await reopened.list()
        XCTAssertEqual(durable, [old, measured]); XCTAssertEqual(ThroughputEstimates(records: durable, installed: [model], backend: .llamaCPU).decode?.tokens, 10)
    }
    func testUnknownZeroInvalidAndNonfiniteIntervalsDoNotProduceRates() {
        let model = model()
        let rows = [row(model, prefill: nil, decode: nil, decoded: nil), row(model, prompt: 0, generated: 1, prefill: 0, decode: 0, decoded: 0),
                    row(model, generated: 1, decode: 1000, decoded: 5), row(model, prompt: 1, generated: 2, prefill: 1e-300, decode: 1e-300, decoded: 1)]
        let result = ThroughputEstimates(records: rows, installed: [model], backend: .llamaCPU)
        // A tiny positive interval remains a finite measurement. A truly overflowing
        // rate must be omitted rather than becoming a confident UI prediction.
        XCTAssertNotNil(result.decode)
        let overflow = row(model, prompt: 1, generated: 2, prefill: Double.leastNonzeroMagnitude, decode: Double.leastNonzeroMagnitude, decoded: 1)
        let rejected = ThroughputEstimates(records: [overflow], installed: [model], backend: .llamaCPU)
        XCTAssertNil(rejected.prefill); XCTAssertNil(rejected.decode)
        XCTAssertNil(ThroughputEstimates(records: Array(rows.prefix(3)), installed: [model], backend: .llamaCPU).decode)
    }
    func testInvalidPersistedWeightMetadataPreservesLedger() async throws {
        let model = model(), original = row(model)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json"), store = try UsageStore(file: file)
        try await store.record(original); let originalBytes = try Data(contentsOf: file)
        var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        bad["id"] = UUID().uuidString; bad["weights"] = ["bytes": -1, "manifestSHA256": String(repeating: "a", count: 64)]
        let record = try JSONDecoder().decode(UsageRecord.self, from: JSONSerialization.data(withJSONObject: bad))
        do { try await store.record(record); XCTFail("Invalid weight metadata accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        let corrupted = try JSONSerialization.data(withJSONObject: ["version":1,"records":[bad]])
        try corrupted.write(to: file); XCTAssertThrowsError(try UsageStore(file: file)); XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }
    func testCalibrationSourcesRequirePresentWeightFilesWithMatchingByteCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var model = model(backend: .mlx)
        model.files[0].path = "model.safetensors"
        let directory = root.appendingPathComponent(model.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("model.safetensors"), inspector = ModelStorageInspector()
        try Data(repeating: 1, count: 100).write(to: file)
        try Data(repeating: 2, count: 20).write(to: directory.appendingPathComponent("staging"))
        let present = try await inspector.snapshot(root: root, models: [model])
        XCTAssertEqual(present.rows[0].weights?.bytes, 100); XCTAssertEqual(present.modelsWithKnownWeights([model]), [model])
        var replaced = model; replaced.files[0].sha256 = String(repeating: "b", count: 64)
        XCTAssertTrue(present.modelsWithKnownWeights([replaced]).isEmpty)
        try Data(repeating: 1, count: 99).write(to: file)
        let truncated = try await inspector.snapshot(root: root, models: [model])
        XCTAssertNil(truncated.rows[0].weights); XCTAssertTrue(truncated.modelsWithKnownWeights([model]).isEmpty)
        try FileManager.default.removeItem(at: file)
        let missing = try await inspector.snapshot(root: root, models: [model])
        XCTAssertNil(missing.rows[0].weights); XCTAssertTrue(missing.modelsWithKnownWeights([model]).isEmpty)
    }
    func testLegacyMetalPromptTimingIsExcludedWithoutDroppingDecodeOrTokens() throws {
        let metal = model(backend: .llamaMetal), old = row(metal)
        let summary = UsageSummary(records: [old])
        XCTAssertEqual(summary.incompleteMetalTimingPasses, 1); XCTAssertEqual(summary.totals.generatedTokens, 11)
        XCTAssertEqual(summary.totals.promptTokens, 20); XCTAssertEqual(summary.totals.decodeTokensPerSecond, 10)
        XCTAssertNil(summary.totals.prefillTokensPerSecond); XCTAssertEqual(summary.totals.inferenceMilliseconds, 0)
        XCTAssertNil(ThroughputEstimates(records: [old], installed: [metal], backend: .llamaMetal).prefill)
        XCTAssertEqual(ThroughputEstimates(records: [old], installed: [metal], backend: .llamaMetal).decode?.measuredTokensPerSecond, 10)
        var metrics = old.measurements; metrics.prefillIncludesCompute = true
        let corrected = UsageRecord(modelID: metal.id, modelName: metal.name, backend: .llamaMetal, measurements: metrics, weights: old.weights)
        let combined = UsageSummary(records: [old,corrected])
        XCTAssertEqual(combined.incompleteMetalTimingPasses, 1); XCTAssertEqual(combined.totals.generatedTokens, 22)
        XCTAssertEqual(combined.totals.inferenceMilliseconds, 2000); XCTAssertEqual(combined.totals.prefillTokensPerSecond, 20)
        XCTAssertEqual(ThroughputEstimates(records: [old,corrected], installed: [metal], backend: .llamaMetal).prefill?.tokens, 20)
        let encoded = try JSONEncoder().encode(corrected), reopened = try JSONDecoder().decode(UsageRecord.self, from: encoded)
        XCTAssertEqual(reopened, corrected)
    }
}
