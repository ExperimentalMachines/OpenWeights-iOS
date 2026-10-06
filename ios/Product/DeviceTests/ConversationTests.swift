import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeConversationFilingPreservesNewerRepliesAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-conversation-filing-" + UUID().uuidString)
        let suite = "native-conversation-filing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var actions: [String] = [], completed = false
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
            let evidence: [String:Any] = ["purpose":"native-conversation-filing", "completed":completed, "actions":actions,
                "limitations":["Real pinned GGUF CPU replies and direct production controller/store operations. No UI gestures or app-process termination.",
                    "A mounted conversation list is captured. Alert/menu interaction, VoiceOver and Dynamic Type remain unverified."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "Native conversation filing"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let downloads = try ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:root.appendingPathComponent("models.json")))
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        for file in pinned.files { try ModelDownloads.verify(file.destination(in:source.deletingLastPathComponent()),file:file) }
        await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.backend = .llamaCPU
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 16
        try await downloads.saveSettings(model)
        let file = root.appendingPathComponent("conversations.json"), store = try ConversationStore(file:file)
        let chat = ChatController(store:store,downloads:downloads,defaults:defaults)
        await chat.load(model); XCTAssertNil(chat.error)
        chat.draft = "Name one fruit."; await chat.send(); try await waitUntil(seconds:60) { !chat.busy }
        XCTAssertNil(chat.error)
        let stale = try XCTUnwrap(chat.current)
        chat.draft = "Name one vegetable."; await chat.send(); try await waitUntil(seconds:60) { !chat.busy }
        XCTAssertNil(chat.error)
        let latest = try await store.conversation(stale.id)
        XCTAssertEqual(latest.messages.count,4); XCTAssertEqual(latest.messages.last?.status,.complete)
        await chat.renameConversation(stale.id,title:"  Cedar\n   project ")
        let renamed = try await store.conversation(stale.id)
        XCTAssertEqual(renamed.messages,latest.messages); XCTAssertEqual(renamed.updatedAt,latest.updatedAt)
        XCTAssertEqual(renamed.title,"Cedar project"); XCTAssertEqual(chat.current,renamed)
        actions.append("stale-row-rename-preserves-two-real-replies-and-activity-date")
        await chat.renameConversation(stale.id,title:" \n ")
        XCTAssertNotNil(chat.error); XCTAssertEqual(chat.current,renamed)
        actions.append("blank-rename-refused")
        let other = try await store.create(title:"Newer chat")
        await chat.setConversationPinned(stale.id,pinned:true)
        XCTAssertEqual(chat.conversations.first?.id,stale.id); XCTAssertNil(chat.error)
        actions.append("pinned-chat-sorts-before-newer-unpinned-chat")
        await chat.setConversationArchived(stale.id,archived:true)
        XCTAssertNil(chat.current); XCTAssertNil(defaults.string(forKey:"selectedConversation")); XCTAssertEqual(chat.contextUsed,0)
        XCTAssertEqual(chat.conversations.map(\.id),[other.id])
        actions.append("archive-current-clears-selection-and-context")
        let reopened = ChatController(store:try ConversationStore(file:file),downloads:downloads,defaults:defaults)
        await reopened.restore(); XCTAssertNil(reopened.current)
        await chat.refresh(archived:true); await chat.renameConversation(stale.id,title:"Filed Cedar")
        XCTAssertTrue(chat.viewingArchived); XCTAssertEqual(chat.conversations.map(\.id),[stale.id])
        let host = UIHostingController(rootView:NavigationStack { ConversationList(chat:chat,selected:{}) })
        let window = UIWindow(frame:UIScreen.main.bounds); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds:250_000_000); host.view.layoutIfNeeded()
        // The screen's initial task selects active chats, as an ordinary new sheet does.
        await chat.refresh(archived:true)
        let renderer = UIGraphicsImageRenderer(bounds:host.view.bounds)
        let image = renderer.image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let screenshot = XCTAttachment(image:image); screenshot.name = "Mounted conversation list"; screenshot.lifetime = .keepAlways; add(screenshot)
        await chat.setConversationArchived(stale.id,archived:false)
        XCTAssertTrue(chat.viewingArchived); XCTAssertTrue(chat.conversations.isEmpty); XCTAssertNil(chat.current)
        await chat.refresh(archived:false)
        let restored = try await store.conversation(stale.id)
        XCTAssertTrue(restored.pinned); XCTAssertEqual(restored.messages,latest.messages); XCTAssertEqual(chat.conversations.first?.id,stale.id)
        actions.append("archive-rename-and-restore-preserve-filter-pin-and-transcript")
        await chat.open(restored); XCTAssertEqual(chat.current?.id,stale.id); XCTAssertNil(chat.error)
        XCTAssertGreaterThan(chat.contextUsed,0)
        actions.append("restored-conversation-reopens-and-warms-real-runtime")
        await chat.delete(restored); XCTAssertNil(chat.current); XCTAssertEqual(chat.contextUsed,0)
        let deleted = ChatController(store:try ConversationStore(file:file),downloads:downloads,defaults:defaults)
        await deleted.restore(); XCTAssertNil(deleted.current); XCTAssertEqual(deleted.conversations.map(\.id),[other.id])
        actions.append("delete-persists-and-clears-selected-handle-on-controller-reopen")
        await chat.open(other)
        try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        await chat.setConversationArchived(other.id,archived:true)
        XCTAssertEqual(chat.current?.id,other.id); XCTAssertEqual(chat.current?.archived,false); XCTAssertNotNil(chat.error)
        actions.append("failed-archive-keeps-open-chat-and-reports-storage-failure")
        completed = true
    }
}
