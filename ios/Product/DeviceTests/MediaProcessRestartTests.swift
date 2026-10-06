import XCTest
import UIKit
import CryptoKit
import UniformTypeIdentifiers
import OpenWeightsCore
@testable import OpenWeights

private struct MediaRestartMarker: Codable {
    var phase: String
    var preparedPID: Int32
    var model: LocalModel
    var previousSelection: String?
    var previousModels: [String:String]
    var previousConversations: [String:String]
    var conversationID: UUID?
    var conversation: Conversation?
}

extension ProductTests {
    private var mediaRestartRoot: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("OpenWeights")
    }
    private var mediaRestartMarker: URL { mediaRestartRoot.appendingPathComponent("MediaRestartValidation/marker.json") }
    private func mediaRestartHash<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data:try encoder.encode(value)).map { String(format:"%02x",$0) }.joined()
    }
    private func mediaRestartWrite(_ marker: MediaRestartMarker) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try FileManager.default.createDirectory(at:mediaRestartMarker.deletingLastPathComponent(),withIntermediateDirectories:true)
        try encoder.encode(marker).write(to:mediaRestartMarker,options:.atomic)
    }
    private func mediaRestartRecord(_ value: [String:Any]) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            .write(to:mediaRestartMarker.deletingLastPathComponent().appendingPathComponent("journal.json"),options:.atomic)
    }
    private func mediaRestartEvidence(_ value: [String:Any]) {
        let payload: [String:Any] = ["purpose":"native-production-root-folded-media-process-restart","observations":value,
            "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations":["Uses actual ProductDelegate ProductState, normal selected-conversation preference and root restoration. Cached, verified model files are hard-linked into a test-owned model entry, not freshly downloaded or imported.",
                "Two alternating synthetic English clips. No general speech/summary quality, performance, energy, system-picker/provider gestures or OS-initiated memory-pressure termination claim.",
                "Prepare pauses at a completed durable checkpoint after product Stop. A host-controlled SIGKILL is required and must be evidenced separately. It is not a kill during inference or file copying.",
                "Existing model/conversation fingerprints and selection are preserved. Ordinary usage records of validation inference are retained."]]
        let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = "native-media-process-restart"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testNativeMediaProcessRestartPrepare() async throws {
        guard !FileManager.default.fileExists(atPath:mediaRestartMarker.path) else {
            throw ModelError.unsupported("Finish or clean up the existing media restart fixture first.")
        }
        let state = ProductDelegate.productState
        let chat = try XCTUnwrap(state.chat), downloads = try XCTUnwrap(state.downloads)
        let attachments = try XCTUnwrap(chat.attachments)
        try await waitUntil(seconds:15) { !chat.loading && !chat.busy && !chat.boardUpdating }
        guard !chat.goalActive, !attachments.busy, !attachments.hasStaged, state.watches?.checkingID == nil else {
            throw ModelError.unsupported("Finish active app work before preparing the media restart fixture.")
        }
        let originalLibrary = try ModelLibrary(file:mediaRestartRoot.appendingPathComponent("models.json"))
        let originalModels = await originalLibrary.list()
        let originalChats = await chat.store.all()
        let support = mediaRestartRoot.deletingLastPathComponent().appendingPathComponent("OmniAudioValidation")
        let sourceLibrary = try ModelLibrary(file:support.appendingPathComponent("models.json"))
        let sourceModels = await sourceLibrary.list()
        var model = try XCTUnwrap(sourceModels.first {
            $0.id.uuidString == "9C4CBED5-1FCD-4223-9785-B6F43FA6634B" && $0.state == .ready
        })
        let originalDirectory = support.appendingPathComponent("Models").appendingPathComponent(model.id.uuidString)
        model.id = UUID(); model.name = "Media restart validation"; model.settings.contextTokens = 4096
        model.settings.outputTokens = 96; model.settings.temperature = 0; model.settings.topP = 1
        model.settings.repeatPenalty = 1; model.settings.thinking = false
        var marker = MediaRestartMarker(phase:"preparing",preparedPID:ProcessInfo.processInfo.processIdentifier,model:model,
            previousSelection:UserDefaults.standard.string(forKey:"selectedConversation"),
            previousModels:try Dictionary(uniqueKeysWithValues:originalModels.map { ($0.id.uuidString,try mediaRestartHash($0)) }),
            previousConversations:try Dictionary(uniqueKeysWithValues:originalChats.map { ($0.id.uuidString,try mediaRestartHash($0)) }))
        try mediaRestartWrite(marker)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        var observations: [[String:Any]] = []
        func record(_ value: [String:Any]) throws {
            observations.append(value)
            try mediaRestartRecord(["phase":"preparing","preparedPID":marker.preparedPID,"observations":observations])
        }
        defer { mediaRestartEvidence(["phase":"prepare","preparedPID":marker.preparedPID,"checkpointArmed":marker.phase == "armed","observations":observations]) }
        try FileManager.default.createDirectory(at:downloads.directory(model),withIntermediateDirectories:true)
        for file in model.files {
            let source = try file.destination(in:originalDirectory), destination = try file.destination(in:downloads.directory(model))
            try await Task.detached { try ModelDownloads.verify(source,file:file) }.value
            try FileManager.default.linkItem(at:source,to:destination)
        }
        try await downloads.save(model)
        marker.model = try XCTUnwrap(downloads.models.first { $0.id == model.id }); try mediaRestartWrite(marker)
        let created = await chat.newConversation(); XCTAssertTrue(created)
        guard created else { throw ModelError.unsupported("The validation conversation could not be created.") }
        marker.conversationID = try XCTUnwrap(chat.current?.id); try mediaRestartWrite(marker)
        await chat.load(marker.model); XCTAssertNil(chat.error); XCTAssertTrue(chat.mediaSupport.audio)
        guard chat.error == nil, chat.mediaSupport.audio else { throw ModelError.unsupported(chat.error ?? "Audio loading failed.") }
        try record(["stage":"normal-product-model-loaded","modelID":model.id.uuidString,"audio":chat.mediaSupport.audio,
            "supportsTools":chat.supportsTools,"effectiveSettingsHash":try mediaRestartHash(marker.model.settings),"preexistingModels":originalModels.count,"preexistingConversations":originalChats.count])
        struct Manifest: Decodable {
            struct Fixture: Decodable { var path: String; var bytes: Int; var sha256: String; var text: String }
            var fixtures: [Fixture]
        }
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:try XCTUnwrap(Bundle.main.url(forResource:"omni-audio-validation-artifact",withExtension:"json"))))
        func words(_ text: String) -> [String] { text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        func send(_ question: String) async throws -> StoredMessage {
            chat.draft = question; await chat.send()
            try await waitUntil(seconds:180) { !chat.busy || chat.pendingToolApproval != nil || chat.pendingUserQuestion != nil }
            XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.pendingUserQuestion)
            guard !chat.busy, chat.error == nil else { throw ModelError.unsupported(chat.error ?? "The audio request did not complete without interaction.") }
            let reply = try XCTUnwrap(chat.current?.messages.last)
            let usage = try UsageStore(file:mediaRestartRoot.appendingPathComponent("usage.json"))
            let rows = await usage.list().filter { $0.modelID == marker.model.id }
            var state: [String:Any] = ["stage":"request-settled","question":question,"lastRole":reply.role.rawValue,
                "lastStatus":reply.status.rawValue,"lastContent":chat.current?.id == marker.conversationID ? reply.content : "<outside-fixture>","busy":chat.busy,"loading":chat.loading,
                "isCompacting":chat.isCompacting,"applicationStateRaw":UIApplication.shared.applicationState.rawValue,
                "usageError":chat.usageError as Any? ?? NSNull(),"fixtureInferenceRecords":rows.count,
                "compactAtPercent":UserDefaults.standard.object(forKey:"compactAtPercent") as Any? ?? NSNull()]
            if let value = chat.current, value.id == marker.conversationID {
                state["fixtureConversation"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
                state["effectiveSettings"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(try XCTUnwrap(chat.loadedModel).settings))
            }
            try record(state)
            XCTAssertEqual(reply.role,.assistant); XCTAssertEqual(reply.status,.complete)
            guard reply.role == .assistant, reply.status == .complete else { throw ModelError.unsupported("The request did not leave a completed assistant reply. A stored user message is not model output.") }
            return reply
        }
        for turn in 1...6 {
            let fixture = manifest.fixtures[(turn - 1) % 2]
            let source = try XCTUnwrap(Bundle.main.url(forResource:(fixture.path as NSString).deletingPathExtension,withExtension:"aiff"))
            let bytes = try Data(contentsOf:source)
            XCTAssertEqual(bytes.count,fixture.bytes); XCTAssertEqual(SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined(),fixture.sha256)
            await chat.stageAttachment(source,type:.aiff); XCTAssertNil(attachments.error)
            let item = try XCTUnwrap(attachments.staged.first)
            let question = turn == 1 ? "Transcribe the speech in this audio." : "Transcribe only the audio attached to this latest message."
            let reply = try await send(question), actual = words(reply.content), expected = words(fixture.text)
            let complete = actual.count >= expected.count && (0...(actual.count - expected.count)).contains { Array(actual[$0..<($0 + expected.count)]) == expected }
            try record(["stage":"audio-turn","turn":turn,"question":question,"reply":reply.content,"fullTranscript":complete,
                "ownedSHA256":item.sha256,"foldThrough":chat.current?.fold?.messageCount ?? 0,"foldSummary":chat.current?.fold?.summary ?? ""])
            XCTAssertTrue(complete,reply.content)
            guard complete else { throw ModelError.unsupported("The complete spoken word sequence was not transcribed.") }
            if turn == 1 {
                let answer = try await send("Which city was mentioned in the audio? Reply with the city name only.")
                XCTAssertEqual(words(answer.content),["lisbon"])
                guard words(answer.content) == ["lisbon"] else { throw ModelError.unsupported("The city-only follow-up failed.") }
            }
        }
        let fold = try XCTUnwrap(ConversationContext.validFold(try XCTUnwrap(chat.current)))
        for word in ["lisbon","cedar","osaka","maple"] { XCTAssertTrue(fold.summary.lowercased().contains(word)) }
        guard ["lisbon","cedar","osaka","maple"].allSatisfy({ fold.summary.lowercased().contains($0) }) else {
            throw ModelError.unsupported("The actual media fold omitted a tested fact.")
        }
        var stopped = false
        let stop = chat.$current.sink { value in
            guard !stopped, chat.busy, let last = value?.messages.last, last.status == .streaming, !last.content.isEmpty else { return }
            stopped = true; chat.cancel()
        }
        chat.draft = "Write a detailed long explanation of the city and project in the latest audio."; await chat.send()
        try await waitUntil(seconds:180) { !chat.busy }; stop.cancel()
        XCTAssertTrue(stopped); XCTAssertEqual(chat.current?.messages.last?.status,.cancelled)
        guard stopped, chat.current?.messages.last?.status == .cancelled else { throw ModelError.unsupported("Product Stop was not observed.") }
        let durable = try await chat.store.conversation(try XCTUnwrap(marker.conversationID))
        XCTAssertEqual(durable.messages,chat.current?.messages); XCTAssertEqual(durable.fold,chat.current?.fold)
        let owned = durable.messages.flatMap { $0.attachments ?? [] }; XCTAssertEqual(owned.count,6)
        for item in owned { _ = try await attachments.store.resolve(item) }
        marker.phase = "armed"; marker.conversation = durable; try mediaRestartWrite(marker)
        try mediaRestartRecord(["phase":"armed","preparedPID":marker.preparedPID,"conversationID":durable.id.uuidString,
            "conversationHash":try mediaRestartHash(durable),"ownedFiles":owned.count,"foldThrough":fold.messageCount,
            "foldSummary":fold.summary,"lastReplyStatus":durable.messages.last!.status.rawValue,"observations":observations])
        // Remain alive at the persisted checkpoint so the host can prove that its
        // SIGKILL actually reaches this PID, rather than assuming a test-host exit.
        while true { try await Task.sleep(nanoseconds:1_000_000_000) }
    }

    @MainActor func testNativeMediaProcessRestartFinish() async throws {
        let marker = try JSONDecoder().decode(MediaRestartMarker.self,from:Data(contentsOf:mediaRestartMarker))
        XCTAssertEqual(marker.phase,"armed"); XCTAssertNotEqual(ProcessInfo.processInfo.processIdentifier,marker.preparedPID)
        guard marker.phase == "armed", ProcessInfo.processInfo.processIdentifier != marker.preparedPID else {
            throw ModelError.unsupported("A distinct cold process and armed durable checkpoint are required.")
        }
        let chat = try XCTUnwrap(ProductDelegate.productState.chat), downloads = try XCTUnwrap(ProductDelegate.productState.downloads)
        let expected = try XCTUnwrap(marker.conversation), attachments = try XCTUnwrap(chat.attachments)
        // Observe the real root scene's launch restoration before any manual
        // restore/open/load call or replacement controller.
        try await waitUntil(seconds:20) { chat.current?.id == expected.id && downloads.models.contains { $0.id == marker.model.id } }
        let automatic = try XCTUnwrap(chat.current); XCTAssertEqual(automatic,expected)
        guard automatic == expected else { throw ModelError.unsupported("Automatic root restoration changed the durable media conversation.") }
        XCTAssertEqual(ConversationContext.validFold(automatic),expected.fold)
        let owned = automatic.messages.flatMap { $0.attachments ?? [] }; XCTAssertEqual(owned.count,6)
        for item in owned { _ = try await attachments.store.resolve(item) }
        XCTAssertEqual(automatic.messages.last?.status,.cancelled)
        var observations: [String:Any] = ["phase":"finish","completed":false,"preparedPID":marker.preparedPID,
            "processIdentifier":ProcessInfo.processInfo.processIdentifier,"automaticRootRestorationVerified":true,
            "conversationHash":try mediaRestartHash(automatic),"ownedFiles":owned.count,"foldSummary":automatic.fold?.summary ?? ""]
        defer { mediaRestartEvidence(observations) }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        await chat.open(automatic); XCTAssertNil(chat.error); XCTAssertEqual(chat.loadedModel?.id,marker.model.id)
        chat.draft = "Which city was spoken in the latest audio? Reply with the city name only."; await chat.send()
        try await waitUntil(seconds:180) { !chat.busy || chat.pendingToolApproval != nil || chat.pendingUserQuestion != nil }
        XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.pendingUserQuestion)
        let reply = try XCTUnwrap(chat.current?.messages.last)
        observations["postColdRestartReply"] = reply.content; observations["replyStatus"] = reply.status.rawValue
        let words = reply.content.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        XCTAssertEqual(words,["osaka"]); XCTAssertEqual(reply.status,.complete)
        guard !chat.busy, chat.error == nil, words == ["osaka"], reply.status == .complete else {
            throw ModelError.unsupported("The original strict cold-restart city recovery failed.")
        }
        try await mediaRestartCleanup(marker)
        observations["preexistingModelsAndConversationsUnchanged"] = true
        observations["previousSelectionRestored"] = true; observations["ownedFilesRemoved"] = owned.allSatisfy { !FileManager.default.fileExists(atPath:attachments.store.displayURL($0).path) }
        XCTAssertEqual(observations["ownedFilesRemoved"] as? Bool,true)
        observations["completed"] = true
        try mediaRestartRecord(observations)
        try FileManager.default.removeItem(at:mediaRestartMarker)
    }

    @MainActor private func mediaRestartCleanup(_ marker: MediaRestartMarker) async throws {
        let chat = try XCTUnwrap(ProductDelegate.productState.chat), downloads = try XCTUnwrap(ProductDelegate.productState.downloads)
        chat.cancel(); try await waitUntil(seconds:30) { !chat.busy }
        if let id = marker.conversationID, let fixture = try? await chat.store.conversation(id) { await chat.delete(fixture); XCTAssertNil(chat.error) }
        if var replacement = downloads.models.first(where: { marker.previousModels[$0.id.uuidString] != nil && $0.state == .ready }) {
            // Release Metal before XCTest exits through C++ global device teardown.
            // This temporary descriptor is never saved to the user's library.
            replacement.backend = .llamaCPU
            await chat.load(replacement); XCTAssertNil(chat.error)
        }
        if let fixture = downloads.models.first(where: { $0.id == marker.model.id }) { try await downloads.remove(fixture) }
        else if FileManager.default.fileExists(atPath:downloads.directory(marker.model).path) { try FileManager.default.removeItem(at:downloads.directory(marker.model)) }
        if let previous = marker.previousSelection { UserDefaults.standard.set(previous,forKey:"selectedConversation") }
        else { UserDefaults.standard.removeObject(forKey:"selectedConversation") }
        await chat.restore()
        let models = try Dictionary(uniqueKeysWithValues:downloads.models.map { ($0.id.uuidString,try mediaRestartHash($0)) })
        let conversations = try Dictionary(uniqueKeysWithValues:await chat.store.all().map { ($0.id.uuidString,try mediaRestartHash($0)) })
        XCTAssertEqual(models,marker.previousModels); XCTAssertEqual(conversations,marker.previousConversations)
        guard models == marker.previousModels, conversations == marker.previousConversations else {
            throw ModelError.unsupported("Preexisting app data changed during media restart validation.")
        }
        XCTAssertEqual(UserDefaults.standard.string(forKey:"selectedConversation"),marker.previousSelection)
    }
    @MainActor func testNativeMediaProcessRestartCleanup() async throws {
        let marker = try JSONDecoder().decode(MediaRestartMarker.self,from:Data(contentsOf:mediaRestartMarker))
        try await mediaRestartCleanup(marker)
        mediaRestartEvidence(["phase":"cleanup-only","completed":true,"preparedPID":marker.preparedPID,"processIdentifier":ProcessInfo.processInfo.processIdentifier,
            "preexistingModelsAndConversationsUnchanged":true,"limitations":"Cleanup is not inference/restart acceptance."])
        try FileManager.default.removeItem(at:mediaRestartMarker)
    }
}
