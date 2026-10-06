import XCTest
import Foundation
import CryptoKit
@testable import OpenWeightsCore

final class ChatAttachmentTests: XCTestCase {
    private func root() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }; return value
    }
    func testOwnedCopySurvivesSourceRemovalAndRefusesChangedBytesAndLinks() async throws {
        let root = try root(), source = root.appendingPathComponent("source.jpg")
        try Data("Fixture bytes for ownership, not an image codec test".utf8).write(to: source)
        let store = try ChatAttachmentStore(root: root.appendingPathComponent("Owned"))
        let attachment = try await store.importFile(source, mediaType: "image/jpeg", kind: .image)
        try FileManager.default.removeItem(at: source)
        let url = try await store.resolve(attachment)
        XCTAssertEqual(url.lastPathComponent, attachment.id.uuidString.lowercased() + ".jpg")
        let reopened = try ChatAttachmentStore(root: root.appendingPathComponent("Owned"))
        let reopenedURL = try await reopened.resolve(attachment); XCTAssertEqual(reopenedURL, url)
        try Data("Changed".utf8).write(to: url)
        do { _ = try await store.resolve(attachment); XCTFail("Changed copy accepted") } catch {}
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root)
        do { _ = try await store.resolve(attachment); XCTFail("Linked copy accepted") } catch {}
        let sourceLink = root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: url)
        do { _ = try await store.importFile(sourceLink, mediaType: "image/jpeg", kind: .image); XCTFail("Source link accepted") } catch {}
    }
    func testBoundedCopyPreservesExistingTargetAndRejectsOversizeWithoutPartialFile() async throws {
        let root = try root(), source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 7, count: 128).write(to: source)
        do { _ = try await AttachmentFileCopy.copy(source, to: target, limit: 64); XCTFail("Oversize accepted") }
        catch AttachmentError.tooLarge(64) {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let original = Data("Keep target".utf8); try original.write(to: target)
        do { _ = try await AttachmentFileCopy.copy(source, to: target, limit: 256); XCTFail("Existing target replaced") } catch {}
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
    func testDocumentWindowReportsTrimmingAndRefusesBinaryBlankAndZeroBudget() async throws {
        let root = try root(), source = root.appendingPathComponent("Cedar.txt")
        let text = "Cedar " + String(repeating: "é", count: 100)
        try Data(text.utf8).write(to: source)
        let document = try await ChatAttachmentStore.readDocument(source, characterLimit: 12)
        XCTAssertEqual(document.text, String(text.prefix(12))); XCTAssertTrue(document.info.wasTrimmed)
        XCTAssertEqual(document.info.name, "Cedar.txt"); XCTAssertEqual(document.info.characters, 12)
        XCTAssertTrue(document.prompt.contains("[cut short: the rest did not fit]"))
        let full = try await ChatAttachmentStore.readDocument(source, characterLimit: 200)
        XCTAssertEqual(full.text, text); XCTAssertFalse(full.info.wasTrimmed)
        for bytes in [Data([0, 1, 255]), Data("  \n ".utf8)] {
            try bytes.write(to: source)
            do { _ = try await ChatAttachmentStore.readDocument(source, characterLimit: 20); XCTFail("Unreadable document accepted") } catch {}
        }
        do { _ = try await ChatAttachmentStore.readDocument(source, characterLimit: 0); XCTFail("Zero budget accepted") } catch {}
    }
    func testAttachmentHistoryBranchFingerprintsAndReferencePruning() async throws {
        let root = try root(), source = root.appendingPathComponent("source.jpg")
        try Data("Immutable reference fixture".utf8).write(to: source)
        let owned = try ChatAttachmentStore(root: root.appendingPathComponent("Owned"))
        let attachment = try await owned.importFile(source, mediaType: "image/jpeg", kind: .image)
        let storeFile = root.appendingPathComponent("conversations.json"), conversations = try ConversationStore(file: storeFile)
        var chat = try await conversations.create(title: "Image")
        var user = StoredMessage(role: .user, content: ""); user.attachments = [attachment]
        let reply = StoredMessage(role: .assistant, content: "Fixture")
        chat.messages = [user, reply]; try await conversations.save(chat)
        let prompt = ConversationContext.promptEntries(chat, system: "System")
        XCTAssertEqual(prompt.count, 3); XCTAssertEqual(prompt[1].attachments, [attachment]); XCTAssertEqual(prompt[1].text["content"], "")
        var noImage = chat; noImage.messages[0].attachments = nil
        XCTAssertNotEqual(ConversationContext.fingerprint(chat.messages[...]), ConversationContext.fingerprint(noImage.messages[...]))
        let branch = try await conversations.branch(chat.id, through: reply.id)
        XCTAssertEqual(branch.messages[0].attachments, [attachment]); XCTAssertNotEqual(branch.messages[0].id, user.id)
        try await conversations.delete(chat.id)
        let reopened = try ConversationStore(file: storeFile), history = await reopened.all()
        try await owned.prune(keeping: Set(history.flatMap { $0.messages.flatMap { $0.attachments ?? [] }.map(\.id) }))
        _ = try await owned.resolve(attachment)
        try await reopened.delete(branch.id); try await owned.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.displayURL(attachment).path))
    }
}
