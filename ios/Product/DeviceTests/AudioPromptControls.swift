import XCTest
import UIKit
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeAudioPromptDeliveryControls() async throws {
        let cache = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AudioValidation")
        let library = try ModelLibrary(file:cache.appendingPathComponent("models.json"))
        let models = await library.list()
        let model = try XCTUnwrap(models.first { $0.id.uuidString == "C74F1D6B-AC55-4B93-80B1-75CB9E86A26A" && $0.state == .ready })
        let directory = cache.appendingPathComponent("Models").appendingPathComponent(model.id.uuidString)
        for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-prompt-controls-" + UUID().uuidString)
        let owned = try ChatAttachmentStore(root:root), attachments = AttachmentController(store:owned)
        let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
        XCTAssertTrue(runtime.mediaSupport.audio)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String:Any]] = []
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at:root)
            let evidence: [String:Any] = ["purpose":"native-audio-prompt-delivery-controls","observations":observations,
                "limitations":["Prompt/cache/media-presence diagnostics. Replies are retained without treating the method as a passing audio-quality suite.",
                    "Fixed ASR system instruction follows Liquid4All/liquid-audio README. Controls do not change app defaults or establish a full original-weight reference, general ASR or audio output."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "native-audio-prompt-delivery-controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let source = try XCTUnwrap(Bundle.main.url(forResource:"Lisbon",withExtension:"aiff"))
        await attachments.stage(source,type:.aiff,support:runtime.mediaSupport); XCTAssertNil(attachments.error)
        let audio = try XCTUnwrap(attachments.staged.first), url = try await owned.resolve(audio)
        let system = model.settings.systemInstructions(base:ChatController.systemPrompt,toolsAvailable:false)
        let cases: [(String,String?,String,Bool)] = [
            ("product-system-transcription-reset",system,"Transcribe the speech in this audio.",true),
            ("no-system-transcription-reset",nil,"Transcribe the speech in this audio.",true),
            ("fixed-ASR-audio-only","Perform ASR.","",true),
            ("fixed-ASR-text-and-audio","Perform ASR.","Transcribe the speech in this audio.",true),
            ("product-system-audio-only",system,"",true),
            ("product-system-city-question",system,"Which city is spoken in this audio? Reply with the city name only.",true),
            ("product-system-with-ASR-instruction",system + "\n\nPerform ASR.","Transcribe the speech in this audio.",true),
            ("fixed-ASR-text-only-negative","Perform ASR.","",false)
        ]
        for (name,preamble,question,hasMedia) in cases {
            await runtime.reset()
            var messages: [[String:String]] = [], paths: [[String]] = []
            if let preamble { messages.append(["role":"system","content":preamble]); paths.append([]) }
            messages.append(["role":"user","content":question]); paths.append(hasMedia ? [url.path] : [])
            let prompt = RuntimePrompt(messages:messages,mediaPaths:paths)
            var final: RuntimeReply?, streamed = ""
            for try await event in runtime.stream(prompt:prompt,settings:model.settings,tools:[]) {
                switch event { case .token(let piece): streamed += piece; case .reply(let reply): final = reply }
            }
            let reply = try XCTUnwrap(final); XCTAssertEqual(reply.content,streamed); XCTAssertFalse(reply.cancelled); XCTAssertEqual(reply.cachedTokens,0)
            observations.append(["stage":name,"messages":messages,"hasMedia":hasMedia,"ownedAudioSHA256":audio.sha256,
                "reply":reply.content,"promptContent":reply.promptContent ?? "","cachedTokens":reply.cachedTokens,
                "contextUsed":reply.contextUsed,"generatedTokens":reply.generatedTokens,"stopReason":reply.stopReason.rawValue])
        }
    }
}
