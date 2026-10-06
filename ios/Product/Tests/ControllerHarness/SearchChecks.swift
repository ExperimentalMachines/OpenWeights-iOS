import Foundation
import OpenWeightsCore

private actor ControllerSearchTransport: SearchHTTPTransport {
    var requests = 0
    let slow: Bool
    init(slow: Bool = false) { self.slow = slow }
    func send(_ request: SearchHTTPRequest, timeout: TimeInterval) async throws -> WebHTTPResponse {
        requests += 1
        if slow { try await Task.sleep(nanoseconds: 20_000_000_000) }
        return WebHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("<div data-type='web'><a href='https://example.com/'>Cedar</a><div class='snippet'>Public Cedar information with enough details to be useful.</div></div>".utf8))
    }
}
extension ControllerChecks {
    @MainActor static func searchChecks(_ passed: inout [String]) async throws {
        func enable(_ fixture: Fixture) { fixture.web.searchEnabled = true; fixture.web.setEngine(.duckduckgo, enabled: false); fixture.web.setEngine(.yahoo, enabled: false) }
        let sourceTransport = ControllerSearchTransport()
        let source = try Fixture(mode: .search, write: false, searchTransport: sourceTransport); defer { source.cleanup() }
        enable(source); try await source.loadAndSend(); try await wait("Search did not complete") { !source.chat.busy }
        let tool = source.chat.current!.messages.first { $0.toolName == "web_search" }
        try require(tool?.status == .complete && tool?.toolUntrustedText == true && tool?.searchEvidence?.engine == .brave && tool?.searchEvidence?.hits.first?.url == "https://example.com/", "Search provenance or structured sources were not saved.")
        let reopened = try ConversationStore(file: source.conversationFile)
        let saved = try await reopened.conversation(source.chat.current!.id)
        try require(saved.messages.first { $0.toolName == "web_search" } == tool && source.runtime.captures.last!.messages.contains { $0["content"]?.contains("https://example.com/") == true }, "Search sources were lost on reopen or excluded from the model follow-up.")
        passed.append("search-structured-source-provenance-persists-reopens-and-feeds-the-answer-pass")

        let repeatedTransport = ControllerSearchTransport()
        let repeated = try Fixture(mode: .searchTwice, write: false, searchTransport: repeatedTransport); defer { repeated.cleanup() }
        enable(repeated); try await repeated.loadAndSend(); try await wait("Ordinary second query hung") { !repeated.chat.busy || repeated.chat.pendingToolApproval != nil }
        let repeatedRequests = await repeatedTransport.requests
        try require(!repeated.chat.busy && repeatedRequests == 2 && repeated.chat.pendingToolApproval == nil, "Public search snippets unnecessarily gated another fixed-provider query.")
        passed.append("public-snippets-do-not-gate-ordinary-followup-search-queries-in-auto")

        let privateTransport = ControllerSearchTransport()
        let privateRead = try Fixture(mode: .readThenSearch, write: false, searchTransport: privateTransport); defer { privateRead.cleanup() }
        try await privateRead.prepareFiles(); enable(privateRead); try await privateRead.loadAndSend()
        try await wait("Private-read search did not ask") { privateRead.chat.pendingToolApproval != nil }
        try require(await privateTransport.requests == 0 && privateRead.chat.pendingToolApproval!.displayedCall.argumentsJSON.contains("Original Cedar") && privateRead.chat.pendingToolApprovalContext?.contains("Brave") == true, "Private file data reached search without its exact query approval.")
        privateRead.chat.answerToolApproval(approved: true); try await wait("Approved private-data search did not finish") { !privateRead.chat.busy }
        try require(await privateTransport.requests == 1, "Approved query did not run once.")
        passed.append("private-file-data-requires-exact-search-query-approval-before-egress")

        let legacyTransport = ControllerSearchTransport()
        let legacy = try Fixture(mode: .search, write: false, searchTransport: legacyTransport); defer { legacy.cleanup() }
        enable(legacy); await legacy.chat.load(legacy.chat.downloads.models[0]); await legacy.chat.newConversation()
        var conversation = legacy.chat.current!
        conversation.messages.append(StoredMessage(role: .user, content: "Read my file."))
        var assistant = StoredMessage(role: .assistant, content: "")
        assistant.promptContent = "<tool_call>{\"name\":\"read_file\",\"arguments\":{\"path\":\"user.txt\"}}</tool_call>"
        assistant.toolCalls = [AgentToolCall(id: "legacy-read", name: "read_file", argumentsJSON: "{\"path\":\"user.txt\"}")]
        conversation.messages.append(assistant)
        var read = StoredMessage(role: .tool, content: "Private Cedar")
        read.toolName = "read_file"; read.toolCallID = "legacy-read"
        conversation.messages.append(read); await legacy.chat.update(conversation)
        legacy.chat.draft = "Search for Cedar"; await legacy.chat.send()
        try await wait("Legacy private read did not gate search") { legacy.chat.pendingToolApproval != nil }
        try require(await legacyTransport.requests == 0, "Legacy file data left the device because its old record had no taint flag.")
        legacy.chat.answerToolApproval(approved: false); try await wait("Declined legacy private query hung") { !legacy.chat.busy }
        passed.append("legacy-file-results-without-taint-metadata-still-require-search-egress-approval")

        let fetching = try Fixture(mode: .searchThenFetch, write: false, searchTransport: ControllerSearchTransport()); defer { fetching.cleanup() }
        enable(fetching); fetching.web.fetchEnabled = true; try await fetching.loadAndSend()
        try await wait("Search-selected URL did not ask") { fetching.chat.pendingToolApproval != nil }
        try require(fetching.chat.pendingToolApproval!.displayedCall.name == "fetch_url", "Wrong post-search approval.")
        fetching.chat.answerToolApproval(approved: false); try await wait("Declined search-result fetch hung") { !fetching.chat.busy }
        passed.append("search-result-selected-page-fetch-still-requires-exact-url-approval")

        let writing = try Fixture(mode: .searchThenWrite, write: false, searchTransport: ControllerSearchTransport()); defer { writing.cleanup() }
        try await writing.prepareFiles(mode: .yolo); enable(writing); try await writing.loadAndSend()
        try await wait("Search-based durable write did not ask") { writing.chat.pendingToolApproval != nil }
        try require(writing.chat.pendingToolApproval!.displayedCall.name == "write_file" && !FileManager.default.fileExists(atPath: writing.sharedFolder.appendingPathComponent("after-search.txt").path), "Search snippets bypassed durable-write approval in Yolo.")
        writing.chat.answerToolApproval(approved: false); try await wait("Declined search-based write hung") { !writing.chat.busy }
        passed.append("search-snippets-taint-same-round-durable-writes-even-in-yolo")

        let slowTransport = ControllerSearchTransport(slow: true)
        let stopped = try Fixture(mode: .search, write: false, searchTransport: slowTransport); defer { stopped.cleanup() }
        enable(stopped); try await stopped.loadAndSend()
        for _ in 0..<100 { if await slowTransport.requests > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        stopped.chat.cancel(); try await wait("Search Stop did not cancel transport") { !stopped.chat.busy }
        try require(await slowTransport.requests == 1 && stopped.chat.current?.messages.first { $0.toolName == "web_search" }?.status == .failed, "Stopped search was not cancelled or was recorded as success.")
        passed.append("chat-stop-cancels-search-task-without-a-successful-result")

        let unsupported = try Fixture(mode: .seeded, supportsTools: false, write: false, searchTransport: ControllerSearchTransport()); defer { unsupported.cleanup() }
        unsupported.web.searchEnabled = true; try await unsupported.loadAndSend(); try await wait("Default search blocked a non-tool model") { !unsupported.chat.busy }
        try require(unsupported.chat.error == nil && unsupported.runtime.captures.allSatisfy { !$0.tools.contains("web_search") }, "A default-on search tool prevented a non-tool model from chatting.")
        passed.append("default-search-is-unavailable-for-non-tool-models-without-blocking-chat")

        let suite = "search-settings-" + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let controls = WebController(defaults: defaults)
        try require(controls.searchEnabled && !controls.fetchEnabled && !controls.documentation && controls.resultCount == 3 && controls.searchEngines.count == 3, "Fresh search settings differ from Android defaults.")
        controls.setEngine(.duckduckgo, enabled: false); controls.setEngine(.yahoo, enabled: false); controls.setEngine(.brave, enabled: false)
        controls.resultCount = 99; controls.documentation = true; controls.searchEnabled = false
        let restored = WebController(defaults: defaults)
        try require(controls.searchEngines == [.brave] && controls.resultCount == 5 && restored.searchEngines == [.brave] && restored.resultCount == 5 && restored.documentation && !restored.searchEnabled, "Provider minimum, result limits or setting persistence failed.")
        passed.append("android-search-defaults-provider-minimum-count-bounds-and-switches-persist")
    }
}
