import XCTest
@testable import OpenWeightsCore

final class ModelFileTransferTests: XCTestCase {
    func testMultiChunkHashesMatchIndependentSHAAndGitReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("multi-chunk.bin")
        try Data(repeating:0xa5,count:8 * 1024 * 1024 + 3).write(to:url)
        // Independent Python hashlib references include the final short chunk and Git header.
        let file = ModelFile(path:"multi-chunk.bin",bytes:8 * 1024 * 1024 + 3,
            sha256:"6f696b08dce2c971d10219bed01c44dd01bd5ec320496ad542f9e435ff2666b8",gitBlobSHA1:"fc46a3ee784ba77aa84a987b12aef18c270b61c1")
        try ModelFileTransfer.verify(url,file:file)
        let output = try FileHandle(forWritingTo:url)
        defer { try? output.close() }
        try output.seekToEnd(); try output.seek(toOffset:8 * 1024 * 1024 + 2)
        try output.write(contentsOf:Data([0xa4])); try output.synchronize()
        XCTAssertThrowsError(try ModelFileTransfer.verify(url,file:file))
        var gitOnly = file; gitOnly.sha256 = nil
        XCTAssertThrowsError(try ModelFileTransfer.verify(url,file:gitOnly))
    }

    func testInterruptedPrefixRecoveryCompletesWithoutDuplicateBytes() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: destination.appendingPathExtension("partial"))
        try ModelFileTransfer.recoverChunk(arrival("abcdef", root: root), destination: destination,
            status: 206, contentRange: "bytes 0-5/6", offset: 0, file: file)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
        try ModelFileTransfer.verify(destination, file: file)
    }
    func testRecoveredEarlierRangeDoesNotAppendAgainOverLaterCheckpoint() throws {
        let (root, destination, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = destination.appendingPathExtension("partial")
        try Data("abcdef".utf8).write(to: partial)
        let file = ModelFile(path: "model", bytes: 9)
        try ModelFileTransfer.recoverChunk(arrival("abc", root: root), destination: destination,
            status: 206, contentRange: "bytes 0-2/9", offset: 0, file: file)
        XCTAssertEqual(try Data(contentsOf: partial), Data("abcdef".utf8))
        try ModelFileTransfer.commitChunk(arrival("ghi", root: root), destination: destination,
            status: 206, contentRange: "bytes 6-8/9", offset: 6, file: file)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdefghi".utf8))
    }
    func testRecoveryRefusesMismatchedWrittenPrefixWithoutChangingCheckpoint() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = destination.appendingPathExtension("partial")
        try Data("axx".utf8).write(to: partial)
        XCTAssertThrowsError(try ModelFileTransfer.recoverChunk(arrival("abcdef", root: root), destination: destination,
            status: 206, contentRange: "bytes 0-5/6", offset: 0, file: file))
        XCTAssertEqual(try Data(contentsOf: partial), Data("axx".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testPublishedGitObjectChecksumIncludesHeaderAndRejectsSameSizeCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let destination = root.appendingPathComponent("tokenizer.json")
        let file = ModelFile(path:"tokenizer.json",bytes:6,gitBlobSHA1:"ce013625030ba8dba906f756967f9e9ca394464a")
        let data = Data("hello\n".utf8)
        try ModelFileTransfer.verify(data,file:file)
        XCTAssertThrowsError(try ModelFileTransfer.verify(Data("jello\n".utf8),file:file))
        try ModelFileTransfer.commitChunk(arrival("hel",root:root),destination:destination,status:206,contentRange:"bytes 0-2/6",offset:0,file:file)
        XCTAssertThrowsError(try ModelFileTransfer.commitChunk(arrival("lo!",root:root),destination:destination,status:206,contentRange:"bytes 3-5/6",offset:3,file:file))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:destination.appendingPathExtension("partial").path))
        try ModelFileTransfer.commitChunk(arrival("hello\n",root:root),destination:destination,status:200,contentRange:nil,offset:0,file:file)
        try ModelFileTransfer.verify(destination,file:file)
        try Data("jello\n".utf8).write(to:destination)
        XCTAssertThrowsError(try ModelFileTransfer.verify(destination,file:file))
    }
    private func fixture() throws -> (URL, URL, ModelFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expected = root.appendingPathComponent("expected")
        try Data("abcdef".utf8).write(to: expected)
        return (root, root.appendingPathComponent("model"), ModelFile(path: "model", bytes: 6, sha256: try ModelFileTransfer.hash(expected)))
    }
    private func arrival(_ text: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: file)
        return file
    }
    func testOwnedCheckpointContinuesAcrossIndependentArrivals() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ModelFileTransfer.commitChunk(arrival("abc", root: root), destination: destination, status: 206,
            contentRange: "bytes 0-2/6", offset: 0, file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathExtension("partial")), Data("abc".utf8))
        try ModelFileTransfer.commitChunk(arrival("def", root: root), destination: destination, status: 206,
            contentRange: "bytes 3-5/6", offset: 3, file: file)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }
    func testWrongRangesAndDuplicateArrivalLeaveCheckpointIntact() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = destination.appendingPathExtension("partial")
        try Data("abc".utf8).write(to: partial)
        for (range, offset, text) in [("bytes 0-2/6", Int64(3), "abc"), ("bytes 3-5/7", 3, "def"),
                                     ("bytes 3-6/6", 3, "defg"), ("bytes 3-5/6", 3, "de"),
                                     ("bytes 0-2/6", 0, "abc"), ("bytes 3-5/*", 3, "def")] {
            XCTAssertThrowsError(try ModelFileTransfer.commitChunk(arrival(text, root: root), destination: destination,
                status: 206, contentRange: range, offset: offset, file: file), range)
            XCTAssertEqual(try Data(contentsOf: partial), Data("abc".utf8))
        }
    }
    func testHashFailureDiscardsCompleteCorruptCheckpointAndAllowsRetry() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ModelFileTransfer.commitChunk(arrival("xxxxxx", root: root), destination: destination,
            status: 206, contentRange: "bytes 0-5/6", offset: 0, file: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
        try ModelFileTransfer.commitChunk(arrival("abcdef", root: root), destination: destination,
            status: 206, contentRange: "bytes 0-5/6", offset: 0, file: file)
        try ModelFileTransfer.verify(destination, file: file)
    }
    func testIgnoredRangeReplacesCheckpointOnlyAfterFullVerification() throws {
        let (root, destination, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = destination.appendingPathExtension("partial")
        try Data("abc".utf8).write(to: partial)
        XCTAssertThrowsError(try ModelFileTransfer.commitChunk(arrival("bad", root: root), destination: destination,
            status: 200, contentRange: nil, offset: 3, file: file))
        XCTAssertEqual(try Data(contentsOf: partial), Data("abc".utf8))
        try ModelFileTransfer.commitChunk(arrival("abcdef", root: root), destination: destination,
            status: 200, contentRange: nil, offset: 3, file: file)
        XCTAssertEqual(try Data(contentsOf: destination), Data("abcdef".utf8))
    }
}
