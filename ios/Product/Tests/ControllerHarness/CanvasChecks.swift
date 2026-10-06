import Foundation
import OpenWeightsCore

extension ControllerChecks {
    @MainActor static func canvasChecks(_ passed: inout [String]) async throws {
        let fixture = try Fixture(mode: .canvas, write: false); defer { fixture.cleanup() }
        try await fixture.prepareFiles()
        try require(fixture.files.canvasEnabled.isEmpty, "Canvas did not start off.")
        try FileManager.default.createDirectory(at: fixture.sharedFolder.appendingPathComponent("site"), withIntermediateDirectories: true)
        try Data("<html><body>Cedar</body></html>".utf8).write(to: fixture.sharedFolder.appendingPathComponent("site/index.html"))
        fixture.files.canvasEnabled = Set(CanvasToolDefinitions.all.map(\.name))
        fixture.files.pageChecker = { _, _ in CanvasPageReport(errors: ["Controlled typo"]) }
        try await fixture.loadAndSend(); try await wait("Canvas tool did not finish") { !fixture.chat.busy }
        let shown = fixture.files.canvas
        let result = fixture.chat.current!.messages.first { $0.toolName == "show_website" }
        try require(shown?.entry == "site/index.html" && result?.status == .complete && result?.toolUntrustedText == true && result?.toolPrivateDataRead == true && result!.content.contains("Controlled typo"), "Canvas routing or diagnostic provenance failed.")
        try require(fixture.runtime.captures.first!.tools.contains("show_website"), "Canvas was not in the native runtime contract.")
        let reopened = try ConversationStore(file: fixture.conversationFile), stored = await reopened.list()
        try require(stored[0].messages.contains { $0.toolName == "show_website" && $0.toolPrivateDataRead == true }, "Preview provenance did not survive persistence.")
        passed.append("canvas-default-off-auto-chat-routing-error-feedback-and-private-provenance-checkpoint")

        let grant = fixture.files.grantID
        let write = AgentToolCall(id: "write-preview", name: "write_file", argumentsJSON: "{\"path\":\"site/index.html\",\"content\":\"<html>Cobalt</html>\",\"replace\":true}")
        let written = await fixture.files.execute(write, approval: ApprovedToolCall(displayedCall: write), expectedGrantID: grant)
        try require(!written.rejected && fixture.files.canvas?.revision == 1 && written.privateDataRead && written.untrustedText, "Site save did not reload or return untrusted grading.")
        let unrelated = AgentToolCall(id: "other", name: "write_file", argumentsJSON: "{\"path\":\"unrelated.txt\",\"content\":\"other\"}")
        _ = await fixture.files.execute(unrelated, approval: ApprovedToolCall(displayedCall: unrelated), expectedGrantID: grant)
        try require(fixture.files.canvas?.revision == 1, "Unrelated save reloaded the site.")
        passed.append("canvas-save-revisions-and-error-feedback-limited-to-active-site")

        let call = AgentToolCall(id: "document", name: "show_document", argumentsJSON: "{\"path\":\"user.txt\"}")
        fixture.files.mode = .ask
        let denied = await fixture.files.execute(call, approval: nil, expectedGrantID: grant)
        try require(denied.rejected && fixture.files.canvas?.id == shown?.id, "Ask preview opened without approval.")
        let approved = ApprovedToolCall(displayedCall: call)
        let document = await fixture.files.execute(call, approval: approved, expectedGrantID: grant)
        let replay = await fixture.files.execute(call, approval: approved, expectedGrantID: grant)
        try require(!document.rejected && replay.rejected && fixture.files.canvas?.kind == .document, "Exact approval was not consumed once.")
        let bad = AgentToolCall(id: "folder", name: "show_slides", argumentsJSON: "{\"path\":\"site\"}")
        fixture.files.mode = .auto
        let badResult = await fixture.files.execute(bad, approval: nil, expectedGrantID: grant)
        try require(badResult.rejected && fixture.files.canvas?.kind == .document, "Deck accepted a folder.")
        passed.append("canvas-ask-exact-one-shot-approval-and-document-folder-refusal")

        let website = AgentToolCall(id: "website", name: "show_website", argumentsJSON: "{\"path\":\"site\"}")
        let site = await fixture.files.execute(website, approval: nil, expectedGrantID: grant)
        try require(!site.rejected && fixture.files.canvas?.entry == "site/index.html", "Website folder did not use index.html.")
        fixture.files.canvasEnabled.remove("show_website")
        let off = await fixture.files.execute(website, approval: nil, expectedGrantID: grant)
        fixture.files.canvasEnabled.insert("show_website"); fixture.files.mode = .plan
        let plan = await fixture.files.execute(website, approval: nil, expectedGrantID: grant)
        try require(off.rejected && plan.rejected, "Off or Plan mode opened a preview.")
        await fixture.files.revoke()
        let revoked = await fixture.files.execute(website, approval: nil, expectedGrantID: grant)
        try require(fixture.files.canvas == nil && revoked.rejected && fixture.files.definitions.isEmpty, "Revocation kept a preview or offered tool.")
        passed.append("canvas-folder-index-off-plan-and-grant-revocation-guards")

        let ask = try Fixture(mode: .canvas, write: false); defer { ask.cleanup() }
        try await ask.prepareFiles(mode: .ask)
        try FileManager.default.createDirectory(at: ask.sharedFolder.appendingPathComponent("site"), withIntermediateDirectories: true)
        try Data("<html>Cedar</html>".utf8).write(to: ask.sharedFolder.appendingPathComponent("site/index.html"))
        ask.files.canvasEnabled = ["show_website"]
        try await ask.loadAndSend(); try await wait("Canvas Ask approval absent") { ask.chat.pendingToolApproval != nil }
        try require(ask.files.canvas == nil, "Canvas opened before the controller approved it.")
        ask.chat.answerToolApproval(approved: false); try await wait("Declined Canvas did not finish") { !ask.chat.busy }
        try require(ask.files.canvas == nil && ask.chat.current!.messages.contains { $0.toolName == "show_website" && $0.status == .failed }, "Declined preview had an effect.")
        passed.append("canvas-chat-ask-decline-persists-refusal-without-opening")

        let cutoff = try Fixture(mode: .canvas, write: false); defer { cutoff.cleanup() }
        try await cutoff.prepareFiles()
        try FileManager.default.createDirectory(at: cutoff.sharedFolder.appendingPathComponent("site"), withIntermediateDirectories: true)
        try Data("<html><body>Cedar</body></html>".utf8).write(to: cutoff.sharedFolder.appendingPathComponent("site/index.html"))
        cutoff.files.canvasEnabled = ["show_website"]
        let cutoffGrant = cutoff.files.grantID
        _ = await cutoff.files.execute(website, approval: nil, expectedGrantID: cutoffGrant)
        let truncated = AgentToolCall(id: "cutoff", name: "write_file", argumentsJSON: "{\"path\":\"site/index.html\",\"text\":\"<html><body><div id=\",\"replace\":true}")
        let noChecker = await cutoff.files.execute(truncated, approval: ApprovedToolCall(displayedCall: truncated), expectedGrantID: cutoffGrant)
        try require(!noChecker.rejected && noChecker.text.contains("looks cut off") && noChecker.privateDataRead && noChecker.untrustedText, "No browser checker hid the cut-off save or its provenance.")
        cutoff.files.pageChecker = { _, _ in CanvasPageReport() }
        let cleanBrowser = await cutoff.files.execute(truncated, approval: ApprovedToolCall(displayedCall: truncated), expectedGrantID: cutoffGrant)
        let repair = AgentToolCall(id: "repair", name: "write_file", argumentsJSON: "{\"path\":\"site/index.html\",\"body\":\"<HTML><BODY>Cobalt</BODY></HTML>\",\"replace\":true}")
        let repaired = await cutoff.files.execute(repair, approval: ApprovedToolCall(displayedCall: repair), expectedGrantID: cutoffGrant)
        try require(cleanBrowser.text.contains("looks cut off") && !repaired.rejected && !repaired.text.contains("looks cut off"), "Browser repair hid truncation or a complete save retained its warning.")
        passed.append("canvas-cutoff-save-warns-without-checker-or-browser-errors-and-content-alias-repair-clears")
        let outsider = AgentToolCall(id: "outside-cutoff", name: "write_file", argumentsJSON: "{\"path\":\"outside.html\",\"content\":\"<html>\"}")
        let outside = await cutoff.files.execute(outsider, approval: nil, expectedGrantID: cutoffGrant)
        cutoff.files.canvasEnabled.insert("show_document")
        let openedDocument = await cutoff.files.execute(call, approval: nil, expectedGrantID: cutoffGrant)
        try require(!openedDocument.rejected && cutoff.files.canvas?.kind == .document, "Document scope control did not open.")
        let documentWrite = await cutoff.files.execute(truncated, approval: ApprovedToolCall(displayedCall: truncated), expectedGrantID: cutoffGrant)
        try require(!outside.text.contains("looks cut off") && !documentWrite.text.contains("looks cut off"), "A different file or document inherited site grading.")
        passed.append("canvas-cutoff-feedback-scoped-to-successful-active-site-saves")

        for mode in [FixtureRuntime.Mode.canvasRounds, .canvasBeyondRounds, .canvasCallCap] {
            let builder = try Fixture(mode: mode, write: false); defer { builder.cleanup() }
            try await builder.prepareFiles()
            try FileManager.default.createDirectory(at: builder.sharedFolder.appendingPathComponent("site"), withIntermediateDirectories: true)
            try Data("<html><body>Cedar</body></html>".utf8).write(to: builder.sharedFolder.appendingPathComponent("site/index.html"))
            builder.files.canvasEnabled = ["show_website"]
            var checked = 0
            builder.files.pageChecker = { _, _ in checked += 1; return CanvasPageReport() }
            try await builder.loadAndSend(); try await wait("Builder did not settle at its bound") { !builder.chat.busy }
            let tools = builder.chat.current!.messages.filter { $0.role == .tool }
            try require(builder.runtime.captures.count == 9, "Builder did not receive eight tool rounds and one answer pass.")
            if mode == .canvasCallCap {
                let present = (1...8).filter { FileManager.default.fileExists(atPath: builder.sharedFolder.appendingPathComponent("builder-\($0).txt").path) }
                try require(present == Array(1...6) && tools.filter { $0.status == .complete }.count == 6 && tools.suffix(2).allSatisfy { $0.content.contains("Six-call limit") } && builder.chat.error == nil, "Builder raised the durable-effect cap above six.")
                passed.append("canvas-eight-round-budget-preserves-six-call-effect-cap")
            } else if mode == .canvasBeyondRounds {
                try require(checked == 1 && tools.count == 9 && tools.last?.status == .failed && tools.last!.content.contains("Tool-round limit") && builder.chat.error != nil, "Ninth builder tool executed or the bound was not reported.")
                passed.append("canvas-ninth-tool-round-refused-before-settled-call-reuse")
            } else {
                try require(checked == 1 && tools.count == 8 && tools.allSatisfy { $0.status == .complete } && tools.last!.content.contains("tool-round limit") && !tools[3].content.contains("tool-round limit") && builder.chat.error == nil, "Builder did not keep eight settled rounds before its answer.")
                passed.append("canvas-eight-settled-tool-rounds-and-one-answer-pass-without-repeated-effects")
            }
        }
    }
}
