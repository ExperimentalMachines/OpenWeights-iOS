import XCTest
import UIKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor extension ProductTests {
    func testNativeScriptWatchFormatControls() async throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: ProductTests.self).url(forResource: "ScriptWatchFormatFixture", withExtension: "json"))
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let messages = try XCTUnwrap(fixture["messages"] as? [[String: String]])
        let sourceSettings = try XCTUnwrap(fixture["settings"] as? [String: Any])
        var model = try NativeAgentArtifact.selected(); model.backend = .llamaCPU
        model.settings.contextTokens = try XCTUnwrap(sourceSettings["contextTokens"] as? Int)
        model.settings.outputTokens = try XCTUnwrap(sourceSettings["outputTokens"] as? Int)
        model.settings.temperature = try XCTUnwrap(sourceSettings["temperature"] as? Double)
        model.settings.topP = try XCTUnwrap(sourceSettings["topP"] as? Double)
        model.settings.repeatPenalty = try XCTUnwrap(sourceSettings["repeatPenalty"] as? Double)
        model.settings.thinking = try XCTUnwrap(sourceSettings["thinking"] as? Bool)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(model.revision)))
        for file in model.files { try ModelDownloads.verify(file.destination(in: directory), file: file) }
        let runtime = NativeObservedRuntime(LlamaRuntime(gpuLayers: 0))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        var completed = false, outcomes: [[String: Any]] = []
        defer {
            runtime.cancel(); UIApplication.shared.isIdleTimerDisabled = idle
            let evidence: [String: Any] = ["purpose": "native-script-watch-format-controls", "completed": completed, "sourceCohort": fixture["sourceCohort"] ?? "", "outcomes": outcomes, "runtimeTrace": runtime.snapshot(), "artifact": NativeAgentArtifact.evidence(model), "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations": ["Diagnostic requests over frozen watch messages and tool results, fresh CPU context for each. A passing XCTest establishes controls executed, not that all format variants worked. Candidate needs complete controller verification with real generated script execution."]]
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) { let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.lifetime = .keepAlways; add(attachment) }
        }
        try await runtime.load(model: model, directory: directory)
        var systemOnly = messages
        systemOnly[0]["content"] = "You are running a scheduled check on the user's phone. Use the available tools to complete the task. Return only the answer in the format the task requests. If no format is specified, reply briefly. Do not claim current facts without evidence. If this is a due reminder, delivering the reminder is the check. Nobody is present to approve tools. Do not ask questions or change a conversation plan."
        let finalReminder = ["role": "user", "content": "Finish the check using the available results. Follow the task's requested output format. Return only the answer without an introduction or explanation."]
        let replayTask = ["role": "user", "content": "The tool has completed. Now deliver the requested final answer for this task: " + (messages.first { $0["role"] == "user" }?["content"] ?? "")]
        var originalHead = messages
        originalHead[0]["content"] = "You are running a scheduled check on the user's phone. Do the check with the tools available and report what you found in one or two sentences. Do not claim current facts without evidence. If this is a due reminder, delivering the reminder is the check. Nobody is present to approve tools. Do not ask questions or change a conversation plan."
        for (name, input) in [("C1-frozen-failing-watch", messages), ("C2-system-format-only", systemOnly), ("C3-final-answer-reminder", messages + [finalReminder]), ("C4-task-tail-after-tool", messages + [replayTask]), ("C5-original-head-with-final-reminder", originalHead + [finalReminder])] {
            await runtime.reset(); var final: RuntimeReply?
            for try await event in runtime.stream(messages: input, settings: model.settings, tools: [ScriptToolDefinition.tool]) { if case .reply(let reply) = event { final = reply } }
            let reply = try XCTUnwrap(final); XCTAssertFalse(reply.cancelled); XCTAssertEqual(reply.stopReason, .endOfTurn)
            let exact = reply.content.trimmingCharacters(in: .whitespacesAndNewlines) == "56913867" && reply.toolCalls.isEmpty
            outcomes.append(["id": name, "answer": reply.content, "exactFormat": exact, "toolCalls": reply.toolCalls.map { ["name": $0.name, "arguments": $0.arguments] }, "cachedTokens": reply.cachedTokens])
        }
        completed = outcomes.count == 5
    }
}
