import Foundation
import XCTest
@testable import OpenWeightsCore

final class ModelDownloadArrivalTests: XCTestCase {
    func testMultipleJournalsRecoverByRangeRatherThanFilenameOrder() throws {
        let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (owner, offset, text) in [("00000000-0000-0000-0000-000000000001", Int64(3), "def"),
                                     ("00000000-0000-0000-0000-000000000002", 0, "abc")] {
            let temporary = root.appendingPathComponent(UUID().uuidString); try Data(text.utf8).write(to: temporary)
            _ = try ModelDownloadArrival.stage(temporary, directory: root, owner: UUID(uuidString: owner)!, modelID: model.id,
                filePath: model.entryFile, requestURL: url, offset: offset, status: 206,
                contentRange: "bytes \(offset)-\(offset + 2)/6")
        }
        try Data("ab".utf8).write(to: destination.appendingPathExtension("partial"))
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 2)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
        try ModelFileTransfer.verify(destination, file: model.files[0])
    }
    private func fixture() throws -> (URL, LocalModel, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = root.appendingPathComponent("seed"); try Data("abcdef".utf8).write(to: seed)
        let url = URL(string: "https://huggingface.co/fixture/model/resolve/pin/model.gguf")!
        let file = ModelFile(path: "nested/model.gguf", bytes: 6, sha256: try ModelFileTransfer.hash(seed), url: url)
        let model = LocalModel(name: "Recovery fixture", backend: .llamaCPU, entryFile: file.path, files: [file])
        return (root, model, try file.destination(in: root), url)
    }
    private func stage(root: URL, model: LocalModel, url: URL, owner: UUID = UUID(), path: String? = nil, modelID: UUID? = nil) throws -> URL {
        let incoming = root.appendingPathComponent("temporary-" + UUID().uuidString); try Data("abcdef".utf8).write(to: incoming)
        return try ModelDownloadArrival.stage(incoming, directory: root, owner: owner, modelID: modelID ?? model.id,
            filePath: path ?? model.entryFile, requestURL: url, offset: 0, status: 206, contentRange: "bytes 0-5/6")
    }
    func testJournalRecoversFullNestedArrivalAfterIndependentRestore() throws {
        let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let body = try stage(root: root, model: model, url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.deletingPathExtension().appendingPathExtension("json").path))
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 1)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.deletingPathExtension().appendingPathExtension("json").path))
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 0)
    }
    func testJournalRecoversHalfWrittenAndFullyWrittenPrefixExactly() throws {
        for prefix in ["abc", "abcdef"] {
            let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try stage(root: root, model: model, url: url)
            try Data(prefix.utf8).write(to: destination.appendingPathExtension("partial"))
            XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 1)
            XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
        }
    }
    func testMovedCompleteBodyBeforeJournalCleanupVerifiesExistingDestination() throws {
        let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let body = try stage(root: root, model: model, url: url)
        try FileManager.default.moveItem(at: body, to: destination)
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 1)
        try ModelFileTransfer.verify(destination, file: model.files[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.deletingPathExtension().appendingPathExtension("json").path))
    }
    func testCurrentProcessStageCannotBeStolenByBootstrap() throws {
        let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = UUID(), body = try stage(root: root, model: model, url: url, owner: owner)
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: owner), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 1)
    }
    func testWrongIdentityCannotWriteAndManifestIsDiscarded() throws {
        for variant in 0..<3 {
            let (root, model, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let body = try stage(root: root, model: model,
                url: variant == 0 ? URL(string: "https://huggingface.co/fixture/other")! : url,
                path: variant == 1 ? "unknown.gguf" : nil, modelID: variant == 2 ? UUID() : nil)
            XCTAssertThrowsError(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: body.deletingPathExtension().appendingPathExtension("json").path))
        }
    }
    func testPausedAndReadyModelsDiscardForeignArrivalWithoutChangingCheckpoint() throws {
        for state in [LocalModel.State.paused, .ready] {
            let (root, original, destination, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = try stage(root: root, model: original, url: url)
            try Data("abc".utf8).write(to: destination.appendingPathExtension("partial"))
            var model = original; model.state = state
            XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: UUID()), 0)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathExtension("partial")), Data("abc".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
    func testLegacyAndUnpublishedOrphansAreRemovedWhileCurrentOwnerAndModelFileStay() throws {
        let (root, original, _, url) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("arrival-" + UUID().uuidString); try Data("orphan".utf8).write(to: legacy)
        let legitimateName = "arrival-" + UUID().uuidString, legitimate = root.appendingPathComponent(legitimateName)
        try Data("model-component".utf8).write(to: legitimate)
        var model = original; model.files.append(ModelFile(path: legitimateName))
        let foreign = try stage(root: root, model: model, url: url), owner = UUID()
        let current = try stage(root: root, model: model, url: url, owner: owner)
        for body in [foreign, current] { try FileManager.default.removeItem(at: body.deletingPathExtension().appendingPathExtension("json")) }
        XCTAssertEqual(try ModelDownloadArrival.recover(in: root, model: model, excludingOwner: owner), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: legitimate.path))
    }
    func testRequestIdentityContainsNoQueryCredential() throws {
        let (root, model, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://huggingface.co/fixture/model?credential=synthetic-secret")!
        let body = try stage(root: root, model: model, url: url)
        let data = try Data(contentsOf: body.deletingPathExtension().appendingPathExtension("json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-secret"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(url.absoluteString))
    }
}
