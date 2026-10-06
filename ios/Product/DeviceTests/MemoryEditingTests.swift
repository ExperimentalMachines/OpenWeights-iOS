import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeMemoryEditingIdentityAndDurability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-memory-edit-" + UUID().uuidString)
        let suite = "native-memory-edit-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = root.appendingPathComponent("memory.json"), store = try MemoryStore(file: file)
        let memory = MemoryController(store: store, defaults: defaults)
        var actions: [String] = [], completed = false
        defer {
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root)
            memoryEditingEvidence(["purpose":"native-memory-editing-identity-and-durability","completed":completed,"actions":actions,
                "limitations":["Direct production controller/store APIs with synthetic facts and a mounted production list. No editor gestures, keyboard, accessibility or app-process termination."]])
        }
        XCTAssertFalse(memory.writeEnabled); XCTAssertFalse(memory.readEnabled)
        checkMemoryTrue(await memory.save("  My project\nis Cedar.  "))
        let original = try XCTUnwrap(memory.facts.first)
        XCTAssertEqual(original.text,"My project is Cedar.")
        checkMemoryTrue(await memory.save("My project is Pine.",replacing:original))
        let edited = try XCTUnwrap(memory.facts.first)
        XCTAssertEqual(edited.id,original.id); XCTAssertEqual(edited.savedAt,original.savedAt)
        let reopened = MemoryController(store:try MemoryStore(file:file),defaults:defaults); await reopened.restore()
        XCTAssertEqual(reopened.facts,[edited]); XCTAssertFalse(reopened.writeEnabled)
        actions.append("manual-explicit-edit-with-agent-switches-off-keeps-ID-age-and-durable-reopen")
        checkMemoryTrue(await memory.save("My project is Cedar. backup"))
        let before = memory.facts
        checkMemoryFalse(await memory.save("Wrong stale edit",replacing:original)); XCTAssertNotNil(memory.error)
        XCTAssertEqual(memory.facts,before); checkMemoryEqual(await store.list(),before)
        actions.append("stale-edit-refused-without-overwriting-newer-or-unrelated-fact")
        checkMemoryFalse(await memory.save("  \n ",replacing:edited))
        checkMemoryFalse(await memory.save(String(repeating:"🧠",count:81),replacing:edited))
        XCTAssertEqual(memory.facts,before)
        actions.append("blank-and-over-160-UTF16-edit-refused-with-retained-facts")
        await memory.delete(edited); let remaining = memory.facts
        XCTAssertEqual(remaining.count,1); XCTAssertTrue(remaining[0].text.contains("backup"))
        await memory.delete(original); XCTAssertNotNil(memory.error); XCTAssertEqual(memory.facts,remaining)
        actions.append("stale-delete-refused-by-ID-without-substring-victim")
        let snapshot = try Data(contentsOf:file)
        try FileManager.default.removeItem(at:file); try FileManager.default.createDirectory(at:file,withIntermediateDirectories:false)
        checkMemoryFalse(await memory.save("Cannot commit",replacing:remaining[0])); XCTAssertEqual(memory.facts,remaining)
        await memory.delete(remaining[0]); XCTAssertNotNil(memory.error); XCTAssertEqual(memory.facts,remaining)
        await memory.deleteAll(); XCTAssertNotNil(memory.error); XCTAssertEqual(memory.facts,remaining)
        try FileManager.default.removeItem(at:file); try snapshot.write(to:file)
        actions.append("failed-edit-delete-and-clear-preserve-in-memory-and-durable-snapshot")
        let screenshot = try await NativeMountedView.capture(NavigationStack { MemoryScreen(memory:memory) },size:CGSize(width:390,height:500))
        let attachment = XCTAttachment(image:screenshot); attachment.name="Mounted saved-memory list";attachment.lifetime = .keepAlways;add(attachment)
        await memory.deleteAll(); XCTAssertNil(memory.error); XCTAssertTrue(memory.facts.isEmpty)
        let empty = MemoryController(store:try MemoryStore(file:file),defaults:defaults);await empty.restore();XCTAssertTrue(empty.facts.isEmpty)
        actions.append("delete-all-persists-empty-list-and-controller-reopen")
        completed = true
    }

    @MainActor func testNativeApprovedMemoryUpdateAndCrossChatRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-memory-update-" + UUID().uuidString)
        let suite = "native-memory-update-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let memoryFile = root.appendingPathComponent("memory.json"), memory = MemoryController(store:try MemoryStore(file:memoryFile),defaults:defaults)
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:root.appendingPathComponent("models.json")))
        let chat = ChatController(store:try ConversationStore(file:root.appendingPathComponent("conversations.json")),downloads:downloads,memory:memory,defaults:defaults)
        let idle = UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled = true
        var actions: [String] = [], calls: [String] = [], completed = false, artifact: [String:Any] = [:], settings: [String:Any] = [:]
        defer {
            chat.cancel();UIApplication.shared.isIdleTimerDisabled = idle;defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            memoryEditingEvidence(["purpose":"native-approved-memory-update-and-cross-chat-read","completed":completed,"actions":actions,"displayedArguments":calls,"artifact":artifact,"effectiveSettings":settings,
                "limitations":["One selected pinned Qwen3 artifact and synthetic facts with direct production approval callbacks. No touch/keyboard acceptance, general agent-quality ranking or process termination."]])
        }
        let pinned = try NativeAgentArtifact.selected(), source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        artifact = NativeAgentArtifact.evidence(pinned)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first));await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first);model.backend = .llamaCPU;model.settings.contextTokens=4096
        model.settings.temperature=0;model.settings.topP=1;model.settings.repeatPenalty=1;model.settings.outputTokens=128;model.settings.thinking=false
        artifact["effectiveBackend"] = model.backend.rawValue
        settings = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(model.settings)) as? [String:Any])
        try await downloads.saveSettings(model);await chat.load(model);XCTAssertNil(chat.error);XCTAssertTrue(chat.supportsTools)
        checkMemoryTrue(await memory.save("My project is Cedar."));let original = try XCTUnwrap(memory.facts.first)
        memory.writeEnabled=true;memory.readEnabled=true
        chat.draft="Use update_memory to change this exact saved fact. old: My project is Cedar. new: My project is Pine. Then confirm briefly."
        await chat.send();try await waitUntil(seconds:120) { chat.pendingToolApproval != nil || !chat.busy }
        let pending = try XCTUnwrap(chat.pendingToolApproval,chat.error ?? "No memory update approval")
        XCTAssertEqual(pending.displayedCall.name,"update_memory");calls.append(pending.displayedCall.argumentsJSON)
        checkMemoryEqual(await memory.store.list(),[original])
        let args = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(pending.displayedCall.argumentsJSON.utf8)) as? [String:Any])
        XCTAssertEqual(args["old"] as? String,original.text);XCTAssertEqual(args["new"] as? String,"My project is Pine.")
        actions.append("real-model-proposes-exact-update-with-no-change-before-approval")
        chat.answerToolApproval(approved:true,ticketID:pending.ticketID)
        try await waitUntil(seconds:120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertFalse(chat.busy);XCTAssertNil(chat.error);XCTAssertNil(chat.pendingToolApproval)
        XCTAssertEqual(memory.facts.count,1);let edited=try XCTUnwrap(memory.facts.first)
        XCTAssertEqual(edited.text,"My project is Pine.");XCTAssertEqual(edited.id,original.id);XCTAssertEqual(edited.savedAt,original.savedAt)
        XCTAssertTrue(chat.current?.messages.contains { $0.role == .tool && $0.toolName == "update_memory" && $0.content == "Updated." } == true)
        actions.append("approved-update-preserves-fact-ID-age-and-runs-real-answer-pass")
        let restored=MemoryController(store:try MemoryStore(file:memoryFile),defaults:defaults);await restored.restore();XCTAssertEqual(restored.facts,[edited])
        XCTAssertTrue(restored.readEnabled);XCTAssertTrue(restored.writeEnabled)
        _ = await chat.newConversation();chat.draft="Use read_memory to find my current saved project. Answer with its name only."
        await chat.send();try await waitUntil(seconds:120) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertNil(chat.error);XCTAssertNil(chat.pendingToolApproval);XCTAssertFalse(chat.busy)
        XCTAssertTrue(chat.current?.messages.contains { $0.role == .tool && $0.toolName == "read_memory" && $0.content.contains("Pine") && !$0.content.contains("Cedar") } == true)
        XCTAssertTrue(chat.current?.messages.last?.content.contains("Pine") == true,chat.current?.messages.last?.content ?? "")
        actions.append("fresh-chat-reads-only-updated-fact-and-real-model-answers-Pine")
        completed=true
    }
    private func checkMemoryTrue(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { XCTAssertTrue(value,file:file,line:line) }
    private func checkMemoryFalse(_ value:Bool,file:StaticString=#filePath,line:UInt=#line) { XCTAssertFalse(value,file:file,line:line) }
    private func checkMemoryEqual<T:Equatable>(_ lhs:T,_ rhs:T,file:StaticString=#filePath,line:UInt=#line) { XCTAssertEqual(lhs,rhs,file:file,line:line) }
    private func memoryEditingEvidence(_ value:[String:Any]) {
        let attachment=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name=value["purpose"] as? String ?? "Memory editing";attachment.lifetime = .keepAlways;add(attachment)
    }
}
