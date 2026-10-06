import Foundation
import OpenWeightsCore

private struct ControllerWebResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private actor ControllerWebConnector: PublicWebConnecting {
    var requests = 0
    let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        requests += 1
        if slow { try await Task.sleep(nanoseconds: 20_000_000_000) }
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<main><h1>Cedar</h1><p>Osaka vegetarian 07:30.</p></main>".utf8))
    }
}
extension ControllerChecks {
    @MainActor static func webChecks(_ passed: inout [String]) async throws {
        func client(_ connector: ControllerWebConnector) -> PublicWebClient { PublicWebClient(resolver: ControllerWebResolver(), connector: connector) }
        let connector = ControllerWebConnector()
        let ordinary = try Fixture(mode: .fetch, write: false, webClient: client(connector)); defer { ordinary.cleanup() }
        ordinary.web.fetchEnabled = true; try await ordinary.loadAndSend()
        try await wait("Auto page fetch hung") { !ordinary.chat.busy }
        let tool = ordinary.chat.current?.messages.first { $0.toolName == "fetch_url" }
        try require(tool?.status == .complete && tool?.toolUntrustedText == true && tool?.content.contains("Osaka") == true && ordinary.runtime.captures[1].messages.contains { $0["content"]?.contains("Read: https://example.com/page") == true }, "Fetched evidence did not reach durable chat and the follow-up prompt.")
        let reopened = try ConversationStore(file: ordinary.conversationFile)
        try require(try await reopened.conversation(ordinary.chat.current!.id).messages.contains { $0 == tool }, "Fetch result was not persisted.")
        passed.append("public-fetch-result-with-provenance-and-taint-is-durable-and-used-by-followup")

        let chainedConnector = ControllerWebConnector()
        let chained = try Fixture(mode: .fetchTwice, write: false, webClient: client(chainedConnector)); defer { chained.cleanup() }
        chained.web.fetchEnabled = true; try await chained.loadAndSend()
        try await wait("Second page fetch did not ask") { chained.chat.pendingToolApproval != nil }
        try require(await chainedConnector.requests == 1 && chained.chat.pendingToolApproval!.displayedCall.argumentsJSON.contains("/next") && chained.chat.pendingToolApprovalContext?.contains("named website") == true, "Untrusted page selected another URL without exact-call approval.")
        chained.chat.answerToolApproval(approved: false)
        try await wait("Declined page fetch did not finish") { !chained.chat.busy }
        try require(await chainedConnector.requests == 1, "Declined URL reached the transport.")
        passed.append("page-to-next-url-requires-exact-approval-and-decline-prevents-network")

        let writing = try Fixture(mode: .fetchThenWrite, write: false, webClient: client(ControllerWebConnector())); defer { writing.cleanup() }
        try await writing.prepareFiles(mode: .yolo); writing.web.fetchEnabled = true; try await writing.loadAndSend()
        try await wait("Page-followed file write did not ask") { writing.chat.pendingToolApproval != nil }
        try require(writing.chat.pendingToolApproval!.displayedCall.name == "write_file" && !FileManager.default.fileExists(atPath: writing.sharedFolder.appendingPathComponent("after-web.txt").path), "Same-round page content bypassed durable-write approval in Yolo.")
        writing.chat.answerToolApproval(approved: true); try await wait("Approved file write did not finish") { !writing.chat.busy }
        try require(try String(contentsOf: writing.sharedFolder.appendingPathComponent("after-web.txt"), encoding: .utf8) == "Cedar", "Approved write did not complete.")
        passed.append("same-round-web-taint-reaches-file-tool-and-yolo-cannot-waive-durable-write-approval")

        for mode in [AgentMode.auto, .plan] {
            let blockedConnector = ControllerWebConnector()
            let blocked = try Fixture(mode: .fetch, write: false, webClient: client(blockedConnector)); defer { blocked.cleanup() }
            blocked.web.fetchEnabled = mode == .plan; blocked.files.mode = mode
            try await blocked.loadAndSend(); try await wait("Disabled or Plan fetch hung") { !blocked.chat.busy }
            try require(await blockedConnector.requests == 0 && blocked.runtime.captures.allSatisfy { !$0.tools.contains("fetch_url") }, "Disabled or Plan tool connected.")
        }
        passed.append("disabled-and-plan-fetch-tools-are-not-offered-and-never-connect")

        let stoppingConnector = ControllerWebConnector(slow: true)
        let stopping = try Fixture(mode: .fetch, write: false, webClient: client(stoppingConnector)); defer { stopping.cleanup() }
        stopping.web.fetchEnabled = true; try await stopping.loadAndSend()
        for _ in 0..<100 { if await stoppingConnector.requests > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        try require(await stoppingConnector.requests == 1, "Fetch never entered the transport.")
        stopping.chat.cancel(); try await wait("Stop did not cancel the page task") { !stopping.chat.busy }
        try require(stopping.chat.current?.messages.first { $0.toolName == "fetch_url" }?.status == .failed, "Cancelled fetch was recorded as successful.")
        passed.append("chat-stop-cancels-active-web-task-and-does-not-record-a-successful-read")

        let unattendedConnector = ControllerWebConnector()
        let unattended = try Fixture(mode: .fetchTwice, write: false, webClient: client(unattendedConnector)); defer { unattended.cleanup() }
        unattended.web.fetchEnabled = true; await unattended.chat.load(unattended.chat.downloads.models[0])
        let result = await unattended.chat.checkWatch(ScheduledWatch(task: "Read public Cedar status", everyMinutes: 1, at: Date()), background: true)
        let unattendedRequests = await unattendedConnector.requests
        try require(result.outcome == .checked && unattendedRequests == 1 && unattended.chat.pendingToolApproval == nil && unattended.chat.current == nil, "Watch outcome=\(result.outcome) summary=\(result.summary) requests=\(unattendedRequests) pending=\(unattended.chat.pendingToolApproval != nil) current=\(unattended.chat.current != nil). A watch reached a second page chosen after untrusted text or changed chat.")
        passed.append("cpu-watch-can-read-one-public-page-but-refuses-followup-egress-without-a-person")
        let historyConnector = ControllerWebConnector()
        let history = try Fixture(mode: .fetch, write: false, webClient: client(historyConnector)); defer { history.cleanup() }
        history.web.fetchEnabled = true; await history.chat.load(history.chat.downloads.models[0])
        var historicalWatch = ScheduledWatch(task: "Read the status page", everyMinutes: 1, at: Date())
        historicalWatch.lastSummary = "A previous check included private or external data."
        _ = await history.chat.checkWatch(historicalWatch, background: true)
        try require(await historyConnector.requests == 0 && history.chat.pendingToolApproval == nil, "Prior watch findings silently selected an unattended outbound URL.")
        passed.append("prior-watch-finding-is-untrusted-and-cannot-authorize-an-unattended-url")
    }
}
