import XCTest
import UIKit
import UniformTypeIdentifiers
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeOmniFoldedAudioChronologyReplayControls() async throws {
        struct Protocol: Decodable {
            struct Control: Decodable { var messages: [[String:String]]; var mediaCounts: [Int] }
            var controls: [String:Control]; var order: [String]
            var modelRepository: String; var modelRevision: String
        }
        struct Manifest: Decodable {
            struct Fixture: Decodable { var path: String; var bytes: Int; var sha256: String }
            var files: [ModelFile]; var fixtures: [Fixture]
        }
        let resource = ProcessInfo.processInfo.environment["OW_AUDIO_REPLAY_PLAN"] ?? "audio-chronology-controls"
        XCTAssertTrue(["audio-chronology-controls","audio-summary-shape-controls"].contains(resource))
        let protocolURL = try XCTUnwrap(Bundle.main.url(forResource:resource,withExtension:"json"))
        let protocolData = try Data(contentsOf:protocolURL)
        let plan = try JSONDecoder().decode(Protocol.self,from:protocolData)
        let manifestURL = try XCTUnwrap(Bundle.main.url(forResource:"omni-audio-validation-artifact",withExtension:"json"))
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:manifestURL))
        let cache = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("OmniAudioValidation")
        let library = try ModelLibrary(file:cache.appendingPathComponent("models.json"))
        let models = await library.list()
        var model = try XCTUnwrap(models.first { $0.id.uuidString == "9C4CBED5-1FCD-4223-9785-B6F43FA6634B" && $0.state == .ready })
        XCTAssertEqual(model.repository,plan.modelRepository); XCTAssertEqual(model.revision,plan.modelRevision)
        XCTAssertEqual(model.files,manifest.files); XCTAssertNil(model.settings.systemPrompt)
        model.settings.contextTokens = 4096; model.settings.outputTokens = 96; model.settings.temperature = 0
        model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.thinking = false; model.settings.reasoningEffort = nil
        let directory = cache.appendingPathComponent("Models").appendingPathComponent(model.id.uuidString)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-chronology-" + UUID().uuidString)
        let journal = cache.appendingPathComponent("audio-chronology-" + UUID().uuidString + ".json")
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var observations: [[String:Any]] = [], normalized: [String] = [], completed = false
        func record(_ value: [String:Any]) throws {
            observations.append(value)
            try JSONSerialization.data(withJSONObject:["purpose":"native-omni-folded-audio-chronology-controls","observations":observations],options:[.prettyPrinted,.sortedKeys]).write(to:journal,options:.atomic)
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at:root)
            let value: [String:Any] = ["purpose":"native-omni-folded-audio-chronology-controls","completed":completed,
                "protocolSHA256":SHA256.hash(data:protocolData).map { String(format:"%02x",$0) }.joined(),
                "repository":plan.modelRepository,"revision":plan.modelRevision,"observations":observations,"normalizedAudioSHA256":normalized,
                "limitations":["Exact failed-prompt replay with two pinned synthetic English clips. No full six-turn acceptance, general speech/summary quality, speed, energy or causal claim across models.",
                    "Reset clears KV context and remembered replies. The shared session retains independent media embeddings, so this is not a fresh model or projector-embedding-cache reset.",
                    "Chronology metadata and summary omission are test-only controls. Original product prompts, recovery criterion, standing guidance, artifact and defaults remain unchanged."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
            attachment.name = "native-omni-folded-audio-chronology-controls"; attachment.lifetime = .keepAlways; add(attachment)
        }
        for file in model.files {
            let url = try file.destination(in:directory)
            try record(["stage":"file-verification-started","file":file.path])
            try await Task.detached { try ModelDownloads.verify(url,file:file) }.value
            try record(["stage":"file-verified","file":file.path,"sha256":file.sha256 ?? ""])
        }
        let runtime = try RuntimeFactory.make(model); try await runtime.load(model:model,directory:directory)
        XCTAssertTrue(runtime.mediaSupport.audio)
        let owned = try ChatAttachmentStore(root:root), attachments = AttachmentController(store:owned)
        var paths: [String] = []
        for fixture in manifest.fixtures {
            let name = (fixture.path as NSString).deletingPathExtension
            let source = try XCTUnwrap(Bundle.main.url(forResource:name,withExtension:"aiff")), data = try Data(contentsOf:source)
            XCTAssertEqual(data.count,fixture.bytes); XCTAssertEqual(SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),fixture.sha256)
            await attachments.stage(source,type:.aiff,support:runtime.mediaSupport); XCTAssertNil(attachments.error)
            let item = try XCTUnwrap(attachments.staged.last), url = try await owned.resolve(item)
            paths.append(url.path); normalized.append(item.sha256)
        }
        XCTAssertEqual(normalized,["717c652dc794a7718463d1e904871dbf41ebc739a140ac2097a9b38f440affa8","219aea41dd79681ead9580c85e30128d5f03f2360ba13d3c6b8d89889ff7d01b"])
        XCTAssertEqual(plan.order.sorted(),plan.controls.keys.flatMap { [$0,$0] }.sorted())
        for (index, name) in plan.order.enumerated() {
            let control = try XCTUnwrap(plan.controls[name]); XCTAssertEqual(control.messages.count,control.mediaCounts.count)
            XCTAssertEqual(control.messages.first?["content"],ChatController.systemPrompt)
            XCTAssertEqual(control.messages.last?["content"],"Which city was spoken in the latest audio? Reply with the city name only.")
            var cursor = 0
            let media: [[String]] = control.mediaCounts.map { count in
                guard count == 1 else { XCTAssertEqual(count,0); return [] }
                defer { cursor += 1 }; return [paths[cursor]]
            }
            XCTAssertEqual(cursor,2)
            let prompt = RuntimePrompt(messages:control.messages,mediaPaths:media)
            await runtime.reset()
            try record(["stage":"control-started","index":index,"control":name,"thermalState":ProcessInfo.processInfo.thermalState.rawValue])
            let size = try await runtime.promptSize(prompt:prompt,settings:model.settings,tools:[])
            XCTAssertTrue(size.exact); XCTAssertLessThanOrEqual(size.tokens + model.settings.outputTokens,model.settings.contextTokens)
            var final: RuntimeReply?, streamed = ""
            for try await event in runtime.stream(prompt:prompt,settings:model.settings,tools:[]) {
                switch event {
                case .token(let piece): streamed += piece
                case .reply(let reply): XCTAssertNil(final); final = reply
                }
            }
            let reply = try XCTUnwrap(final), usage = try XCTUnwrap(reply.usage)
            XCTAssertEqual(reply.content,streamed); XCTAssertFalse(reply.cancelled); XCTAssertEqual(reply.stopReason,.endOfTurn); XCTAssertEqual(reply.cachedTokens,0)
            XCTAssertEqual(size.tokens,usage.promptTokens + usage.cachedTokens)
            let words = reply.content.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let accepted = words == ["osaka"]
            try record(["stage":"control-finished","index":index,"control":name,"messages":control.messages,
                "mediaCounts":control.mediaCounts,"normalizedAudioSHA256":normalized,"countedPrompt":size.tokens,
                "promptTokens":usage.promptTokens,"cachedTokens":usage.cachedTokens,"contextUsed":reply.contextUsed,"reply":reply.content,
                "generatedTokens":reply.generatedTokens,"stopReason":reply.stopReason.rawValue,"answerAccepted":accepted])
            if name != "A-reset-original" { XCTAssertTrue(accepted,"\(name) latest-city answer: \(reply.content)") }
        }
        completed = true
    }
}
