import XCTest
@testable import OpenWeightsCore

final class ModelSettingsTests: XCTestCase {
    private func model(_ name: String, context: Int = 2048, threads: Int = 4) -> LocalModel {
        var value = LocalModel(name: name, backend: .llamaCPU, entryFile: "model.gguf", files: [ModelFile(path: "model.gguf")])
        value.settings.contextTokens = context; value.settings.threads = threads
        return value
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testLegacyPreferencesStaySeparateUntilExplicitSettingsSave() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("models.json")
        var a = model("A"), b = model("B", context: 4096, threads: 2)
        a.settings.temperature = 0.2; b.settings.temperature = 0.9
        let encoded = try JSONEncoder().encode([a, b])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for index in legacy.indices {
            var settings = try XCTUnwrap(legacy[index]["settings"] as? [String: Any])
            settings.removeValue(forKey: "topK"); settings.removeValue(forKey: "minP")
            legacy[index]["settings"] = settings
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "models": legacy]).write(to: file)
        let library = try ModelLibrary(file: file)
        let before = await library.list()
        XCTAssertEqual(before.first { $0.id == a.id }?.settings.temperature, 0.2)
        XCTAssertEqual(before.first { $0.id == b.id }?.settings.temperature, 0.9)
        XCTAssertTrue(before.allSatisfy { $0.settings.topK == nil && $0.settings.minP == nil })
        a.settings.topK = 17; a.settings.minP = 0.2
        try await library.saveSettings(a)
        let reopened = try ModelLibrary(file: file), after = await reopened.list()
        XCTAssertTrue(after.allSatisfy { $0.settings.temperature == 0.2 && $0.settings.topK == 17 && $0.settings.minP == 0.2 })
        XCTAssertEqual(after.first { $0.id == b.id }?.settings.contextTokens, 4096)
        XCTAssertEqual(after.first { $0.id == b.id }?.settings.threads, 2)
    }

    func testGenerationIsSharedButContextThreadsAndBackendRemainModelSpecific() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json"), library = try ModelLibrary(file: file)
        var a = model("A", context: 8192, threads: 6), b = model("B", context: 4096, threads: 2)
        b.backend = .llamaMetal
        try await library.save(a); try await library.save(b)
        a.settings.outputTokens = 1024; a.settings.temperature = 0; a.settings.topP = 0.8
        a.settings.topK = 0; a.settings.minP = 0; a.settings.repeatPenalty = 1.2; a.settings.thinking = true
        try await library.saveSettings(a)
        let reopened = try ModelLibrary(file: file), values = await reopened.list()
        let savedB = try XCTUnwrap(values.first { $0.id == b.id })
        XCTAssertEqual(savedB.settings, b.settings.sharingGeneration(from: a.settings))
        XCTAssertEqual(savedB.backend, .llamaMetal)
        try await reopened.delete(a.id)
        let c = model("C")
        try await reopened.save(c)
        let second = try ModelLibrary(file: file), remaining = await second.list()
        XCTAssertEqual(remaining.first { $0.id == c.id }?.settings.temperature, 0)
        XCTAssertEqual(remaining.first { $0.id == c.id }?.settings.contextTokens, 2048)
        XCTAssertEqual(remaining.first { $0.id == c.id }?.settings.minP, 0)
    }

    func testDownloadStateWritesCannotOverwriteGenerationAndStaleSettingsCannotRewindState() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = try ModelLibrary(file: directory.appendingPathComponent("models.json"))
        var a = model("A"), b = model("B")
        try await library.save(a); try await library.save(b)
        a.settings.temperature = 0.3; try await library.saveSettings(a)
        b.state = .ready; try await library.save(b)
        let updated = await library.list()
        XCTAssertEqual(updated.first { $0.id == b.id }?.settings.temperature, 0.3)
        var stale = b; stale.state = .downloading; stale.settings.temperature = 0.4
        try await library.saveSettings(stale)
        let after = await library.list()
        XCTAssertEqual(after.first { $0.id == b.id }?.state, .ready)
        XCTAssertTrue(after.allSatisfy { $0.settings.temperature == 0.4 })
    }

    func testSharedOutputBudgetCanRefuseSmallerExportWithoutBlockingDownloadManagement() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json"), library = try ModelLibrary(file: file)
        var a = model("A", context: 8192), b = model("B")
        b.backend = .xnnpack
        try await library.save(a); try await library.save(b)
        a.settings.outputTokens = 2048; try await library.saveSettings(a)
        let initial = await library.list()
        var effective = try XCTUnwrap(initial.first { $0.id == b.id })
        XCTAssertThrowsError(try effective.settings.validate(for: .xnnpack))
        effective.state = .paused; try await library.save(effective)
        let reopened = try ModelLibrary(file: file), saved = await reopened.list()
        XCTAssertEqual(saved.first { $0.id == b.id }?.state, .paused)
        effective.settings.outputTokens = 512; try await reopened.saveSettings(effective)
        let repaired = await reopened.list()
        XCTAssertTrue(repaired.allSatisfy { $0.settings.outputTokens == 512 })
        try XCTUnwrap(repaired.first { $0.id == b.id }).settings.validate(for: .xnnpack)
    }

    func testInvalidSettingsRefuseBeforeChangingDurableModelOrSharedPreferences() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json"), library = try ModelLibrary(file: file)
        let original = model("A"); try await library.save(original)
        let before = try Data(contentsOf: file)
        let mutations: [(inout ModelSettings) -> Void] = [
            { $0.temperature = .infinity }, { $0.temperature = -1 }, { $0.topP = .nan }, { $0.topP = 1.1 },
            { $0.minP = .nan }, { $0.minP = -0.1 }, { $0.minP = 1.1 }, { $0.topK = -1 },
            { $0.topK = Int(Int32.max) + 1 }, { $0.repeatPenalty = 0 }, { $0.repeatPenalty = 1e-300 },
            { $0.outputTokens = $0.contextTokens }, { $0.contextTokens = 127 }, { $0.threads = 0 }
        ]
        for mutation in mutations {
            var bad = original; mutation(&bad.settings)
            do { try await library.saveSettings(bad); XCTFail("Invalid settings were accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), before)
            let current = await library.list(); XCTAssertEqual(current, [original])
        }
    }

    func testExperimentalCompiledMLXBackendPersistsAndKeepsItsExportWindow() async throws {
        let directory=root();defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("models.json"),library=try ModelLibrary(file:file)
        var value=LocalModel(name:"Compiled MLX",backend:.executorchMLX,entryFile:"model.pte",files:[ModelFile(path:"model.pte")],family:"qwen3")
        value.state = .ready;try await library.save(value)
        let restored=await (try ModelLibrary(file:file)).list();XCTAssertEqual(restored,[value])
        value.settings.contextTokens=4096
        XCTAssertThrowsError(try value.settings.validate(for:.executorchMLX))
        value.settings.contextTokens=2048;try value.settings.validate(for:.executorchMLX)
        value.settings.temperature = .nan;XCTAssertThrowsError(try value.settings.validate(for:.executorchMLX))
    }
    func testCompiledWindowAndDeletedModelRefuseSettingsSave() async throws {
        var settings = ModelSettings(); settings.contextTokens = 4096
        XCTAssertThrowsError(try settings.validate(for: .xnnpack))
        try settings.validate(for: .mlx)
        settings.contextTokens = 2048; settings.temperature = 0; settings.topK = 0; settings.minP = 0
        try settings.validate(for: .xnnpack)
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("models.json"), library = try ModelLibrary(file: file)
        let a = model("A"); try await library.save(a); try await library.delete(a.id)
        let before = try Data(contentsOf: file)
        do { try await library.saveSettings(a); XCTFail("Deleted model was resurrected") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
}
