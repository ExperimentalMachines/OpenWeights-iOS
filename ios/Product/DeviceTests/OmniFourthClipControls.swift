import XCTest
import UIKit
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeOmniFourthClipCapturedHistoryControls() async throws {
        try await omniFourthClipControls(cancelDuringFold: false)
    }
    @MainActor func testNativeOmniFoldCancellationMessageAndResendControls() async throws {
        try await omniFourthClipControls(cancelDuringFold: true)
    }
    @MainActor private func omniFourthClipControls(cancelDuringFold: Bool) async throws {
        struct Manifest: Decodable {
            struct Clip: Decodable { var path: String; var bytes: Int; var sha256: String; var text: String }
            var repository: String; var revision: String; var files: [ModelFile]; var fixtures: [Clip]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "omni-audio-validation-artifact", withExtension: "json"))))
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniAudioValidation")
        let cachedLibrary = try ModelLibrary(file: cache.appendingPathComponent("models.json"))
        let cachedModels = await cachedLibrary.list()
        var model = try XCTUnwrap(cachedModels.first { $0.id.uuidString == "9C4CBED5-1FCD-4223-9785-B6F43FA6634B" && $0.state == .ready })
        XCTAssertEqual(model.repository, manifest.repository); XCTAssertEqual(model.revision, manifest.revision)
        XCTAssertEqual(model.files, manifest.files); XCTAssertNil(model.settings.systemPrompt)
        model.settings.contextTokens = 4096; model.settings.outputTokens = 96; model.settings.threads = 4
        model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1
        model.settings.thinking = false; model.settings.reasoningEffort = nil
        let directory = cache.appendingPathComponent("Models").appendingPathComponent(model.id.uuidString)
        let cachedMetadata = try Data(contentsOf: cache.appendingPathComponent("models.json"))
        for file in model.files {
            let path = try file.destination(in: directory)
            try await Task.detached { try ModelDownloads.verify(path, file: file) }.value
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-fourth-clip-" + UUID().uuidString)
        let suite = "omni-fourth-clip-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let trigger = Double(ProcessInfo.processInfo.environment["OW_AUDIO_COMPACT_AT"] ?? "75") ?? .nan
        guard [75.0, 99.0].contains(trigger) else { throw ModelError.unsupported("Unknown fourth-clip diagnostic compaction threshold.") }
        defaults.set(trigger, forKey: "compactAtPercent")
        let journal = cache.appendingPathComponent("audio-fourth-clip-" + UUID().uuidString + ".json")
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let runtime = NativeObservedRuntime(try RuntimeFactory.make(model), repeatMediaCount: false)
        var observations: [[String: Any]] = [], completed = false
        func record(_ value: [String: Any]) throws {
            observations.append(value)
            try JSONSerialization.data(withJSONObject: ["purpose": "native-omni-fourth-clip-captured-history-controls", "observations": observations], options: [.prettyPrinted, .sortedKeys]).write(to: journal, options: .atomic)
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            let value: [String: Any] = ["purpose": cancelDuringFold ? "native-omni-fold-cancellation-message-and-resend-controls" : "native-omni-fourth-clip-captured-history-controls", "completed": completed, "cancelDuringFold": cancelDuringFold,
                "repository": manifest.repository, "revision": manifest.revision, "journal": journal.lastPathComponent, "compactAtPercent": trigger,
                "observations": observations, "runtime": runtime.snapshot(),
                "limitations": ["Four real controller audio turns and their actual city follow-up are captured in this run. The earlier failed normal-root cohort did not retain its complete prompt, so these are not a byte-identical reconstruction of that historical failure.",
                    "Test capture passes requests through without additional pre-stream counts. Original controller guidance, settings, history and attachment bytes are unchanged. Replay variants are diagnostics only, with per-request answer acceptance recorded separately from method execution.",
                    "Reset clears KV/reply state but retains independent media embeddings. It is not a fresh model/projector load. Two repeated synthetic English clips and one artifact/device do not establish general speech quality, performance, energy, peak memory or cause.",
                    "Uses a temporary controller/store/library beside verified cached model files. No original user models/chats, provider gestures, OS lifecycle, cloud execution or production policy changes."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "native-omni-fourth-clip-captured-history-controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let downloads = ModelDownloads(root: cache.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: "org.experimentalmachines.openweights.fourth-clip." + UUID().uuidString)
        try record(["stage": "compaction-preflight", "isolatedCompactAtPercent": trigger,
            "normalAppCompactAtPercent": UserDefaults.standard.object(forKey: "compactAtPercent") as Any? ?? NSNull()])
        defer { downloads.cancelAllTransfers() }
        await downloads.restore(); try await downloads.save(model)
        let owned = try ChatAttachmentStore(root: root.appendingPathComponent("Owned")), attachments = AttachmentController(store: owned)
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, defaults: defaults, runtimeFactory: { _ in runtime }, attachments: attachments)
        let created = await chat.newConversation(); XCTAssertTrue(created)
        await chat.load(model); XCTAssertNil(chat.error)
        guard chat.error == nil else { throw ModelError.unsupported(chat.error ?? "Model load failed.") }
        let firstQuestion = "Transcribe the speech in this audio."
        let cityQuestion = "Which city was mentioned in the audio? Reply with the city name only."
        let latestQuestion = "Transcribe only the audio attached to this latest message."
        func words(_ value: String) -> [String] { value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        func containsSpeech(_ value: String, _ expected: String) -> Bool {
            let actual = words(value), wanted = words(expected)
            return actual.count >= wanted.count && (0...(actual.count - wanted.count)).contains { Array(actual[$0..<($0 + wanted.count)]) == wanted }
        }
        func send(_ question: String) async throws -> StoredMessage {
            chat.draft = question; await chat.send(); try await waitUntil(seconds: 180) { !chat.busy }
            XCTAssertNil(chat.error); XCTAssertNil(chat.pendingToolApproval); XCTAssertNil(chat.pendingUserQuestion)
            guard chat.error == nil else { throw ModelError.unsupported(chat.error ?? "Controller request failed.") }
            let reply = try XCTUnwrap(chat.current?.messages.last); XCTAssertEqual(reply.role, .assistant); XCTAssertEqual(reply.status, .complete)
            guard reply.role == .assistant else { throw ModelError.unsupported("The last stored message is not an assistant reply.") }
            return reply
        }
        for turn in 1...4 {
            let clip = manifest.fixtures[(turn - 1) % 2]
            let path = try XCTUnwrap(Bundle.main.url(forResource: (clip.path as NSString).deletingPathExtension, withExtension: "aiff"))
            let data = try Data(contentsOf: path)
            XCTAssertEqual(data.count, clip.bytes); XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), clip.sha256)
            await chat.stageAttachment(path, type: .aiff); XCTAssertNil(attachments.error)
            let item = try XCTUnwrap(attachments.staged.first)
            if cancelDuringFold, turn == 4 {
                let before = (runtime.snapshot()["streams"] as? [[String:Any]])?.count ?? -1
                var stopped = false
                let observer = chat.$isCompacting.sink { active in
                    guard active, !stopped else { return }
                    stopped = true; chat.cancel()
                }
                chat.draft = latestQuestion; await chat.send(); try await waitUntil(seconds:180) { !chat.busy }; observer.cancel()
                let pending = try XCTUnwrap(chat.current?.messages.last)
                let after = (runtime.snapshot()["streams"] as? [[String:Any]])?.count ?? -1
                XCTAssertTrue(stopped); XCTAssertNil(chat.error); XCTAssertEqual(before,after)
                XCTAssertEqual(pending.role,.user); XCTAssertEqual(pending.status,.complete); XCTAssertEqual(pending.content,latestQuestion)
                XCTAssertNil(chat.current?.fold); XCTAssertEqual(pending.attachments,[item])
                _ = try await owned.resolve(item)
                try record(["stage":"cancelled-before-assistant","stopOnPublishedCompaction":stopped,"lastRole":pending.role.rawValue,
                    "lastStatus":pending.status.rawValue,"lastContent":pending.content,"streamsBefore":before,"streamsAfter":after,
                    "busy":chat.busy,"error":chat.error as Any? ?? NSNull(),"conversation":try JSONSerialization.jsonObject(with:JSONEncoder().encode(try XCTUnwrap(chat.current)))])
                await chat.editAndResend(messageID:pending.id,text:latestQuestion); try await waitUntil(seconds:180) { !chat.busy }
                let recovered = try XCTUnwrap(chat.current?.messages.last)
                XCTAssertNil(chat.error); XCTAssertEqual(recovered.role,.assistant); XCTAssertEqual(recovered.status,.complete)
                XCTAssertTrue(containsSpeech(recovered.content,clip.text),recovered.content)
                for attachment in try XCTUnwrap(chat.current).messages.flatMap({ $0.attachments ?? [] }) { _ = try await owned.resolve(attachment) }
                XCTAssertEqual(try Data(contentsOf:cache.appendingPathComponent("models.json")),cachedMetadata)
                try record(["stage":"edit-and-resend-recovery","reply":recovered.content,"lastRole":recovered.role.rawValue,
                    "fullTranscript":containsSpeech(recovered.content,clip.text),"ownedAudioFiles":chat.current?.messages.flatMap({ $0.attachments ?? [] }).count ?? 0,"cachedLibraryBytesUnchanged":true])
                await runtime.reset(); completed = true; return
            }
            let reply = try await send(turn == 1 ? firstQuestion : latestQuestion)
            let accepted = containsSpeech(reply.content, clip.text)
            try record(["stage": "controller-audio-turn", "turn": turn, "reply": reply.content, "fullTranscript": accepted,
                "ownedSHA256": item.sha256, "foldThrough": chat.current?.fold?.messageCount ?? 0])
            XCTAssertTrue(accepted, reply.content)
            if turn == 1 {
                let city = try await send(cityQuestion)
                try record(["stage": "controller-city-follow-up", "reply": city.content, "accepted": words(city.content) == ["lisbon"]])
                XCTAssertEqual(words(city.content), ["lisbon"])
            }
        }
        let (frozen, settings) = try XCTUnwrap(runtime.capturedMediaRequest())
        XCTAssertEqual(frozen.messages.last?["content"], latestQuestion); XCTAssertEqual(frozen.mediaPaths.last?.count, 1)
        XCTAssertEqual(settings.contextTokens, 4096); XCTAssertEqual(settings.outputTokens, 96); XCTAssertEqual(settings.temperature, 0)
        var hashes: [String: String] = [:]
        for path in Set(frozen.mediaPaths.flatMap { $0 }) {
            hashes[path] = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        }
        let conversation = try XCTUnwrap(chat.current)
        if trigger == 99 { XCTAssertNil(conversation.fold); XCTAssertEqual(frozen.mediaPaths.flatMap { $0 }.count, 4) }
        try record(["stage": "frozen-actual-fourth-request", "messages": frozen.messages, "mediaPaths": frozen.mediaPaths,
            "mediaSHA256ByMessage": frozen.mediaPaths.map { $0.map { hashes[$0]! } },
            "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)),
            "conversation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)),
            "countAfterGeneration": try await runtime.promptSize(prompt: frozen, settings: settings, tools: []).tokens])
        func replay(_ label: String, _ prompt: RuntimePrompt) async throws {
            await runtime.reset()
            var final: RuntimeReply?, streamed = ""
            for try await event in runtime.stream(prompt: prompt, settings: settings, tools: []) {
                switch event { case .token(let piece): streamed += piece; case .reply(let reply): XCTAssertNil(final); final = reply }
            }
            let reply = try XCTUnwrap(final); XCTAssertEqual(reply.content, streamed); XCTAssertFalse(reply.cancelled)
            XCTAssertEqual(reply.cachedTokens, 0); XCTAssertEqual(reply.stopReason, .endOfTurn); XCTAssertTrue(reply.toolCalls.isEmpty)
            let count = try await runtime.promptSize(prompt: prompt, settings: settings, tools: [])
            XCTAssertTrue(count.exact)
            if let usage = reply.usage { XCTAssertEqual(count.tokens, usage.promptTokens + usage.cachedTokens) }
            try record(["stage": label, "reset": true, "messages": prompt.messages, "mediaPaths": prompt.mediaPaths,
                "mediaSHA256ByMessage": prompt.mediaPaths.map { $0.map { hashes[$0]! } }, "reply": reply.content,
                "cachedTokens": reply.cachedTokens, "contextUsed": reply.contextUsed, "generatedTokens": reply.generatedTokens,
                "countAfterGeneration": count.tokens, "stopReason": reply.stopReason.rawValue,
                "fullTranscript": containsSpeech(reply.content, manifest.fixtures[1].text)])
        }
        for attempt in 1...2 { try await replay("C2-reset-identical-fourth-\(attempt)", frozen) }
        let latestOnly = RuntimePrompt(messages: [frozen.messages[0], frozen.messages.last!], mediaPaths: [[], frozen.mediaPaths.last!])
        for attempt in 1...2 { try await replay("C3-reset-latest-only-\(attempt)", latestOnly) }
        if let index = frozen.messages.firstIndex(where: { $0["role"] == "user" && $0["content"] == cityQuestion }), index + 1 < frozen.messages.count, frozen.messages[index + 1]["role"] == "assistant" {
            var noCity = frozen; noCity.messages.removeSubrange(index...(index + 1)); noCity.mediaPaths.removeSubrange(index...(index + 1))
            for attempt in 1...2 { try await replay("C4-reset-without-earlier-city-round-\(attempt)", noCity) }
        } else { try record(["stage": "C4-not-applicable", "reason": "The actual fourth prompt has already folded the city round."]) }
        var noLatest = frozen; noLatest.mediaPaths[noLatest.mediaPaths.count - 1] = []
        try await replay("C5-reset-without-latest-audio", noLatest)
        await runtime.reset()
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent("models.json")), cachedMetadata)
        try record(["stage": "finished", "cachedLibraryBytesUnchanged": true])
        completed = true
    }
}
