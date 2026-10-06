import XCTest
@testable import OpenWeightsCore

final class FileToolsTests: XCTestCase {
    private func fixture() throws -> (URL, Workspace, FileTools, FileToolSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root)
        var settings = FileToolSettings(); settings.enabled = Set(FileToolDefinitions.all.map(\.name))
        return (root, workspace, FileTools(workspace: workspace), settings)
    }
    private func call(_ name: String, _ arguments: String) -> AgentToolCall { AgentToolCall(id: UUID().uuidString, name: name, argumentsJSON: arguments) }
    func testCleanAdditiveWriteThenReadRequiresApprovalForLaterDurableChanges() async throws {
        let (root, _, tools, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let create = call("write_file", "{\"path\":\"note.txt\",\"content\":\"first\"}")
        let first = await tools.execute(create, settings: settings)
        XCTAssertFalse(first.rejected)
        let read = await tools.execute(call("read_file", "{\"path\":\"note.txt\"}"), settings: settings)
        XCTAssertEqual(read.text, "first")
        let rewrite = call("write_file", "{\"path\":\"note.txt\",\"content\":\"second\"}")
        let refused = await tools.execute(rewrite, settings: settings)
        XCTAssertTrue(refused.rejected)
        let approved = await tools.execute(rewrite, settings: settings, approval: ApprovedToolCall(displayedCall: rewrite))
        XCTAssertFalse(approved.rejected)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "second")
    }
    func testForeignReplacementAndDeleteAskEvenInYoloAndConsumeExactTickets() async throws {
        let (root, _, tools, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("user".utf8).write(to: root.appendingPathComponent("user.txt"))
        var settings = initial; settings.mode = .yolo
        let replace = call("write_file", "{\"path\":\"user.txt\",\"content\":\"approved\",\"replace\":true}")
        let ticket = ApprovedToolCall(displayedCall: replace)
        let refused = await tools.execute(replace, settings: settings)
        XCTAssertTrue(refused.rejected)
        let approved = await tools.execute(replace, settings: settings, approval: ticket)
        XCTAssertFalse(approved.rejected)
        let repeated = await tools.execute(replace, settings: settings, approval: ticket)
        XCTAssertTrue(repeated.rejected)
        let different = call("write_file", "{\"path\":\"user.txt\",\"content\":\"wrong\",\"replace\":true}")
        let mismatched = await tools.execute(different, settings: settings, approval: ApprovedToolCall(displayedCall: replace))
        XCTAssertTrue(mismatched.rejected)
        let deletion = call("delete_file", "{\"path\":\"user.txt\"}")
        let unapproved = await tools.execute(deletion, settings: settings)
        XCTAssertTrue(unapproved.rejected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("user.txt").path))
        let deleted = await tools.execute(deletion, settings: settings, approval: ApprovedToolCall(displayedCall: deletion))
        XCTAssertFalse(deleted.rejected)
    }
    func testAskPlanDisabledAndRevokedToolsProduceNoEffect() async throws {
        let (root, workspace, tools, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let create = call("write_file", "{\"path\":\"new.txt\",\"content\":\"new\"}")
        var settings = initial; settings.mode = .ask
        let ask = await tools.execute(create, settings: settings)
        XCTAssertTrue(ask.rejected)
        settings.mode = .plan
        let plan = await tools.execute(create, settings: settings, approval: ApprovedToolCall(displayedCall: create))
        XCTAssertTrue(plan.rejected)
        settings.mode = .auto; settings.enabled.remove("write_file")
        let disabled = await tools.execute(create, settings: settings)
        XCTAssertTrue(disabled.rejected)
        settings = initial
        await workspace.revoke()
        let revoked = await tools.execute(create, settings: settings)
        XCTAssertTrue(revoked.rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
    }
    func testFindAndReadPageArgumentsAndMalformedOffsets() async throws {
        let (root, _, tools, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "a", count: 4001).utf8).write(to: root.appendingPathComponent("notes.md"))
        let found = await tools.execute(call("find_files", "{\"pattern\":\"*.md\"}"), settings: settings)
        XCTAssertTrue(found.text.contains("notes.md"))
        let first = await tools.execute(call("read_file", "{\"path\":\"notes.md\"}"), settings: settings)
        XCTAssertTrue(first.text.contains("offset 4000"))
        let second = await tools.execute(call("read_file", "{\"path\":\"notes.md\",\"offset\":4000}"), settings: settings)
        XCTAssertEqual(second.text, "a")
        for offset in ["true", "-1", "0.5", "1e100"] {
            let bad = await tools.execute(call("read_file", "{\"path\":\"notes.md\",\"offset\":\(offset)}"), settings: settings)
            XCTAssertTrue(bad.rejected)
        }
    }
    func testNewTurnClearsTaintButDoesNotRestoreLostSessionOwnership() async throws {
        let (root, workspace, tools, settings) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let create = call("write_file", "{\"path\":\"scratch.txt\",\"content\":\"new\"}")
        _ = await tools.execute(create, settings: settings)
        _ = await tools.execute(call("read_file", "{\"path\":\"scratch.txt\"}"), settings: settings)
        await tools.beginTurn()
        let deletion = call("delete_file", "{\"path\":\"scratch.txt\"}")
        let own = await tools.requiresApproval(deletion, mode: .auto)
        XCTAssertFalse(own)
        await workspace.clearSessionArtifacts()
        let foreign = await tools.requiresApproval(deletion, mode: .auto)
        XCTAssertTrue(foreign)
        await tools.beginTurn(carriesUntrustedText: true)
        let additive = call("write_file", "{\"path\":\"new.txt\",\"content\":\"new\"}")
        let tainted = await tools.requiresApproval(additive, mode: .yolo)
        XCTAssertTrue(tainted)
    }
}
