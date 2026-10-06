import Foundation
import OpenWeightsCore

extension ControllerChecks {
    @MainActor static func conversationMetadataChecks(_ passed: inout [String]) async throws {
        let fixture = try Fixture(mode: .seeded, supportsTools: false, write: false)
        defer { fixture.cleanup() }
        try await fixture.loadAndSend(); try await wait("Metadata initial turn did not settle") { !fixture.chat.busy }
        let stale = fixture.chat.current!
        fixture.chat.draft = "A newer turn"; await fixture.chat.send()
        try await wait("Metadata newer turn did not settle") { !fixture.chat.busy }
        let latest = try await fixture.chat.store.conversation(stale.id)
        await fixture.chat.renameConversation(stale.id, title: "  Cedar\n   project ")
        var saved = try await fixture.chat.store.conversation(stale.id)
        try require(saved.title == "Cedar project" && saved.messages == latest.messages && saved.updatedAt == latest.updatedAt && fixture.chat.current == saved,
                    "A stale rename replaced newer messages or changed the activity date.")
        passed.append("conversation-stale-rename-preserves-newer-transcript-and-activity-date")
        await fixture.chat.renameConversation(stale.id, title: " \n ")
        try require(fixture.chat.error != nil && fixture.chat.current == saved, "Blank rename changed the conversation or hid refusal.")
        passed.append("conversation-blank-rename-refused-without-transcript-change")
        let other = try await fixture.chat.store.create(title: "Newer unpinned")
        await fixture.chat.setConversationPinned(stale.id, pinned: true)
        saved = try await fixture.chat.store.conversation(stale.id)
        try require(fixture.chat.conversations.first?.id == stale.id && saved.pinned && saved.messages == latest.messages,
                    "Pin did not sort first or replaced transcript.")
        passed.append("conversation-pin-orders-ahead-of-newer-chat-without-replacing-messages")
        let resets = fixture.runtime.resetCount
        await fixture.chat.setConversationArchived(stale.id, archived: true)
        try require(fixture.chat.current == nil && fixture.defaults.string(forKey: "selectedConversation") == nil, "Archiving current left its selected handle.")
        try require(fixture.runtime.resetCount > resets && fixture.chat.contextUsed == 0 && fixture.chat.conversations.map(\.id) == [other.id],
                    "Archiving current retained context or active row.")
        passed.append("conversation-archive-clears-current-handle-context-and-active-row")
        await fixture.chat.refresh(archived: true)
        await fixture.chat.renameConversation(stale.id, title: "Filed Cedar")
        try require(fixture.chat.viewingArchived && fixture.chat.conversations.map(\.id) == [stale.id], "Archive rename switched the list to active.")
        await fixture.chat.setConversationArchived(stale.id, archived: false)
        try require(fixture.chat.viewingArchived && fixture.chat.conversations.isEmpty && fixture.chat.current == nil,
                    "Restore switched archive filter or reopened a chat.")
        await fixture.chat.refresh(archived: false)
        let restored = try await fixture.chat.store.conversation(stale.id)
        try require(restored.pinned && restored.messages == latest.messages && fixture.chat.conversations.first?.id == stale.id,
                    "Restore lost pin/transcript/order.")
        passed.append("conversation-archive-rename-and-restore-preserve-filter-pin-and-transcript")
        await fixture.chat.open(restored)
        await fixture.chat.delete(restored)
        let reopened = ChatController(store: try ConversationStore(file: fixture.conversationFile), downloads: fixture.downloads,
                                      defaults: fixture.defaults, runtimeFactory: { _ in fixture.runtime })
        await reopened.restore()
        try require(fixture.chat.current == nil && reopened.current == nil && reopened.conversations.map(\.id) == [other.id],
                    "Delete/reopen retained the removed selected conversation.")
        passed.append("conversation-delete-clears-selection-and-remains-deleted-on-controller-reopen")

        await fixture.chat.open(other)
        try FileManager.default.removeItem(at: fixture.conversationFile)
        try FileManager.default.createDirectory(at: fixture.conversationFile, withIntermediateDirectories: false)
        await fixture.chat.setConversationArchived(other.id, archived: true)
        try require(fixture.chat.current?.id == other.id && fixture.chat.current?.archived == false && fixture.chat.error != nil,
                    "Failed archive removed the open conversation or hid failure.")
        passed.append("conversation-failed-archive-keeps-open-chat-and-reports-storage-failure")
    }
}
