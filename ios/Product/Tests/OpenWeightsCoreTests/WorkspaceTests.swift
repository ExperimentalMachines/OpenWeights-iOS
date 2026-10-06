import XCTest
@testable import OpenWeightsCore

final class WorkspaceTests: XCTestCase {
    private func fixture() throws -> (URL, Workspace) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try Workspace(root: root))
    }
    private func refuses(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("The operation should have been refused", file: file, line: line) }
        catch {}
    }
    func testTraversalAndSymlinkEscapeDoNotReadOrWriteOutsideGrant() async throws {
        let (root, workspace) = try fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("secret.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        for path in ["../secret.txt", "/etc/passwd", "a/../b", "a//b", "a/./b", "file:///secret", "C:\\secret", "a\0b", "escape/secret.txt", "secret.txt"] {
            await refuses { _ = try await workspace.read(path) }
            await refuses { try await workspace.write(path, content: "changed", replace: true) }
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret.txt"), encoding: .utf8), "private")
        let result = try await workspace.find(pattern: "*")
        XCTAssertTrue(result.paths.isEmpty)
    }
    func testCreateReplacementAndSessionOwnershipProtectExistingFiles() async throws {
        let (root, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("user.txt"))
        await refuses { try await workspace.write("user.txt", content: "bad") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("user.txt"), encoding: .utf8), "original")
        try await workspace.write("user.txt", content: "approved", replace: true)
        let ownsUser = await workspace.isSessionOwned("user.txt")
        XCTAssertFalse(ownsUser)
        try await workspace.write("notes/scratch.txt", content: "first")
        try await workspace.write("notes/scratch.txt", content: "second")
        let ownsScratch = await workspace.isSessionOwned("notes/scratch.txt")
        XCTAssertTrue(ownsScratch)
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes/scratch.txt"))
        try Data("external".utf8).write(to: root.appendingPathComponent("notes/scratch.txt"))
        let ownsReplacement = await workspace.isSessionOwned("notes/scratch.txt")
        XCTAssertFalse(ownsReplacement)
        await refuses { try await workspace.write("notes/scratch.txt", content: "bad") }
        try await workspace.write("fresh.txt", content: "new")
        await workspace.clearSessionArtifacts()
        await refuses { try await workspace.write("fresh.txt", content: "needs approval") }
        await refuses { try await workspace.write("oversize.txt", content: String(repeating: "🧠", count: 1001)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("oversize.txt").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".openweights-") }))
    }
    func testPagedUTF8UsesUTF16OffsetsAndRefusesBinaryAndSpecialFiles() async throws {
        let (root, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "é", count: 4000) + "🧠" + "tail"
        try Data(text.utf8).write(to: root.appendingPathComponent("long.txt"))
        let first = try await workspace.read("long.txt")
        let second = try await workspace.read("long.txt", offset: first.nextOffset!)
        XCTAssertEqual(first.text + second.text, text)
        XCTAssertNil(second.nextOffset)
        let boundary = String(repeating: "a", count: 3999) + "🧠tail"
        try Data(boundary.utf8).write(to: root.appendingPathComponent("boundary.txt"))
        let page = try await workspace.read("boundary.txt")
        XCTAssertEqual(page.nextOffset, 3999)
        let continuation = try await workspace.read("boundary.txt", offset: page.nextOffset!)
        XCTAssertEqual(page.text + continuation.text, boundary)
        await refuses { _ = try await workspace.read("boundary.txt", offset: 4000) }
        let splitBytes = String(repeating: "a", count: 8191) + "é🧠tail"
        try Data(splitBytes.utf8).write(to: root.appendingPathComponent("bytes.txt"))
        let splitWindow = try await workspace.read("bytes.txt", offset: 8191)
        XCTAssertEqual(splitWindow.text, "é🧠tail")
        let beyond = try await workspace.read("long.txt", offset: Int.max)
        XCTAssertEqual(beyond.text, "")
        await refuses { _ = try await workspace.read("long.txt", offset: -1) }
        try Data([0xff, 0, 1]).write(to: root.appendingPathComponent("binary"))
        await refuses { _ = try await workspace.read("binary") }
        await refuses { _ = try await workspace.read(".") }
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        await refuses { _ = try await workspace.read("pipe") }
    }
    func testSearchReportsBudgetAndGlobMatchesOneCharacter() async throws {
        let (root, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 { try Data("Birch port".utf8).write(to: root.appendingPathComponent("note\(index).md")) }
        let first = try await workspace.find(pattern: "*.md")
        XCTAssertEqual(first.paths.count, 10); XCTAssertTrue(first.partial)
        let again = try await workspace.find(pattern: "note?.md", contains: "BIRCH")
        XCTAssertEqual(again.paths.count, 10)
        XCTAssertFalse(Workspace.matches("note10.md", pattern: "note?.md"))
        XCTAssertTrue(Workspace.matches("Notes.MD", pattern: "notes"))
        let missing = try await workspace.find(pattern: "*.json")
        XCTAssertTrue(missing.paths.isEmpty); XCTAssertFalse(missing.partial)
    }
    func testRevocationReadOnlyAndRenamedRootKeepTheGrantBoundary() async throws {
        let (root, workspace) = try fixture()
        let renamed = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: renamed) }
        try Data("granted".utf8).write(to: root.appendingPathComponent("note.txt"))
        try FileManager.default.moveItem(at: root, to: renamed)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ungranted replacement".utf8).write(to: root.appendingPathComponent("note.txt"))
        let window = try await workspace.read("note.txt")
        XCTAssertEqual(window.text, "granted")
        await workspace.revoke()
        await refuses { _ = try await workspace.read("note.txt") }
        await refuses { try await workspace.write("note.txt", content: "bad", replace: true) }
        let readOnly = try Workspace(root: renamed, writable: false)
        await refuses { try await readOnly.write("new.txt", content: "bad") }
        await refuses { try await readOnly.delete("note.txt") }
    }
    func testRecursiveDeleteUnlinksSymlinksWithoutTouchingTheirTargets() async throws {
        let (root, workspace) = try fixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try await workspace.write("scratch/nested/a.txt", content: "delete")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("scratch/link"), withDestinationURL: outside)
        try await workspace.delete("scratch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch").path))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8), "keep")
    }
    func testCoordinatedAccessChecksDirectoryIdentityAndRevocation() async throws {
        let (root, _) = try fixture()
        let moved = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let workspace = try Workspace(root: root, access: .coordinated)
        try await workspace.write("note.txt", content: "granted")
        let result = try await workspace.read("note.txt")
        XCTAssertEqual(result.text, "granted")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("different folder".utf8).write(to: root.appendingPathComponent("note.txt"))
        await refuses { _ = try await workspace.read("note.txt") }
        await refuses { try await workspace.write("note.txt", content: "bad", replace: true) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "different folder")
        await workspace.revoke()
        await refuses { _ = try await workspace.find(pattern: "*") }
    }
    func testStopBeforeOperationPreservesFilesAndNextTurnRecovers() async throws {
        let (root, workspace) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await workspace.write("note.txt", content: "original")
        workspace.cancel()
        await refuses { try await workspace.write("note.txt", content: "bad", replace: true) }
        await refuses { try await workspace.delete("note.txt") }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "original")
        await workspace.prepareTurn()
        try await workspace.write("note.txt", content: "recovered", replace: true)
        let result = try await workspace.read("note.txt")
        XCTAssertEqual(result.text, "recovered")
    }
    func testChildReadWaitsForCoordinatedWriterAndStopCancelsTheWait() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: file)
        let workspace = try Workspace(root: root, access: .coordinated)
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &error) { _ in
                acquired.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            writerDone.signal()
        }
        defer { release.signal() }
        let writerAcquired = await Task.detached { acquired.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(writerAcquired)
        guard writerAcquired else { return }
        let early = expectation(description: "Child read finished before writer released it")
        early.isInverted = true
        let finished = expectation(description: "Cancelled child read finished")
        let result = LockedWorkspaceRead()
        let reader = Task {
            do { _ = try await workspace.read("note.txt"); result.record(succeeded: true) }
            catch { result.record(succeeded: false) }
            early.fulfill(); finished.fulfill()
        }
        await fulfillment(of: [early], timeout: 0.15)
        workspace.cancel()
        await fulfillment(of: [finished], timeout: 3)
        await reader.value
        XCTAssertEqual(result.succeeded, false, "The cancelled coordination wait returned file contents.")
        release.signal()
        let released = await Task.detached { writerDone.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(released)
        await workspace.prepareTurn()
        let recovered = try await workspace.read("note.txt")
        XCTAssertEqual(recovered.text, "original")
    }
}

private final class LockedWorkspaceRead: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    var succeeded: Bool? { lock.withLock { value } }
    func record(succeeded: Bool) { lock.withLock { value = succeeded } }
}
