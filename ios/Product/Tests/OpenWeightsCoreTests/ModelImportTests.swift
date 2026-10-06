import Darwin
import XCTest
@testable import OpenWeightsCore

final class ModelImportTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testOwnedCopyHasVerifiedBytesAndSurvivesSourceDeletion() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.gguf"), owned = root.appendingPathComponent("owned.gguf")
        let data = Data("GGUF".utf8) + Data(repeating: 7, count: 2 * 1024 * 1024 + 37)
        try data.write(to: source)
        let imported = try await ModelImport.copyGGUF(from: source, to: owned, access: .coordinated)
        XCTAssertEqual(imported.bytes, Int64(data.count))
        XCTAssertEqual(imported.sha256, try ModelFileTransfer.hash(source))
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: owned), data)
        try ModelFileTransfer.verify(owned, file: ModelFile(path: owned.lastPathComponent, bytes: imported.bytes, sha256: imported.sha256))
    }
    func testRefusesBadMagicLinksFoldersAndFIFOWithoutOwnedCopy() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.gguf"), bad = root.appendingPathComponent("bad.gguf")
        try Data("GGUF fixture".utf8).write(to: regular)
        try Data("bad header".utf8).write(to: bad)
        let link = root.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let directory = root.appendingPathComponent("folder.gguf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fifo = root.appendingPathComponent("fifo.gguf")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        let owned = root.appendingPathComponent("owned.gguf")
        for source in [bad, link, directory, fifo] {
            do {
                _ = try await ModelImport.copyGGUF(from: source, to: owned, access: .coordinated)
                XCTFail("Invalid import was accepted: " + source.lastPathComponent)
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        }
    }
    func testExistingDestinationAndDestinationLinkArePreserved() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.gguf"), original = root.appendingPathComponent("original")
        try Data("GGUF fixture".utf8).write(to: source)
        try Data("keep this".utf8).write(to: original)
        let link = root.appendingPathComponent("owned.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        for target in [original, link] {
            do { _ = try await ModelImport.copyGGUF(from: source, to: target); XCTFail("Existing destination was replaced.") }
            catch {}
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("keep this".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), original.path)
    }
    func testCoordinatedImportWaitsForWriterAndCopiesItsCompletedContent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.gguf"), owned = root.appendingPathComponent("owned.gguf")
        try Data("GGUF original".utf8).write(to: source)
        let held = expectation(description: "Writer holds source")
        let done = expectation(description: "Writer finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let updated = Data("GGUF completed replacement".utf8)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forReplacing, error: &error) { url in
                held.fulfill(); release.wait()
                do { try updated.write(to: url, options: .atomic) } catch { XCTFail("Writer failed: \(error)") }
            }
            XCTAssertNil(error); done.fulfill()
        }
        await fulfillment(of: [held], timeout: 3)
        let early = expectation(description: "Import completed before coordinated writer")
        early.isInverted = true
        let reader = Task { () throws -> ImportedModelFile in
            let value = try await ModelImport.copyGGUF(from: source, to: owned, access: .coordinated)
            early.fulfill(); return value
        }
        await fulfillment(of: [early], timeout: 0.15)
        release.signal()
        let value = try await reader.value
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: owned), updated)
        XCTAssertEqual(value.bytes, Int64(updated.count))
    }
    func testCancellationEndsWaitingCoordinationWithoutOwnedCopyAndNextImportRecovers() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.gguf"), owned = root.appendingPathComponent("owned.gguf")
        try Data("GGUF original".utf8).write(to: source)
        let held = expectation(description: "Writer holds source")
        let writerDone = expectation(description: "Writer finished")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forReplacing, error: &error) { _ in
                held.fulfill(); release.wait()
            }
            XCTAssertNil(error); writerDone.fulfill()
        }
        await fulfillment(of: [held], timeout: 3)
        let early = expectation(description: "Import ended before Stop")
        early.isInverted = true
        let finished = expectation(description: "Cancelled import finished")
        let reader = Task { () -> Bool in
            defer { early.fulfill(); finished.fulfill() }
            do { _ = try await ModelImport.copyGGUF(from: source, to: owned, access: .coordinated); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        await fulfillment(of: [early], timeout: 0.15)
        reader.cancel()
        await fulfillment(of: [finished], timeout: 3)
        let cancelled = await reader.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        release.signal()
        await fulfillment(of: [writerDone], timeout: 3)
        let result = try await ModelImport.copyGGUF(from: source, to: owned, access: .coordinated)
        XCTAssertEqual(result.bytes, 13)
    }
}
