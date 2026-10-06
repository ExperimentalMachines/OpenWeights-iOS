import XCTest
import UIKit
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeAudioLatestClipHistoryControls() async throws {
        struct Manifest: Decodable {
            struct Fixture: Decodable { var path: String; var bytes: Int; var sha256: String }
            var repository: String; var revision: String; var files: [ModelFile]; var fixtures: [Fixture]
        }
        let manifestURL = try XCTUnwrap(Bundle.main.url(forResource:"audio-validation-artifact",withExtension:"json"))
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifestURL))
        let cache = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AudioValidation")
        let library = try ModelLibrary(file:cache.appendingPathComponent("models.json")), models = await library.list()
        var model = try XCTUnwrap(models.first { $0.id.uuidString == "C74F1D6B-AC55-4B93-80B1-75CB9E86A26A" && $0.state == .ready })
        XCTAssertEqual(model.repository,manifest.repository); XCTAssertEqual(model.revision,manifest.revision); XCTAssertEqual(model.files,manifest.files)
        model.settings.systemPrompt = "Perform ASR."
        let directory = cache.appendingPathComponent("Models").appendingPathComponent(model.id.uuidString)
        for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-history-controls-" + UUID().uuidString)
        let owned = try ChatAttachmentStore(root:root), attachments = AttachmentController(store:owned)
        let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
        XCTAssertTrue(runtime.mediaSupport.audio)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String:Any]] = [], normalized: [String] = []
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at:root)
            let evidence: [String:Any] = ["purpose":"native-audio-latest-clip-history-controls","repository":manifest.repository,
                "revision":manifest.revision,"normalizedAudioSHA256":normalized,"observations":observations,
                "limitations":["Controlled prompt/history/cache/media-presence diagnostics on two fixed English clips. Method success checks execution, not all answer-quality expectations.",
                    "Historical question wording and media omissions are authored controls, not newly generated historical turns. They do not change original app/test prompts or defaults.",
                    "No original-weight reference, general ASR, audio output, speed, energy, fit, native UI gesture, OS lifecycle or multi-device claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "native-audio-latest-clip-history-controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        var paths: [String] = []
        for fixture in manifest.fixtures {
            let name = (fixture.path as NSString).deletingPathExtension
            let source = try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:"aiff")), data = try Data(contentsOf:source)
            XCTAssertEqual(data.count,fixture.bytes); XCTAssertEqual(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),fixture.sha256)
            await attachments.stage(source,type:.aiff,support:runtime.mediaSupport); XCTAssertNil(attachments.error)
            let item = try XCTUnwrap(attachments.staged.last), url = try await owned.resolve(item)
            normalized.append(item.sha256); paths.append(url.path)
        }
        XCTAssertEqual(paths.count,2)
        let system = ["role":"system","content":model.settings.systemInstructions(base:ChatController.systemPrompt,toolsAvailable:false)]
        let firstQuestion = ["role":"user","content":"Transcribe the speech in this audio."]
        let cityQuestion = ["role":"user","content":"Which city was mentioned in the audio? Reply with the city name only."]
        let latestQuestion = ["role":"user","content":"Transcribe only the audio attached to this latest message."]
        func request(_ name: String, _ prompt: RuntimePrompt, reset: Bool, expected: [String]) async throws -> RuntimeReply {
            if reset { await runtime.reset() }
            var final: RuntimeReply?, streamed = ""
            for try await event in runtime.stream(prompt:prompt,settings:model.settings,tools:[]) {
                switch event { case .token(let piece): streamed += piece; case .reply(let reply): final = reply }
            }
            let reply = try XCTUnwrap(final); XCTAssertEqual(reply.content,streamed); XCTAssertFalse(reply.cancelled)
            if reset { XCTAssertEqual(reply.cachedTokens,0) }
            let mediaSHA = prompt.mediaPaths.map { row in row.map { path in normalized[paths.firstIndex(of:path)!] } }
            let missing = expected.filter { !reply.content.lowercased().contains($0.lowercased()) }
            observations.append(["stage":name,"messages":prompt.messages,"mediaSHA256ByMessage":mediaSHA,"reset":reset,
                "reply":reply.content,"promptContent":reply.promptContent ?? "","cachedTokens":reply.cachedTokens,
                "contextUsed":reply.contextUsed,"generatedTokens":reply.generatedTokens,"stopReason":reply.stopReason.rawValue,
                "expectedWords":expected,"missingWords":missing,"answerAccepted":missing.isEmpty])
            return reply
        }
        let first = try await request("fresh-first-transcription",RuntimePrompt(messages:[system,firstQuestion],mediaPaths:[[],[paths[0]]]),reset:true,expected:["Lisbon","Cedar"])
        let firstAnswer = ["role":"assistant","content":first.promptContent ?? first.content]
        let followUp = try await request("retained-first-city-follow-up",RuntimePrompt(messages:[system,firstQuestion,firstAnswer,cityQuestion],mediaPaths:[[],[paths[0]],[],[]]),reset:false,expected:["Lisbon"])
        let cityAnswer = ["role":"assistant","content":followUp.promptContent ?? followUp.content]
        let fullMessages = [system,firstQuestion,firstAnswer,cityQuestion,cityAnswer,latestQuestion]
        let fullPaths: [[String]] = [[],[paths[0]],[],[],[],[paths[1]]]
        let full = RuntimePrompt(messages:fullMessages,mediaPaths:fullPaths)
        _ = try await request("retained-full-history-latest-clip",full,reset:false,expected:["Osaka","Maple"])
        _ = try await request("reset-identical-full-history-latest-clip",full,reset:true,expected:["Osaka","Maple"])
        _ = try await request("fresh-second-same-latest-question",RuntimePrompt(messages:[system,latestQuestion],mediaPaths:[[],[paths[1]]]),reset:true,expected:["Osaka","Maple"])
        _ = try await request("fresh-second-original-transcription-question",RuntimePrompt(messages:[system,firstQuestion],mediaPaths:[[],[paths[1]]]),reset:true,expected:["Osaka","Maple"])
        _ = try await request("reset-history-without-city-round",RuntimePrompt(messages:[system,firstQuestion,firstAnswer,latestQuestion],mediaPaths:[[],[paths[0]],[],[paths[1]]]),reset:true,expected:["Osaka","Maple"])
        var noFormat = fullMessages
        noFormat[3] = ["role":"user","content":"Which city was mentioned in the audio?"]
        _ = try await request("reset-history-without-earlier-format-instruction",RuntimePrompt(messages:noFormat,mediaPaths:fullPaths),reset:true,expected:["Osaka","Maple"])
        var explicit = fullMessages
        explicit[5] = ["role":"user","content":"Transcribe all words in the latest audio, including the city and project. Do not shorten the transcript."]
        _ = try await request("reset-history-explicit-complete-transcription",RuntimePrompt(messages:explicit,mediaPaths:fullPaths),reset:true,expected:["Osaka","Maple"])
        var scoped = fullMessages
        scoped[0] = ["role":"system","content":system["content"]! + " Follow the latest user request. Formatting constraints in earlier user messages apply only to those earlier replies."]
        _ = try await request("reset-identical-history-scoped-system-instruction",RuntimePrompt(messages:scoped,mediaPaths:fullPaths),reset:true,expected:["Osaka","Maple"])
        let scopedFirst = RuntimePrompt(messages:[scoped[0],firstQuestion],mediaPaths:[[],[paths[0]]])
        _ = try await request("reset-fresh-scoped-first-transcription",scopedFirst,reset:true,expected:["Lisbon","Cedar"])
        await runtime.reset()
        try await runtime.warm(messages:[scoped[0]],settings:model.settings,tools:[])
        _ = try await request("system-warmed-scoped-first-transcription",scopedFirst,reset:false,expected:["Lisbon","Cedar"])
        var noLatestAudio = fullPaths; noLatestAudio[5] = []
        _ = try await request("reset-full-history-without-latest-audio-negative",RuntimePrompt(messages:fullMessages,mediaPaths:noLatestAudio),reset:true,expected:["Osaka","Maple"])
    }
}
