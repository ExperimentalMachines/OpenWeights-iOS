import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor extension ProductTests {
    func testNativeCanvasRepairFrozenControls() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: ProductTests.self).url(forResource: "CanvasRepairFixture", withExtension: "json"))
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:fixtureURL)) as? [String:Any])
        let messages = try XCTUnwrap(fixture["messages"] as? [[String:String]])
        let settings = try XCTUnwrap(fixture["settings"] as? [String:Any])
        var model = try NativeAgentArtifact.selected()
        model.settings.contextTokens = try XCTUnwrap(settings["contextTokens"] as? Int)
        model.settings.outputTokens = try XCTUnwrap(settings["outputTokens"] as? Int)
        model.settings.temperature = try XCTUnwrap(settings["temperature"] as? Double)
        model.settings.topP = try XCTUnwrap(settings["topP"] as? Double)
        model.settings.repeatPenalty = try XCTUnwrap(settings["repeatPenalty"] as? Double)
        model.settings.thinking = try XCTUnwrap(settings["thinking"] as? Bool)
        let directory = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(model.revision)))
        for file in model.files { try ModelDownloads.verify(file.destination(in:directory),file:file) }
        let runtime = NativeObservedRuntime(LlamaRuntime(gpuLayers:99))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var completed = false, outcomes: [[String:Any]] = []
        defer {
            runtime.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let value: [String:Any] = ["purpose":"native-Canvas-frozen-repair-diagnostic-controls", "completed":completed,"sourceCohort":fixture["sourceCohort"] ?? "", "sourceAttachmentSHA256":fixture["sourceAttachmentSHA256"] ?? "", "outcomes":outcomes,"runtimeTrace":runtime.snapshot(),"artifact":NativeAgentArtifact.evidence(model),"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,"limitations":["Diagnostic fresh-context requests over exact frozen failed repair messages. A passing XCTest means controls executed, not that all variants repaired the page.","Generated calls are observed without execution or browser grading. A candidate must pass the actual controller, exact approval, saved-source and rendered-page flow before acceptance. No production change, general quality or performance claim."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");attachment.lifetime = .keepAlways;attachment.name = "Canvas frozen repair controls";add(attachment)
        }
        try await runtime.load(model:model,directory:directory)
        let guidance = "For each missing local asset, save the required file or remove its reference if equivalent functionality is already inline. An unchanged save cannot repair the reported error. Do not claim the page is clean while the browser still reports errors."
        var withToolHint = messages
        for index in withToolHint.indices where withToolHint[index]["role"] == "tool" && withToolHint[index]["content"]?.contains("Missing file:") == true {
            withToolHint[index]["content"] = (withToolHint[index]["content"] ?? "") + "\n" + guidance
        }
        let tailHint = messages + [["role":"user","content":guidance]]
        let tools = FileToolDefinitions.all.filter { ["read_file","write_file"].contains($0.name) } + CanvasToolDefinitions.all.filter { $0.name == "show_website" }
        XCTAssertEqual(tools.map(\.name),fixture["offeredTools"] as? [String])
        for (name,input) in [("C1-frozen-failing-repair",messages),("C2-guidance-in-diagnostic-tool-result",withToolHint),("C3-guidance-at-tail",tailHint)] {
            await runtime.reset(); var final: RuntimeReply?
            for try await event in runtime.stream(messages:input,settings:model.settings,tools:tools) { if case .reply(let reply) = event { final = reply } }
            let reply = try XCTUnwrap(final);XCTAssertFalse(reply.cancelled);XCTAssertEqual(reply.stopReason,.endOfTurn)
            let proposedClean = reply.toolCalls.contains { call in
                guard call.name == "write_file", let args = (try? JSONSerialization.jsonObject(with:Data(call.arguments.utf8))) as? [String:Any], let source = args["content"] as? String else { return false }
                return args["path"] as? String == "site/index.html" && !source.contains("missing.css") && source.contains("Cedar Expedition") && source.contains("Add one") && source.contains("</html>")
            }
            outcomes.append(["id":name,"proposedEntryWithoutMissingReference":proposedClean,"answer":reply.content,"toolCalls":reply.toolCalls.map { ["name":$0.name,"arguments":$0.arguments] },"cachedTokens":reply.cachedTokens])
        }
        completed = outcomes.count == 3
    }
}
