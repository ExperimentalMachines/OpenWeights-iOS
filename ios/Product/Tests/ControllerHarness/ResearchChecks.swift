import Foundation
import OpenWeightsCore

private struct ResearchResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private actor ResearchConnector: PublicWebConnecting {
    private(set) var requests = 0
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        requests += 1
        if address.url.path == "/status" { return WebHTTPResponse(status: 302, headers: ["location":"/current"], body: Data()) }
        return WebHTTPResponse(status: 200, headers: ["content-type":"text/plain"], body: Data("Current identifier: Cobalt. Current revision: 73.".utf8))
    }
}
private actor ResearchSearch: SearchHTTPTransport {
    private(set) var requests = 0
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests += 1
        return WebHTTPResponse(status: 200, headers: ["content-type":"text/html"], body: Data("<div data-type='web'><a href='https://example.com/status'>Current project status</a><div class='snippet'>Read the source for the current identifier and revision.</div></div>".utf8))
    }
}
extension ControllerChecks {
    @MainActor static func researchChecks(_ passed: inout [String]) async throws {
        func fixture(_ mode: FixtureRuntime.Mode) throws -> Fixture {
            let value = try Fixture(mode: mode, write: false, webClient: PublicWebClient(resolver: ResearchResolver(), connector: ResearchConnector()), searchTransport: ResearchSearch())
            value.web.searchEnabled = true; value.web.fetchEnabled = true; value.web.mediaEnabled = false
            value.web.setEngine(.brave, enabled: true); value.web.setEngine(.duckduckgo, enabled: false); value.web.setEngine(.yahoo, enabled: false)
            return value
        }
        func finish(_ value: Fixture) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while value.chat.goalActive || value.chat.busy {
                if let approval = value.chat.pendingToolApproval { value.chat.answerToolApproval(approved: true, ticketID: approval.ticketID) }
                if ProcessInfo.processInfo.systemUptime > deadline { throw CheckFailure("Research fixture hung: " + (value.chat.error ?? "")) }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        for previous in [AgentMode.plan, .ask, .yolo] {
            let value = try fixture(.research); defer { value.cleanup() }
            value.files.mode = previous
            var model = value.downloads.models[0]; model.settings.toolPrompt = "Prefer answering from memory."
            try await value.downloads.saveSettings(model); await value.chat.load(model)
            value.chat.draft = "/deep-research Current project status"; await value.chat.send(); try await finish(value)
            try require(value.chat.workGoal?.state == .done && value.chat.workGoal?.stepsTaken == 2, "Two research questions did not finish: \(value.chat.workGoal?.state.rawValue ?? "none") \(value.chat.error ?? "") \(value.chat.workGoal?.note ?? "") Captures: \(value.runtime.captures.map { $0.messages.last ?? [:] })")
            try require(value.chat.current?.messages.filter { $0.toolName == "web_search" }.allSatisfy { $0.content.contains("Fetch the full readable page") && !$0.content.contains("without mentioning the search") } == true, "Ordinary search guidance overrode the research brief.")
            let goal = value.chat.workGoal!, plan = goal.plan!
            try require(goal.research?.verifies(plan) == true && goal.research?.sources(for: plan) == ["https://example.com/current"], "Correlated redirected sources were lost.")
            try require(value.runtime.captures.first?.tools.contains("ask_user") == false && value.chat.pendingUserQuestion == nil, "Research planning offered user questions.")
            let execution = value.runtime.captures.filter { $0.messages.first?["content"]?.contains(ResearchBrief.toolPrompt) == true }
            try require(!execution.isEmpty && execution.allSatisfy { $0.messages.first?["content"]?.contains("Prefer answering from memory.") == false }, "Research did not replace the configured tool prompt.")
            let synthesis = value.runtime.captures.first { $0.messages.last?["content"]?.hasPrefix(ResearchBrief.finish) == true }
            try require(synthesis?.tools.isEmpty == true && synthesis?.messages.last?["content"]?.contains("https://example.com/current") == true, "Synthesis offered tools or lost verified sources.")
            try require(value.files.mode == (previous == .plan ? .auto : previous), "Research did not restore the selected mode.")
            let reopened = try ConversationStore(file: value.conversationFile), retained = try await reopened.conversation(value.chat.current!.id)
            try require(retained.messages.filter { $0.fetchEvidence != nil }.count == 2, "Typed fetch evidence did not survive reopen.")
            passed.append("research-two-questions-correlated-redirect-sources-report-and-mode-restoration-" + previous.rawValue)
        }
        let split = try fixture(.researchSplit); defer { split.cleanup() }
        await split.chat.load(split.downloads.models[0]); await split.chat.startResearch("Status?"); try await finish(split)
        try require(split.chat.workGoal?.state == .done && split.chat.workGoal?.stepsTaken == 2 && split.chat.workGoal?.research?.evidence.count == 2, "Search and fetch across retries of the assigned question did not correlate.")
        let splitMessages = try await ConversationStore(file: split.conversationFile).conversation(split.chat.current!.id).messages
        try require(splitMessages.filter { $0.fetchEvidence != nil }.allSatisfy { $0.researchStep?.goalID == split.chat.workGoal?.id }, "Research step scopes did not survive reopen.")
        passed.append("research-correlates-durable-search-and-fetch-across-retries-of-same-question")
        let fallback = try fixture(.researchFallback); defer { fallback.cleanup() }
        await fallback.chat.load(fallback.downloads.models[0]); await fallback.chat.startResearch("Current identifier?"); try await finish(fallback)
        try require(fallback.chat.workGoal?.state == .done && fallback.chat.workGoal?.plan?.steps.count == 1, "Original-question fallback failed.")
        passed.append("research-no-plan-uses-one-original-question-without-asking-user")
        for mode in [FixtureRuntime.Mode.researchSearchOnly, .researchUnrelated] {
            let value = try fixture(mode); defer { value.cleanup() }
            await value.chat.load(value.downloads.models[0]); await value.chat.startResearch("Status?"); try await finish(value)
            try require(value.chat.workGoal?.state == .halted && value.chat.workGoal?.stepsTaken == 0 && value.chat.current?.plan?.steps.allSatisfy { !$0.done } == true && value.runtime.captures.allSatisfy { $0.messages.last?["content"]?.hasPrefix(ResearchBrief.finish) != true }, "Uncorrelated step advanced or synthesized.")
            passed.append(mode == .researchSearchOnly ? "research-search-only-premature-advance-rolled-back-no-report" : "research-unrelated-fetch-two-failures-halt-with-no-report")
        }
        for mode in [FixtureRuntime.Mode.researchCappedReport, .researchNoSearchReport] {
            let value = try fixture(mode); defer { value.cleanup() }
            await value.chat.load(value.downloads.models[0]); await value.chat.startResearch("Status?"); try await finish(value)
            try require(value.chat.workGoal?.state == .halted && value.chat.workGoal?.research?.evidence.count == 2, "Incomplete report counted as finished.")
            if mode == .researchNoSearchReport {
                try require(value.chat.current?.messages.last { $0.toolName == "web_search" }?.status == .failed, "Synthesis performed a search.")
            }
            passed.append(mode == .researchCappedReport ? "research-capped-report-halts-with-verified-findings-retained" : "research-synthesis-tool-call-is-refused-and-cannot-mark-done")
        }
        let stopped = try fixture(.research); defer { stopped.cleanup() }
        await stopped.chat.load(stopped.downloads.models[0]); await stopped.chat.startResearch("Status?")
        try await wait("Research fetch approval absent") { stopped.chat.pendingToolApproval != nil }
        stopped.chat.stopGoal(); try await wait("Research Stop hung") { !stopped.chat.goalActive && !stopped.chat.busy }
        try require(stopped.chat.workGoal?.state == .stopped && stopped.chat.workGoal?.stepsTaken == 0 && stopped.chat.pendingToolApproval == nil, "Stop permitted a pending fetch.")
        passed.append("research-stop-at-fetch-approval-performs-no-fetch-and-no-report")
        let reviewed = try fixture(.research); defer { reviewed.cleanup() }
        await reviewed.chat.load(reviewed.downloads.models[0]); await reviewed.chat.startResearch("Status?"); try await finish(reviewed)
        await reviewed.chat.setPlanStep(0, done: false)
        let savedReview = try await ConversationStore(file: reviewed.conversationFile).conversation(reviewed.chat.current!.id)
        try require(reviewed.chat.error == nil && reviewed.chat.workGoal?.state == .halted && reviewed.chat.workGoal?.plan == savedReview.plan,
            "Completed research review diverged: error=\(reviewed.chat.error ?? "") goal=\(reviewed.chat.workGoal?.state.rawValue ?? "none") goalPlan=\(String(describing: reviewed.chat.workGoal?.plan)) conversationPlan=\(String(describing: savedReview.plan))")
        passed.append("completed-research-review-keeps-goal-and-conversation-plans-consistent")
        let beforeCycle = reviewed.chat.workGoal?.research?.cycleID
        let captureCount = reviewed.runtime.captures.count
        await reviewed.chat.resumeGoal(); try await finish(reviewed)
        try require(reviewed.chat.workGoal?.state == .done && reviewed.chat.workGoal?.stepsTaken == 3 && reviewed.runtime.captures.dropFirst(captureCount).contains { $0.tools.contains("web_search") }, "Rechecked question reused its old evidence or reset its budget.")
        try require(reviewed.chat.workGoal?.research?.cycleID == beforeCycle, "Resuming an unchanged review invalidated same-question retry evidence.")
        try require(reviewed.runtime.captures.dropFirst(captureCount).filter { $0.tools.contains("web_search") }.allSatisfy { $0.messages.contains { $0["content"]?.contains("This plan was reviewed. Search again for this question") == true } }, "Reviewed research did not request fresh search and returned-page reads.")
        passed.append("rechecked-research-requires-new-scoped-tools-and-preserves-cumulative-budget")
        await reviewed.chat.clearPlan()
        let clearedPlan = try await ConversationStore(file: reviewed.conversationFile).conversation(reviewed.chat.current!.id)
        try require(reviewed.chat.error == nil && reviewed.chat.workGoal?.plan == nil && clearedPlan.plan == nil && reviewed.chat.workGoal?.research?.evidence.isEmpty == true, "Clear plan left stale research evidence or a split board.")
        passed.append("clear-completed-research-clears-both-plans-and-source-evidence")

        let rejected = try fixture(.research); defer { rejected.cleanup() }
        await rejected.chat.load(rejected.downloads.models[0]); await rejected.chat.startResearch("Status?"); try await finish(rejected)
        let rejectedPlan = rejected.chat.current!.plan, rejectedGoal = rejected.chat.workGoal
        let goalFile = rejected.root.appendingPathComponent("goal.json")
        try FileManager.default.removeItem(at: goalFile); try FileManager.default.createDirectory(at: goalFile, withIntermediateDirectories: false)
        await rejected.chat.setPlanStep(0, done: false)
        let unchanged = try await ConversationStore(file: rejected.conversationFile).conversation(rejected.chat.current!.id)
        try require(rejected.chat.error != nil && rejected.chat.current?.plan == rejectedPlan && unchanged.plan == rejectedPlan && rejected.chat.workGoal == rejectedGoal, "Failed goal commit still changed its conversation plan.")
        passed.append("failed-goal-review-commit-preserves-both-plans")

        let mirror = try fixture(.research); defer { mirror.cleanup() }
        await mirror.chat.load(mirror.downloads.models[0]); await mirror.chat.startResearch("Status?"); try await finish(mirror)
        let priorFile = try Data(contentsOf: mirror.conversationFile)
        try FileManager.default.removeItem(at: mirror.conversationFile); try FileManager.default.createDirectory(at: mirror.conversationFile, withIntermediateDirectories: false)
        await mirror.chat.setPlanStep(0, done: false)
        try require(mirror.chat.error != nil && mirror.chat.workGoal?.state == .halted && mirror.chat.current?.plan == mirror.chat.workGoal?.plan, "A failed transcript mirror lost the committed reviewed goal.")
        let dismissedWhileBroken = await mirror.chat.dismissGoal()
        try require(!dismissedWhileBroken && mirror.chat.workGoal?.state == .halted, "Dismiss removed the only committed reviewed plan before its mirror could save.")
        passed.append("dismiss-refuses-to-drop-a-reviewed-plan-with-failed-conversation-mirror")
        try FileManager.default.removeItem(at: mirror.conversationFile); try priorFile.write(to: mirror.conversationFile)
        let recovered = ChatController(store: try ConversationStore(file: mirror.conversationFile), downloads: mirror.downloads, goals: try GoalStore(file: mirror.root.appendingPathComponent("goal.json")), defaults: mirror.defaults, runtimeFactory: { _ in mirror.runtime }, goalHaltReason: { nil })
        await recovered.restore()
        let restored = try await ConversationStore(file: mirror.conversationFile).conversation(mirror.chat.current!.id)
        try require(recovered.error == nil && restored.plan == recovered.workGoal?.plan && restored.goalPlanReviewID == recovered.workGoal?.planReviewID && recovered.current?.plan == restored.plan, "Reopening did not repair the failed plan mirror.")
        passed.append("failed-conversation-mirror-reconciles-by-review-id-on-controller-reopen")
        var unrelatedPlan = restored; unrelatedPlan.plan = TaskPlan(steps: [TaskStep(text: "Independent normal chat")])
        let unrelated = try ConversationStore(file: mirror.conversationFile); try await unrelated.save(unrelatedPlan)
        let retained = ChatController(store: try ConversationStore(file: mirror.conversationFile), downloads: mirror.downloads, goals: try GoalStore(file: mirror.root.appendingPathComponent("goal.json")), defaults: mirror.defaults, runtimeFactory: { _ in mirror.runtime }, goalHaltReason: { nil })
        await retained.restore()
        try require(retained.current?.plan == unrelatedPlan.plan, "An already acknowledged goal review overwrote a later ordinary plan.")
        passed.append("acknowledged-review-does-not-overwrite-independent-later-planning")
        let deletedGoal = try fixture(.research); defer { deletedGoal.cleanup() }
        await deletedGoal.chat.load(deletedGoal.downloads.models[0]); await deletedGoal.chat.startResearch("Status?"); try await finish(deletedGoal)
        await deletedGoal.chat.delete(deletedGoal.chat.current!)
        let recreated = await deletedGoal.chat.newConversation()
        try require(recreated && deletedGoal.chat.error == nil && deletedGoal.chat.goalSnapshot.goal == nil, "Deleting the owning conversation stranded its old goal board.")
        passed.append("deleted-goal-conversation-does-not-block-creating-another-chat")
        let disabled = try fixture(.research); defer { disabled.cleanup() }
        await disabled.chat.load(disabled.downloads.models[0]); disabled.web.fetchEnabled = false; await disabled.chat.startResearch("Status?")
        try require(!disabled.chat.goalActive && disabled.chat.workGoal == nil && disabled.runtime.captures.isEmpty && disabled.chat.error?.contains("Page fetching") == true, "Research bypassed the fetch switch.")
        passed.append("research-requires-both-web-switches-before-creating-work")
    }
}
