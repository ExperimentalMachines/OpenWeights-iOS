import XCTest
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativePairedAudioAttachmentHistoryReopenStopAndRecovery() async throws {
        try await pairedAudioFlow(additionalSystem:nil,purpose:"native-paired-audio-attachment-history")
    }
    @MainActor func testNativePairedAudioASRInstructionHistoryReopenStopAndRecovery() async throws {
        try await pairedAudioFlow(additionalSystem:"Perform ASR.",purpose:"native-paired-audio-ASR-instruction-history")
    }
    @MainActor func testNativePairedAudioASRScopedInstructionHistoryReopenStopAndRecovery() async throws {
        try await pairedAudioFlow(additionalSystem:"Perform ASR. Follow the latest user request. Formatting constraints in earlier user messages apply only to those earlier replies.",purpose:"native-paired-audio-ASR-scoped-instruction-history",requireFullTranscripts:true)
    }
    @MainActor func testNativePairedOmniAudioAttachmentHistoryReopenStopAndRecovery() async throws {
        try await pairedAudioFlow(additionalSystem:nil,purpose:"native-paired-omni-audio-attachment-history",requireFullTranscripts:true,omni:true)
    }
    @MainActor func testNativePairedOmniSixAudioTurnsReopenFoldStopAndRecovery() async throws {
        try await pairedAudioFlow(additionalSystem:nil,purpose:"native-paired-omni-six-audio-turns",requireFullTranscripts:true,omni:true,growingHistory:true)
    }
    @MainActor private func pairedAudioFlow(additionalSystem: String?, purpose: String, requireFullTranscripts: Bool = false, omni: Bool = false, growingHistory: Bool = false) async throws {
        struct Manifest: Decodable {
            struct Fixture: Decodable { var path: String; var bytes: Int; var sha256: String; var text: String }
            var repository: String; var revision: String; var files: [ModelFile]; var fixtures: [Fixture]
        }
        let manifestURL = try XCTUnwrap(Bundle.main.url(forResource:omni ? "omni-audio-validation-artifact" : "audio-validation-artifact",withExtension:"json"))
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifestURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-audio-" + UUID().uuidString)
        let suite = "native-audio-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        let cache = support.appendingPathComponent(omni ? "OmniAudioValidation" : "AudioValidation")
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let journal = cache.appendingPathComponent("audio-flow-" + UUID().uuidString + ".json")
        var observations: [[String:Any]] = [], completed = false
        var observedRuntime: NativeObservedRuntime?
        func record(_ value: [String:Any]) {
            observations.append(value)
            if omni {
                do {
                    try JSONSerialization.data(withJSONObject:["purpose":purpose,"repository":manifest.repository,"revision":manifest.revision,"observations":observations],options:[.prettyPrinted,.sortedKeys]).write(to:journal,options:.atomic)
                } catch { XCTFail("Audio phase journal: \(error.localizedDescription)") }
            }
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":purpose,"completed":completed,"additionalSystem":additionalSystem ?? "","requireFullTranscripts":requireFullTranscripts,"growingHistory":growingHistory,"transcriptPolicy":omni ? "complete-spoken-word-sequence-with-optional-label" : "exact-normalized-word-sequence-when-required","journal":omni ? journal.lastPathComponent : "",
                "repository":manifest.repository,"revision":manifest.revision,"observations":observations,"runtime":observedRuntime?.snapshot() as Any? ?? NSNull(),
                "limitations":["Two synthetic English speech clips, repeated across six audio turns when growingHistory is enabled, and one manifest-pinned base/projector artifact. This verifies scoped audio input delivery, not general ASR quality, audio output, performance, energy, fit or a recommended model.",
                    "Direct product APIs and same-process store reopen. No microphone, system picker, external provider, user Stop gesture, OS suspension or process termination."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = purpose; attachment.lifetime = .keepAlways; add(attachment)
        }
        let details = try await HubClient.details(manifest.repository,revision:manifest.revision,transport:HubAPITransport(useStoredCredential:false))
        let base = try XCTUnwrap(details.siblings.first { $0.rfilename == manifest.files[0].path })
        let projector = try XCTUnwrap(details.siblings.first { $0.rfilename == manifest.files[1].path })
        var model = try HubClient.gguf(details,file:base,projector:projector)
        XCTAssertEqual(model.files,manifest.files)
        model.id = try XCTUnwrap(UUID(uuidString:omni ? "9C4CBED5-1FCD-4223-9785-B6F43FA6634B" : "C74F1D6B-AC55-4B93-80B1-75CB9E86A26A"))
        model.settings.contextTokens = 4096; model.settings.outputTokens = 96; model.settings.temperature = 0
        model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.thinking = false
        model.settings.systemPrompt = additionalSystem
        let downloads = ModelDownloads(root:cache.appendingPathComponent("Models"),library:try ModelLibrary(file:cache.appendingPathComponent("models.json")),sessionIdentifier:omni ? "org.experimentalmachines.openweights.audio-omni-validation" : "org.experimentalmachines.openweights.audio-validation")
        defer { downloads.cancelAllTransfers() }
        await downloads.restore()
        if omni {
            let capacity = try XCTUnwrap(try support.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage)
            let plannedBytes = manifest.files.reduce(Int64(0)) { $0 + Int64($1.bytes ?? 0) }
            let existingReady = downloads.models.contains { $0.id == model.id && $0.state == .ready }
            record(["stage":"storage-and-memory-preflight","plannedArtifactBytes":plannedBytes,"freeImportantUsageBytes":capacity,"appHeadroomBytes":OWRuntimeSession.availableMemoryBytes().uint64Value,"physicalMemoryBytes":ProcessInfo.processInfo.physicalMemory,"thermalState":ProcessInfo.processInfo.thermalState.rawValue,"existingReady":existingReady])
            if !existingReady && capacity < plannedBytes + 64 * 1024 * 1024 {
                throw NSError(domain:"AudioValidation",code:1,userInfo:[NSLocalizedDescriptionKey:"Insufficient available storage for pinned audio artifacts and bounded download chunks."])
            }
        }
        if let existing = downloads.models.first(where: { $0.id == model.id }) {
            if existing.state != .ready { await downloads.resume(existing) }
        } else { await downloads.install(model) }
        try await waitUntil(seconds:omni ? 1200 : 480) { downloads.models.first(where: { $0.id == model.id })?.state == .ready || downloads.error != nil || downloads.models.first(where: { $0.id == model.id })?.state == .failed }
        XCTAssertNil(downloads.error)
        let ready = try XCTUnwrap(downloads.models.first { $0.id == model.id }); XCTAssertEqual(ready.state,.ready,ready.failure ?? "")
        for file in model.files {
            let url = try file.destination(in:downloads.directory(ready))
            if omni {
                record(["stage":"file-verification-started","file":file.path,"appHeadroomBytes":OWRuntimeSession.availableMemoryBytes().uint64Value])
                // Production acquisition verifies off the UI thread. Its independent
                // validation must not block that thread across multi-gigabyte files.
                try await Task.detached { try ModelDownloads.verify(url,file:file) }.value
                record(["stage":"file-verified","file":file.path,"appHeadroomBytes":OWRuntimeSession.availableMemoryBytes().uint64Value])
            } else { try ModelDownloads.verify(url,file:file) }
        }
        model.state = .ready; try await downloads.saveSettings(model)
        record(["stage":"download-verified","files":model.files.map { ["path":$0.path,"bytes":$0.bytes ?? 0,"sha256":$0.sha256 ?? ""] }])
        let owned = try ChatAttachmentStore(root:root.appendingPathComponent("Owned")), attachments = AttachmentController(store:owned)
        let file = root.appendingPathComponent("conversations.json"), store = try ConversationStore(file:file)
        let chat = ChatController(store:store,downloads:downloads,defaults:defaults,runtimeFactory: { local in
            let real = try RuntimeFactory.make(local)
            guard growingHistory else { return real }
            let observed = NativeObservedRuntime(real); observedRuntime = observed; return observed
        },attachments:attachments)
        await chat.load(model); XCTAssertNil(chat.error); XCTAssertTrue(chat.mediaSupport.audio); XCTAssertFalse(chat.mediaSupport.marker.isEmpty)
        record(["stage":"model-loaded","audio":chat.mediaSupport.audio,"vision":chat.mediaSupport.vision,"marker":chat.mediaSupport.marker,"appHeadroomBytes":OWRuntimeSession.availableMemoryBytes().uint64Value])
        func stage(_ index: Int) async throws -> ChatAttachment {
            let fixture = manifest.fixtures[index], name = (fixture.path as NSString).deletingPathExtension
            let source = try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:"aiff"))
            let data = try Data(contentsOf:source)
            XCTAssertEqual(data.count,fixture.bytes); XCTAssertEqual(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),fixture.sha256)
            let temporary = root.appendingPathComponent(fixture.path); try data.write(to:temporary)
            await chat.stageAttachment(temporary,type:.aiff); XCTAssertNil(attachments.error)
            let item = try XCTUnwrap(attachments.staged.first), url = try await owned.resolve(item)
            let decoded = try AVAudioFile(forReading:url)
            XCTAssertEqual(decoded.fileFormat.sampleRate,16_000); XCTAssertEqual(decoded.fileFormat.channelCount,1); XCTAssertGreaterThan(decoded.length,16_000)
            try FileManager.default.removeItem(at:temporary)
            record(["stage":"audio-normalized","source":fixture.path,"sourceSHA256":fixture.sha256,"spokenText":fixture.text,"ownedSHA256":item.sha256,"sampleRate":decoded.fileFormat.sampleRate,"channels":decoded.fileFormat.channelCount,"frames":decoded.length])
            return item
        }
        func send(_ question: String, stage: String, expected: [String]) async throws {
            chat.draft = question; await chat.send(); try await waitUntil(seconds:120) { !chat.busy }
            XCTAssertNil(chat.error)
            let reply = try XCTUnwrap(chat.current?.messages.last); XCTAssertEqual(reply.role,.assistant); XCTAssertEqual(reply.status,.complete)
            guard reply.role == .assistant, reply.status == .complete else { throw ModelError.unsupported("The audio request did not leave a completed assistant reply.") }
            record(["stage":stage,"question":question,"reply":reply.content,"status":reply.status.rawValue,"contextUsed":chat.contextUsed,"uncountedMedia":chat.contextIncludesUncountedMedia,"contextIsExact":chat.contextIsExact,"error":chat.error ?? "","foldThrough":chat.current?.fold?.messageCount ?? 0,"foldSummary":chat.current?.fold?.summary ?? "","visibleMessages":chat.current?.messages.count ?? 0])
            for word in expected { XCTAssertTrue(reply.content.lowercased().contains(word.lowercased()),reply.content) }
        }
        let firstAudio = try await stage(0)
        try await send("Transcribe the speech in this audio.",stage:"first-audio-transcription",expected:["Lisbon","Cedar"])
        func transcriptWords(_ value: String) -> [String] {
            value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        func assertTranscript(_ index: Int) {
            let actual = transcriptWords(chat.current?.messages.last?.content ?? ""), expected = transcriptWords(manifest.fixtures[index].text)
            if omni {
                let containsCompleteSpeech = actual.count >= expected.count && (0...(actual.count - expected.count)).contains { Array(actual[$0..<($0 + expected.count)]) == expected }
                XCTAssertTrue(containsCompleteSpeech,"Missing complete spoken word sequence: \(chat.current?.messages.last?.content ?? "")")
            } else { XCTAssertEqual(actual,expected) }
        }
        if requireFullTranscripts { assertTranscript(0) }
        XCTAssertEqual(chat.current?.messages.first?.attachments,[firstAudio]); XCTAssertFalse(attachments.hasStaged)
        try await send("Which city was mentioned in the audio? Reply with the city name only.",stage:"retained-audio-text-follow-up",expected:["Lisbon"])
        if requireFullTranscripts { if omni { XCTAssertEqual(transcriptWords(chat.current?.messages.last?.content ?? ""),["lisbon"]) } else { XCTAssertEqual(chat.current?.messages.last?.content.trimmingCharacters(in:.whitespacesAndNewlines),"Lisbon") } }
        let saved = try XCTUnwrap(chat.current), reopened = try ConversationStore(file:file)
        let durable = try await reopened.conversation(saved.id); XCTAssertEqual(durable.messages,saved.messages)
        let created = await chat.newConversation(); XCTAssertTrue(created); await chat.open(durable); XCTAssertNil(chat.error)
        XCTAssertEqual(chat.current?.messages,saved.messages); _ = try await owned.resolve(firstAudio)
        record(["stage":"store-reopen-and-open","messages":durable.messages.count,"attachmentPreserved":true])
        let secondAudio = try await stage(1)
        try await send("Transcribe only the audio attached to this latest message.",stage:"second-audio-with-history",expected:["Osaka","Maple"])
        if requireFullTranscripts { assertTranscript(1) }
        XCTAssertEqual(chat.current?.messages.suffix(2).first?.attachments,[secondAudio])
        var growingAudio: [ChatAttachment] = []
        if growingHistory {
            for turn in 3...6 {
                let index = (turn - 1) % 2
                growingAudio.append(try await stage(index))
                record(["stage":"growing-audio-send-started","audioTurn":turn,"visibleMessages":chat.current?.messages.count ?? 0])
                try await send("Transcribe only the audio attached to this latest message.",stage:"audio-turn-\(turn)",expected:[])
                guard chat.error == nil else { return }
                assertTranscript(index)
                for item in [firstAudio,secondAudio] + growingAudio { _ = try await owned.resolve(item) }
            }
            XCTAssertNotNil(chat.current?.fold,"Six audio turns must make space through media-aware folding.")
            let foldedSummary = chat.current?.fold?.summary.lowercased() ?? ""
            for fact in ["lisbon","cedar","osaka","maple"] { XCTAssertTrue(foldedSummary.contains(fact),"Media summary lost \(fact): \(foldedSummary)") }
            XCTAssertTrue(chat.contextIsExact); XCTAssertFalse(chat.contextIncludesUncountedMedia)
            XCTAssertEqual(chat.current?.messages.filter { $0.role == .user && $0.attachments?.isEmpty == false }.count,6)
            let all = try XCTUnwrap(chat.current), disk = try await ConversationStore(file:file).conversation(all.id)
            XCTAssertEqual(disk.messages,all.messages); XCTAssertEqual(disk.fold,all.fold)
            record(["stage":"growing-history-store-reopened","audioTurns":6,"visibleMessages":disk.messages.count,"foldThrough":disk.fold?.messageCount ?? 0,"foldSummary":disk.fold?.summary ?? ""])
        }
        var stopped = false
        let observer = chat.$current.sink { value in
            guard !stopped,chat.busy,let last=value?.messages.last,last.role == .assistant,last.status == .streaming,!last.content.isEmpty else { return }
            stopped = true; chat.cancel()
        }
        chat.draft = "Write a detailed long explanation of the city and project in the latest audio."
        await chat.send(); try await waitUntil(seconds:120) { !chat.busy }; observer.cancel()
        XCTAssertTrue(stopped); XCTAssertEqual(chat.current?.messages.last?.status,.cancelled)
        record(["stage":"stop-on-published-stream","stopped":stopped,"reply":chat.current?.messages.last?.content ?? ""])
        _ = try await owned.resolve(firstAudio); _ = try await owned.resolve(secondAudio)
        try await send("Which city was spoken in the latest audio? Reply with the city name only.",stage:"post-stop-recovery",expected:["Osaka"])
        if requireFullTranscripts { if omni { XCTAssertEqual(transcriptWords(chat.current?.messages.last?.content ?? ""),["osaka"]) } else { XCTAssertEqual(chat.current?.messages.last?.content.trimmingCharacters(in:.whitespacesAndNewlines),"Osaka") } }
        if growingHistory, let observedRuntime {
            let streams = observedRuntime.snapshot()["streams"] as? [[String:Any]] ?? []
            let mediaStreams = streams.filter { $0["countedPrompt"] != nil }
            XCTAssertGreaterThanOrEqual(mediaStreams.count,8)
            for stream in mediaStreams {
                let count = try XCTUnwrap(stream["countedPrompt"] as? Int)
                XCTAssertEqual(count,stream["countedAgain"] as? Int); XCTAssertEqual(stream["countIsExact"] as? Bool,true)
                let usage = try XCTUnwrap(stream["usage"] as? [String:Any])
                XCTAssertEqual(count,(usage["promptTokens"] as? Int ?? -1) + (usage["cachedTokens"] as? Int ?? -1))
            }
            record(["stage":"media-counts-match-actual-native-usage","streams":mediaStreams.count])
            let readings = streams.filter { stream in
                guard let messages = stream["messages"] as? [[String:String]] else { return false }
                return messages.last?["content"]?.hasPrefix("Read only this attached file.") == true
            }
            let summaries = streams.filter { stream in
                guard let messages = stream["messages"] as? [[String:String]] else { return false }
                return messages.last?["content"]?.hasPrefix(ConversationCompactor.instruction) == true
            }
            let records = chat.current?.fold?.summary ?? ""
            XCTAssertTrue(records.hasPrefix(ConversationCompactor.mediaRecordsHeading)); XCTAssertTrue(summaries.isEmpty)
            XCTAssertGreaterThanOrEqual(readings.count,4)
            for reading in readings {
                let reply = try XCTUnwrap(reading["reply"] as? [String:Any])
                let literal = try XCTUnwrap(reply["content"] as? String).trimmingCharacters(in:.whitespacesAndNewlines)
                XCTAssertFalse(literal.isEmpty); XCTAssertTrue(records.contains(literal),"Fold rewrote or omitted an actual file reading")
            }
            record(["stage":"verbatim-media-records-verified","independentReadings":readings.count,"textSummaryStreams":summaries.count,"recordCharacters":records.utf16.count])
        }
        await chat.delete(try XCTUnwrap(chat.current)); XCTAssertNil(chat.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath:owned.displayURL(firstAudio).path)); XCTAssertFalse(FileManager.default.fileExists(atPath:owned.displayURL(secondAudio).path))
        for item in growingAudio { XCTAssertFalse(FileManager.default.fileExists(atPath:owned.displayURL(item).path)) }
        record(["stage":"last-reference-delete","bothOwnedAudioFilesRemoved":true])
        completed = true
    }
}
