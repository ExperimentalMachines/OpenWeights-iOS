import XCTest
@testable import OpenWeightsCore

final class ModelLibraryTests: XCTestCase {
    func testContainerAliasWithMissingFinalFile() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
        XCTAssertEqual(try ModelFile(path: "Models/model.gguf").destination(in: root), root.appendingPathComponent("Models/model.gguf"))
    }
    func testPathContainmentIncludesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        for name in ["../model.gguf", "/model.gguf", "folder//model", "folder/./model", "escape/model", "folder\\model", "folder:model", "model\0"] {
            XCTAssertThrowsError(try ModelFile(path: name).destination(in: root), name)
        }
        XCTAssertEqual(try ModelFile(path: "xnnpack/model.pte").destination(in: root), root.appendingPathComponent("xnnpack/model.pte"))
    }
    func testSettingsAndPausedDownloadSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("models.json")
        let library = try ModelLibrary(file: file)
        var model = LocalModel(name: "Qwen", backend: .llamaCPU, entryFile: "model.gguf", files: [ModelFile(path: "model.gguf")])
        model.state = .paused; model.settings.contextTokens = 4096; model.settings.thinking = true
        try await library.save(model)
        let reopened = try ModelLibrary(file: file)
        let models = await reopened.list()
        XCTAssertEqual(models, [model])
        try await reopened.delete(model.id)
        let empty = try ModelLibrary(file: file)
        let remaining = await empty.list()
        XCTAssertTrue(remaining.isEmpty)
    }
}
