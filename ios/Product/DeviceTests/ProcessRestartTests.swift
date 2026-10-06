import Foundation
import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

private struct ProductRestartMarker: Codable {
    var preparedPID: Int32
    var importedID: UUID
    var downloadID: UUID
    var conversation: Conversation
    var weightCheckpointBytes: Int64
    var expectedDownload: LocalModel
}

extension ProductTests {
    private var restartRoot: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("OpenWeights")
    }
    private var restartMarker: URL { restartRoot.appendingPathComponent("process-restart-validation.json") }
    func testNativeProductProcessRestartPrepare() async throws {
        let state = ProductDelegate.productState
        let downloads = try XCTUnwrap(state.downloads), chat = try XCTUnwrap(state.chat)
        XCTAssertNil(state.failure)
        guard !FileManager.default.fileExists(atPath:restartMarker.path) else {
            throw ModelError.unsupported("A prior process-restart fixture exists. Finish its second phase before preparing another.")
        }
        // This development app's empty library was checked before the run. Never
        // replace someone's existing models or selected conversation for a fixture.
        try await waitUntil(seconds:5) { !chat.loading }
        let initialModels = try await ModelLibrary(file:restartRoot.appendingPathComponent("models.json")).list()
        let initialChats = try await ConversationStore(file:restartRoot.appendingPathComponent("conversations.json")).list()
        guard initialModels.isEmpty, initialChats.isEmpty, chat.current == nil else {
            throw ModelError.unsupported("Process-restart preparation requires this development app's empty library and conversation store.")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        let pinned = try XCTUnwrap(HubClient.pinnedCatalogue().first { $0.backend == .llamaMetal })
        let original = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(original,file:try XCTUnwrap(pinned.files.first))
        await downloads.importGGUF(original); XCTAssertNil(downloads.error)
        var imported = try XCTUnwrap(downloads.models.first)
        imported.name = "Process restart prepared model"
        imported.settings.temperature = 0; imported.settings.topP = 1; imported.settings.repeatPenalty = 1
        imported.settings.outputTokens = 64; imported.settings.thinking = false
        try await downloads.save(imported); await chat.load(imported); XCTAssertNil(chat.error)
        chat.draft = "My project name is Cedar. Reply with only Cedar."; await chat.send()
        try await waitUntil(seconds:90) { !chat.busy || chat.pendingToolApproval != nil }
        XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.error)
        let first = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        XCTAssertTrue(first == "Cedar" || first == "Cedar.")
        guard first == "Cedar" || first == "Cedar." else { return }
        let current = try XCTUnwrap(chat.current)
        let stored = try await ConversationStore(file:restartRoot.appendingPathComponent("conversations.json")).conversation(current.id)
        XCTAssertEqual(stored.messages,current.messages); XCTAssertEqual(stored.modelID,imported.id)
        var download = pinned
        download.name = "Qwen3 0.6B verified restart download"
        download.settings = imported.settings
        await downloads.install(download); XCTAssertNil(downloads.error)
        let weight = try XCTUnwrap(download.files.first)
        let partial = try weight.destination(in:downloads.directory(download)).appendingPathExtension("partial")
        try await waitUntil(seconds:180) { ((try? ModelFileTransfer.byteCount(partial)) ?? 0) > 0 || downloads.models.first { $0.id == download.id }?.state == .ready || downloads.error != nil }
        let running = try XCTUnwrap(downloads.models.first { $0.id == download.id })
        XCTAssertEqual(running.state,.downloading)
        guard running.state == .downloading else { return }
        await downloads.pause(running); XCTAssertNil(downloads.error)
        let checkpoint = try ModelFileTransfer.byteCount(partial)
        XCTAssertGreaterThan(checkpoint,0); XCTAssertLessThan(checkpoint,try XCTUnwrap(weight.bytes))
        try await Task.sleep(nanoseconds:200_000_000)
        XCTAssertEqual(try ModelFileTransfer.byteCount(partial),checkpoint)
        XCTAssertEqual(downloads.models.first { $0.id == download.id }?.state,.paused)
        let marker = ProductRestartMarker(preparedPID:ProcessInfo.processInfo.processIdentifier,importedID:imported.id,
            downloadID:download.id,conversation:stored,weightCheckpointBytes:checkpoint,expectedDownload:download)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(marker).write(to:restartMarker,options:.atomic)
        processRestartAttachment(["phase":"prepare","completed":true,"processIdentifier":marker.preparedPID,
            "importedModelID":imported.id.uuidString,"downloadModelID":download.id.uuidString,
            "conversationID":stored.id.uuidString,"firstAnswer":first,"checkpointBytes":checkpoint,
            "productionBackgroundSessionIdentifier":"org.experimentalmachines.openweights.models",
            "markerRelativePath":"Library/Application Support/OpenWeights/process-restart-validation.json"])
    }

    func testNativeProductProcessRestartFinish() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let marker = try JSONDecoder().decode(ProductRestartMarker.self,from:Data(contentsOf:restartMarker))
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertNotEqual(pid,marker.preparedPID)
        guard pid != marker.preparedPID else { return }
        let state = ProductDelegate.productState
        let downloads = try XCTUnwrap(state.downloads), chat = try XCTUnwrap(state.chat)
        XCTAssertNil(state.failure)
        // Observe the actual root scene's launch restoration before invoking any
        // manual restore, model loading or test-created replacement controller.
        try await waitUntil(seconds:15) { downloads.models.contains { $0.id == marker.downloadID } && chat.current?.id == marker.conversation.id }
        let automatic = try XCTUnwrap(chat.current)
        XCTAssertEqual(automatic,marker.conversation)
        let paused = try XCTUnwrap(downloads.models.first { $0.id == marker.downloadID })
        XCTAssertEqual(paused.state,.paused)
        let owned = try XCTUnwrap(paused.files.first).destination(in:downloads.directory(paused))
        let checkpoint = try ModelFileTransfer.byteCount(owned.appendingPathExtension("partial"))
        XCTAssertEqual(checkpoint,marker.weightCheckpointBytes)
        guard automatic == marker.conversation, checkpoint == marker.weightCheckpointBytes, paused.state == .paused else { return }
        var observations: [String:Any] = ["phase":"finish","completed":false,"preparedPID":marker.preparedPID,"processIdentifier":pid,
            "conversationID":automatic.id.uuidString,"automaticRootRestorationVerified":true,
            "checkpointBytes":checkpoint,"downloadModelID":paused.id.uuidString]
        defer { processRestartAttachment(observations) }
        await chat.open(automatic); XCTAssertNil(chat.error)
        XCTAssertEqual(chat.loadedModel?.id,marker.importedID)
        chat.draft = "What is my project name? Reply with only its name."; await chat.send()
        try await waitUntil(seconds:90) { !chat.busy }
        XCTAssertNil(chat.error)
        let recalled = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        observations["postRestartRecall"] = recalled
        XCTAssertTrue(recalled == "Cedar" || recalled == "Cedar.")
        await downloads.resume(paused); XCTAssertNil(downloads.error)
        let ranges = downloads.diagnosticSnapshot().compactMap { $0["range"] as? String }
        observations["resumeRequestRanges"] = ranges
        XCTAssertTrue(ranges.contains { $0.hasPrefix("bytes=\(checkpoint)-") })
        try await waitUntil(seconds:480) { downloads.models.first { $0.id == marker.downloadID }?.state == .ready || downloads.error != nil || downloads.models.first { $0.id == marker.downloadID }?.state == .failed }
        let ready = try XCTUnwrap(downloads.models.first { $0.id == marker.downloadID })
        XCTAssertNil(downloads.error); XCTAssertEqual(ready.state,.ready,ready.failure ?? "")
        guard ready.state == .ready else { return }
        let expected = try XCTUnwrap(marker.expectedDownload.files.first)
        try await Task.detached { try ModelFileTransfer.verify(owned,file:expected) }.value
        observations["completeSHA256"] = try await Task.detached { try ModelFileTransfer.hash(owned) }.value
        observations["completeBytes"] = try ModelFileTransfer.byteCount(owned)
        await chat.load(ready); XCTAssertNil(chat.error)
        XCTAssertEqual(chat.loadedModel?.id,marker.downloadID)
        chat.draft = "What is my project name? Reply with only its name."; await chat.send()
        try await waitUntil(seconds:90) { !chat.busy }
        XCTAssertNil(chat.error)
        let downloadedReply = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content).trimmingCharacters(in:.whitespacesAndNewlines)
        observations["downloadedModelRecall"] = downloadedReply
        XCTAssertTrue(downloadedReply == "Cedar" || downloadedReply == "Cedar.")
        let previous = try XCTUnwrap(downloads.models.first { $0.id == marker.importedID })
        try await downloads.remove(previous)
        XCTAssertFalse(downloads.models.contains { $0.id == previous.id })
        XCTAssertEqual(chat.loadedModel?.id,ready.id)
        XCTAssertEqual(chat.current?.modelID,ready.id)
        observations["unloadedPreparationModelRemoved"] = true
        let finished = (recalled == "Cedar" || recalled == "Cedar.") && (downloadedReply == "Cedar" || downloadedReply == "Cedar.")
            && ranges.contains { $0.hasPrefix("bytes=\(checkpoint)-") }
        observations["completed"] = finished
        if finished { try FileManager.default.removeItem(at:restartMarker) }
    }
    private func processRestartAttachment(_ observations: [String:Any]) {
        let value: [String:Any] = ["purpose":"native-production-root-actual-process-restart","observations":observations,
            "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Uses the real app delegate ProductState, normal root scene restoration, production model library, standard selected-conversation preference and production background-session identifier.","The fixture requires the development app's empty library/conversation store and retains the verified downloaded model and real conversation for review. The redundant preparation model is removed.","Two actual PIDs establish observed process restart. The preceding process's exit cause requires separate evidence. Paused downloads have no in-flight transfer, so this does not prove automatic OS background relaunch, suspension callbacks, force-quit transfer continuation, gestures or VoiceOver.","Prepared model bytes are imported from verified cache. The paused and resumed second model uses a real pinned Hub transfer. No A2 performance, fit, energy or general-quality claim."]]
        let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "native-process-restart.json"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
