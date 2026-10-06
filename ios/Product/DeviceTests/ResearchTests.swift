import Foundation
import XCTest
import SwiftUI
import UIKit
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

private actor NativeResearchSearch: SearchHTTPTransport {
    private var queries: [String] = []
    func observations() -> [String] { queries }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        queries.append(request.address.url.absoluteString)
        return WebHTTPResponse(status: 200, headers: ["content-type":"text/html"], body: Data("<div data-type='web'><a href='https://example.com/status'>Current Cedar project status</a><div class='snippet'>The official status page contains the current project identifier and revision. Open it to read both facts.</div></div>".utf8))
    }
}
private actor NativeResearchConnector: PublicWebConnecting {
    private var exchanges: [[String: String]] = []
    private var identifier = "Cobalt"
    private var revision = 73
    func changeFacts() { identifier = "Juniper"; revision = 84 }
    func observations() -> [[String: String]] { exchanges }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        let redirect = address.url.path == "/status"
        let body = redirect ? Data() : Data("Cedar project current status. The current identifier is \(identifier). The current revision is \(revision). These are the only current status facts supplied by this page.".utf8)
        exchanges.append(["url":address.url.absoluteString,"bodySHA256":SHA256.hash(data:body).map { String(format:"%02x",$0) }.joined(),"status":redirect ? "302" : "200"])
        return WebHTTPResponse(status: redirect ? 302 : 200, headers: redirect ? ["location":"/current"] : ["content-type":"text/plain"], body: body)
    }
}
extension ProductTests {
    func testNativeResearchTwoQuestionsAndReport() async throws { try await verifyResearchReview(review: false) }
    func testNativeResearchReviewReopenAndFreshEvidence() async throws { try await verifyResearchReview(review: true) }
    private func verifyResearchReview(review: Bool) async throws {
        let pinned = try NativeAgentArtifact.selected(), root = FileManager.default.temporaryDirectory.appendingPathComponent("native-research-" + UUID().uuidString)
        let suite = "openweights.native-research." + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite); try? FileManager.default.removeItem(at:root) }
        let downloads = ModelDownloads(root:root.appendingPathComponent("Models"),library:try ModelLibrary(file:root.appendingPathComponent("models.json")),sessionIdentifier:suite)
        let search = NativeResearchSearch(), connector = NativeResearchConnector()
        let web = WebController(defaults:defaults,client:PublicWebClient(resolver:WebWatchFixtureResolver(),connector:connector),searchTransport:search)
        web.searchEnabled = true; web.fetchEnabled = true; web.mediaEnabled = false
        web.setEngine(.brave,enabled:true); web.setEngine(.duckduckgo,enabled:false); web.setEngine(.yahoo,enabled:false)
        let files = WorkspaceController(bookmarkFile:root.appendingPathComponent("workspace.bookmark"),defaults:defaults); files.mode = .yolo
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers:99)), goalFile = root.appendingPathComponent("goal.json"), conversationFile = root.appendingPathComponent("conversations.json")
        var chat = ChatController(store:try ConversationStore(file:conversationFile),downloads:downloads,files:files,goals:try GoalStore(file:goalFile),web:web,defaults:defaults,runtimeFactory:{ _ in observed })
        var completed = false, approvals: [[String:String]] = [], actions: [String] = [], network: [[String:String]] = [], searches: [String] = []
        defer {
            let state = chat.workGoal?.state.rawValue ?? "none", note = chat.workGoal?.note ?? "", error = chat.error ?? ""
            chat.cancel()
            let evidence: [String:Any] = ["purpose":review ? "native-product-research-review" : "native-product-research","completed":completed,"state":state,"stepsTaken":chat.workGoal?.stepsTaken ?? -1,"goalNote":note,"error":error,"actionsReached":actions,"approvals":approvals,"fetchExchanges":network,"searchRequests":searches,"runtimeTrace":observed.snapshot(),"artifact":NativeAgentArtifact.evidence(pinned),"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,
                "limitations":["Real pinned GGUF and product controllers. Deterministic search/page transports exercise actual parsers, redirect guards and typed evidence without live provider availability.","Approval and slash entry use controller calls. Mounted views verify rendering, not touch, VoiceOver or OS termination. No general research quality or performance claim."]]
            let item = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json"); item.name = review ? "native-product-research-review.json" : "native-product-research.json"; item.lifetime = .keepAlways; add(item)
        }
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let source = cachedDirectory(artifact:"gguf",revision:try XCTUnwrap(pinned.revision)).appendingPathComponent(pinned.entryFile)
        try ModelDownloads.verify(source,file:try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.settings.temperature = 0; model.settings.repeatPenalty = 1
        model.settings.outputTokens = 384; model.settings.contextTokens = 8192; model.settings.thinking = false
        model.settings.toolPrompt = "Prefer answering from memory."
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error)
        guard chat.error == nil else { return }
        chat.draft = "/deep-research What are the current identifier and revision of the Cedar project? Make exactly two questions, one for the identifier and one for the revision. Search the web for each and read the returned status page."; await chat.send()
        let deadline = ProcessInfo.processInfo.systemUptime + 360
        while chat.goalActive || chat.busy {
            if let approval = chat.pendingToolApproval {
                approvals.append(["name":approval.displayedCall.name,"arguments":approval.displayedCall.argumentsJSON])
                XCTAssertEqual(approval.displayedCall.name,"fetch_url","Research Auto must still require exact fetch approval after untrusted search, even when the selected mode was Yolo.")
                chat.answerToolApproval(approved:true,ticketID:approval.ticketID)
            }
            if ProcessInfo.processInfo.systemUptime > deadline { XCTFail("Research did not finish within its native test deadline."); break }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        network = await connector.observations(); searches = await search.observations()
        XCTAssertNil(chat.error); XCTAssertEqual(chat.workGoal?.state,.done); XCTAssertEqual(chat.workGoal?.stepsTaken,2)
        guard chat.error == nil, chat.workGoal?.state == .done, var goal = chat.workGoal, let plan = goal.plan else { return }
        XCTAssertEqual(goal.research?.evidence.count,2); XCTAssertTrue(goal.research?.verifies(plan) == true)
        XCTAssertEqual(goal.research?.sources(for:plan),["https://example.com/current"]); XCTAssertEqual(files.mode,.yolo)
        var answer = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content)
        XCTAssertTrue(answer.contains("Cobalt") && answer.contains("73") && answer.contains("https://example.com/current"),answer)
        guard answer.contains("Cobalt"), answer.contains("73"), answer.contains("https://example.com/current") else { return }
        actions.append("two-real-model-questions-each-search-fetch-approved-redirect-correlated-before-report")
        let trace = observed.snapshot()["streams"] as? [[String:Any]] ?? []
        XCTAssertFalse((trace.first?["offeredTools"] as? [String] ?? []).contains("ask_user"))
        XCTAssertEqual(trace.last?["offeredTools"] as? [String],[])
        XCTAssertGreaterThanOrEqual(searches.count,2); XCTAssertGreaterThanOrEqual(approvals.count,2)
        actions.append("research-overrides-yolo-and-configured-tool-bias-report-offers-no-tools-mode-restored")
        let retained = try await ConversationStore(file:conversationFile).conversation(try XCTUnwrap(chat.current?.id))
        XCTAssertEqual(retained.messages.filter { $0.fetchEvidence != nil }.count,chat.current?.messages.filter { $0.fetchEvidence != nil }.count)
        let reopened = await (try GoalStore(file:goalFile)).snapshot(); XCTAssertEqual(reopened.goal,goal)
        actions.append("typed-search-fetch-and-per-question-sources-survive-store-reopen")
        if review {
            let originalID = goal.id, originalCycle = goal.research?.cycleID
            await chat.setPlanStep(0, done: false); await chat.setPlanStep(1, done: false)
            XCTAssertNil(chat.error); XCTAssertEqual(chat.workGoal?.state, .halted)
            XCTAssertEqual(chat.workGoal?.id, originalID); XCTAssertEqual(chat.workGoal?.stepsTaken, 2)
            XCTAssertNotEqual(chat.workGoal?.research?.cycleID, originalCycle)
            XCTAssertTrue(chat.workGoal?.research?.evidence.isEmpty == true)
            XCTAssertEqual(chat.current?.plan, chat.workGoal?.plan)
            guard chat.error == nil, chat.workGoal?.state == .halted else { return }
            actions.append("manual-uncheck-preserves-goal-identity-budget-and-clears-old-evidence")
            await connector.changeFacts(); chat.cancel()
            chat = ChatController(store:try ConversationStore(file:conversationFile),downloads:downloads,files:files,goals:try GoalStore(file:goalFile),web:web,defaults:defaults,runtimeFactory:{ _ in observed })
            await chat.restore(); XCTAssertNil(chat.error); XCTAssertEqual(chat.current?.plan,chat.workGoal?.plan)
            XCTAssertEqual(chat.workGoal?.id,originalID); XCTAssertEqual(chat.workGoal?.state,.halted)
            await chat.load(model); XCTAssertNil(chat.error)
            guard chat.error == nil else { return }
            let nextCycle = chat.workGoal?.research?.cycleID, firstResumedStream = (observed.snapshot()["streams"] as? [[String:Any]] ?? []).count
            await chat.resumeGoal()
            let resumedDeadline = ProcessInfo.processInfo.systemUptime + 360
            while chat.goalActive || chat.busy {
                if let approval = chat.pendingToolApproval {
                    approvals.append(["name":approval.displayedCall.name,"arguments":approval.displayedCall.argumentsJSON])
                    XCTAssertEqual(approval.displayedCall.name,"fetch_url")
                    chat.answerToolApproval(approved:true,ticketID:approval.ticketID)
                }
                if ProcessInfo.processInfo.systemUptime > resumedDeadline { XCTFail("Reviewed research did not finish."); break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            network = await connector.observations(); searches = await search.observations()
            XCTAssertNil(chat.error); XCTAssertEqual(chat.workGoal?.state,.done); XCTAssertEqual(chat.workGoal?.stepsTaken,4)
            XCTAssertEqual(chat.workGoal?.id,originalID); XCTAssertEqual(chat.workGoal?.research?.cycleID,nextCycle)
            guard chat.error == nil, chat.workGoal?.state == .done, let updated = chat.workGoal else { return }
            goal = updated; answer = try XCTUnwrap(chat.current?.messages.last { $0.role == .assistant }?.content)
            XCTAssertTrue(answer.contains("Juniper") && answer.contains("84") && answer.contains("https://example.com/current"),answer)
            guard answer.contains("Juniper"),answer.contains("84"),answer.contains("https://example.com/current") else { return }
            let resumedStreams = Array((observed.snapshot()["streams"] as? [[String:Any]] ?? []).dropFirst(firstResumedStream))
            XCTAssertGreaterThanOrEqual(resumedStreams.flatMap { ($0["reply"] as? [String:Any])?["toolCalls"] as? [[String:String]] ?? [] }.filter { $0["name"] == "web_search" }.count,2)
            let persisted = try await ConversationStore(file:conversationFile).conversation(try XCTUnwrap(chat.current?.id))
            let currentReads = persisted.messages.filter { $0.fetchEvidence != nil && $0.researchStep?.cycleID == nextCycle }
            XCTAssertGreaterThanOrEqual(currentReads.count,2)
            let finalSnapshot = await (try GoalStore(file:goalFile)).snapshot(); XCTAssertEqual(finalSnapshot.goal,goal)
            actions.append("controller-store-reopen-resume-fetches-changed-facts-with-new-cycle-and-four-cumulative-steps")
        }
        let image = try await NativeMountedView.capture(VStack(alignment:.leading,spacing:16) { GoalStrip(chat:chat,goal:goal); TranscriptMarkdownView(content:answer) }.padding().background(OWTheme.canvas),size:CGSize(width:390,height:650))
        let screenshot = XCTAttachment(image:image); screenshot.name = review ? "native-research-review-report-and-sources" : "native-research-report-and-sources"; screenshot.lifetime = .keepAlways; add(screenshot)
        completed = true
    }
}
