import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    func testNativeDiscoveredMLXDownloadPauseResumeVerifyAndChat() async throws {
        var pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .mlx })
        // The Hub declares an index even for this single weight file. Keep an
        // independent complete pin rather than dropping runtime metadata.
        pinned.files.append(ModelFile(path:"model.safetensors.index.json",bytes:49731,
            sha256:"7b294141456f6904936db03c00bca50fb5f6198f652fe8483f9cd2a1018accfb",
            url:try GGUFRangePolicy.pinnedURL(repository:try XCTUnwrap(pinned.repository),revision:try XCTUnwrap(pinned.revision),path:"model.safetensors.index.json")))
        try await discoveredMLXTransferAndChat(pinned, expectedFamily: "qwen3")
    }
    func testNativeDiscoveredQwen25MLXDownloadPauseResumeVerifyAndChat() async throws {
        try await discoveredMLXTransferAndChat(NativeMLXArtifact.qwen25(), expectedFamily: "qwen2")
    }
    private func discoveredMLXTransferAndChat(_ pinned: LocalModel, expectedFamily: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-download-" + UUID().uuidString)
        let suite = root.lastPathComponent, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let libraryURL = root.appendingPathComponent("models.json"), conversationsURL = root.appendingPathComponent("conversations.json")
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:libraryURL),sessionIdentifier:suite)
        var reopened: ModelDownloads?, chat: ChatController?
        var actions: [String] = [], observations: [String:Any] = [:], completed = false
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer {
            chat?.cancel(); downloads.cancelAllTransfers(); reopened?.cancelAllTransfers()
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite)
            mlxDownloadAttachment(completed:completed,actions:actions,observations:observations)
            if completed { try? FileManager.default.removeItem(at:root) }
        }
        let details = try await HubClient.details(try XCTUnwrap(pinned.repository),revision:try XCTUnwrap(pinned.revision),transport:HubAPITransport(useStoredCredential:false))
        var model = try await HubClient.mlx(details,useStoredCredential:false)
        XCTAssertEqual(model.family,expectedFamily); XCTAssertEqual(model.backend,.mlx)
        XCTAssertEqual(Set(model.files.map(\.path)),Set(pinned.files.map(\.path)))
        for expected in pinned.files {
            let selected = try XCTUnwrap(model.files.first { $0.path == expected.path })
            XCTAssertEqual(selected.bytes,expected.bytes)
            XCTAssertEqual(selected.url,expected.url)
        }
        observations = ["repository":details.id,"revision":details.sha,"entry":model.entryFile,"family":model.family ?? "",
            "components":model.files.map { ["path":$0.path,"bytes":$0.bytes ?? -1,"sha256":$0.sha256 ?? "","gitBlobSHA1":$0.gitBlobSHA1 ?? ""] }]
        actions.append("select-live-pinned-export-with-verified-metadata-and-canonical-companions")
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 96
        await downloads.install(model); XCTAssertNil(downloads.error)
        let weights = try XCTUnwrap(model.files.first { $0.path == "model.safetensors" })
        let ownedWeights = try weights.destination(in:downloads.directory(model)), partial = ownedWeights.appendingPathExtension("partial")
        try await waitUntil(seconds:180) { ((try? ModelFileTransfer.byteCount(partial)) ?? 0) > 0 || downloads.models.first?.state == .ready || downloads.models.first?.state == .failed || downloads.error != nil }
        XCTAssertEqual(downloads.models.first?.state,.downloading,downloads.error ?? downloads.models.first?.failure ?? "")
        guard downloads.models.first?.state == .downloading else { return }
        await downloads.pause(try XCTUnwrap(downloads.models.first)); XCTAssertNil(downloads.error)
        let checkpoint = try ModelFileTransfer.byteCount(partial)
        XCTAssertGreaterThan(checkpoint,0); XCTAssertLessThan(checkpoint,try XCTUnwrap(weights.bytes))
        XCTAssertEqual(downloads.models.first?.state,.paused)
        observations["weightCheckpointBytes"] = checkpoint
        let saved = downloads.models
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial),checkpoint)
        downloads.cancelAllTransfers()
        let restored = ModelDownloads(root:downloads.root,library:try ModelLibrary(file:libraryURL),sessionIdentifier:suite + ".reopen")
        reopened = restored; await restored.restore()
        XCTAssertEqual(restored.models,saved)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial),checkpoint)
        actions.append("pause-stable-weight-checkpoint-and-reopen-model-metadata")
        await restored.resume(try XCTUnwrap(restored.models.first)); XCTAssertNil(restored.error)
        let ranges = restored.diagnosticSnapshot().compactMap { $0["range"] as? String }
        observations["resumeRequestRanges"] = ranges
        XCTAssertTrue(ranges.contains { $0.hasPrefix("bytes=\(checkpoint)-") })
        guard ranges.contains(where:{ $0.hasPrefix("bytes=\(checkpoint)-") }) else { return }
        try await waitUntil(seconds:480) { restored.models.first?.state == .ready || restored.models.first?.state == .failed || restored.error != nil }
        let installed = try XCTUnwrap(restored.models.first)
        XCTAssertNil(restored.error); XCTAssertEqual(installed.state,.ready,installed.failure ?? "")
        guard installed.state == .ready else { return }
        var fullSHA256: [String:String] = [:]
        for expected in pinned.files {
            let owned = try expected.destination(in:restored.directory(installed))
            try await Task.detached { try ModelFileTransfer.verify(owned,file:expected) }.value
            let actual = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
            fullSHA256[expected.path] = actual
            XCTAssertEqual(actual,expected.sha256)
            XCTAssertFalse(FileManager.default.fileExists(atPath:owned.appendingPathExtension("partial").path))
        }
        observations["independentFullFileSHA256"] = fullSHA256
        actions.append("resume-exact-range-and-verify-all-complete-files-against-independent-pins")
        mlxDownloadAttachment(completed:false,actions:actions,observations:observations)
        let initial = ChatController(store:try ConversationStore(file:conversationsURL),downloads:restored,defaults:defaults)
        chat = initial
        await initial.load(installed); XCTAssertNil(initial.error)
        initial.draft = "Reply with exactly Cedar."; await initial.send()
        try await waitUntil(seconds:90) { !initial.busy }
        XCTAssertNil(initial.error)
        let answer = try XCTUnwrap(initial.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        observations["firstAnswer"] = answer
        XCTAssertTrue(answer == "Cedar" || answer == "Cedar.")
        let conversation = try XCTUnwrap(initial.current)
        let stored = try await ConversationStore(file:conversationsURL).conversation(conversation.id)
        // Store.save stamps commit time. All content and identity must survive,
        // while the persisted activity date advances rather than matching the draft.
        var expectedStored = conversation; expectedStored.updatedAt = stored.updatedAt
        observations["controllerUpdatedAt"] = conversation.updatedAt.timeIntervalSince1970
        observations["persistedUpdatedAt"] = stored.updatedAt.timeIntervalSince1970
        XCTAssertEqual(stored,expectedStored)
        XCTAssertGreaterThanOrEqual(stored.updatedAt,conversation.updatedAt)
        guard stored == expectedStored, stored.updatedAt >= conversation.updatedAt else { return }
        await initial.open(stored); XCTAssertNil(initial.error)
        XCTAssertEqual(initial.current,stored)
        XCTAssertEqual(initial.loadedModel?.id,installed.id)
        initial.draft = "What is 2 + 2? Reply with only the number."; await initial.send()
        try await waitUntil(seconds:90) { !initial.busy }
        XCTAssertNil(initial.error)
        let recovery = try XCTUnwrap(initial.current?.messages.last { $0.role == .assistant })
        XCTAssertEqual(recovery.content.trimmingCharacters(in:.whitespacesAndNewlines),"4")
        observations["reopenedAnswer"] = recovery.content
        actions.append("load-downloaded-model-chat-and-continue-durably-reopened-conversation")
        completed = (answer == "Cedar" || answer == "Cedar.") && recovery.content.trimmingCharacters(in:.whitespacesAndNewlines) == "4"
    }
    private func mlxDownloadAttachment(completed: Bool, actions: [String], observations: [String:Any]) {
        let evidence: [String:Any] = ["purpose":"native-discovered-mlx-full-download-pause-resume-chat","completed":completed,
            "actions":actions,"observations":observations,"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Actual public pinned Hub folder selection and fresh product URLSession downloads with full weight/tokenizer/config verification. No cached weight seeding.","Paused metadata/download-manager reopening and stored conversation reopening occur within one process. No killed-process or OS suspension verification.","Direct controller calls do not verify gestures, VoiceOver, gated access, other families or general model quality. No A2 speed, memory-fit or energy claim."]]
        let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "native-mlx-download.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
