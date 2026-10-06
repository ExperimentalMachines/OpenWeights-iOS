import Foundation
import Combine
import OpenWeightsCore

@MainActor final class ModelDownloads {
    let root: URL
    var models: [LocalModel]
    private var library: ModelLibrary?
    init(root: URL, models: [LocalModel]) { self.root = root; self.models = models }
    func saveSettings(_ model: LocalModel) async throws {
        if library == nil {
            let saved = try ModelLibrary(file: root.appendingPathComponent("models.json"))
            for value in models { try await saved.save(value) }
            library = saved
        }
        guard let library else { throw CheckFailure("The model library was not created.") }
        try await library.saveSettings(model); models = await library.list()
    }
    func directory(_ model: LocalModel) -> URL { root.appendingPathComponent(model.id.uuidString) }
    nonisolated static func verify(_ url: URL, file: ModelFile) throws { try ModelFileTransfer.verify(url, file: file) }
}
enum RuntimeFactory {
    static func make(_ model: LocalModel) throws -> any ChatRuntime { throw CheckFailure("A host fixture must explicitly inject its runtime.") }
}
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func require(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(message) } }

actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var released = false
    func wait() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class FixtureRuntime: ChatRuntime, @unchecked Sendable {
    enum Mode { case research, researchSplit, researchFallback, researchSearchOnly, researchUnrelated, researchCappedReport, researchNoSearchReport, canvasRounds, canvasBeyondRounds, canvasCallCap, canvas, script, scriptThenSearch, watchStaleThenFetch, watchRefusedFetch, media, readThenMedia, search, searchTwice, readThenSearch, searchThenFetch, searchThenWrite, fetch, fetchTwice, fetchThenWrite, fetchSave, goalEmpty, goalCapped, goalUnknown, goalRepeatPlan, watchReadThenWrite, watchRequest, watchReminder, watchCapped, seeded, folding, foldingCapped, foldingUnknown, foldingCancelled, foldingEmpty, goalAdvance, goalManyAdvance, goalQuestion, goal, goalWrongAdvance, goalFailedTools, planRepair, planNoRepair, proseQuestion, planning, question, advance, invalidQuestion, write, read, repeatWrites, repeatSame, emptyStream, multipleCalls, fileWrite, fileReplace, fileRounds, manyFiles, readThenWrite, fileSettled, fileRefusal, declinedThenWrite }
    struct Capture { let messages: [[String: String]]; let tools: [String]; let settings: ModelSettings }
    var mediaEnabled = false
    var mediaCellCost = 1200
    var exactMediaCount = true
    var completeMediaReadings = false
    var rejectVerbatimMediaRecords = false
    var beforeVerbatimCount: (@MainActor () -> Void)?
    private var recordedMedia: [RuntimePrompt] = []
    var mediaCaptures: [RuntimePrompt] { lock.withLock { recordedMedia } }
    var mediaSupport: RuntimeMediaSupport { RuntimeMediaSupport(vision:mediaEnabled,audio:mediaEnabled,marker:mediaEnabled ? "<media>" : "") }
    func promptSize(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        let text = try await promptSize(messages:prompt.messages,settings:settings,tools:tools)
        return RuntimePromptSize(tokens:text.tokens + prompt.mediaPaths.flatMap { $0 }.count * mediaCellCost,exact:!prompt.hasMedia || exactMediaCount)
    }
    func warm(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        try await warm(messages:prompt.messages,settings:settings,tools:tools)
    }
    func stream(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        if prompt.hasMedia { lock.withLock { recordedMedia.append(prompt) } }
        return stream(messages:prompt.messages,settings:settings,tools:tools)
    }
    var usageMetrics: UsageMeasurements? = nil
    struct Preparation { let kind: String; let capture: Capture }
    let supportsTools: Bool
    let mode: Mode
    var beforeFirstReply: (() throws -> Void)?
    private let lock = NSLock()
    private var recorded: [Capture] = []
    private var prepared: [Preparation] = []
    var preparations: [Preparation] { lock.withLock { prepared } }
    private var scriptArguments = "{\"source\":\"30+1\"}"
    func setScriptArguments(_ value: String) { lock.withLock { scriptArguments = value } }
    var warmGate: PreparationGate?
    var countGate: PreparationGate?
    var loadGate: PreparationGate?
    var streamGate: PreparationGate?
    private var resets = 0
    var resetCount: Int { lock.withLock { resets } }
    private var cancellations = 0
    var cancellationCount: Int { lock.withLock { cancellations } }
    init(_ mode: Mode = .write, supportsTools: Bool = true) { self.mode = mode; self.supportsTools = supportsTools }
    private var folding: Bool { [.folding, .foldingCapped, .foldingUnknown, .foldingCancelled, .foldingEmpty].contains(mode) }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        lock.withLock { prepared.append(Preparation(kind: "count", capture: Capture(messages: messages, tools: tools.map(\.name), settings: settings))) }
        await countGate?.wait()
        if messages.contains(where: { $0["content"]?.contains(ConversationCompactor.mediaRecordsHeading) == true }) {
            await beforeVerbatimCount?()
            if rejectVerbatimMediaRecords { return RuntimePromptSize(tokens: settings.contextTokens, exact: true) }
        }
        return RuntimePromptSize(tokens: folding ? messages.reduce(0) { $0 + ($1["content"]?.utf16.count ?? 0) } / 4 + 20 : 40, exact: true)
    }
    var captures: [Capture] { lock.withLock { recorded } }
    func load(model: LocalModel, directory: URL) async throws { await loadGate?.wait() }
    func cancel() { lock.withLock { cancellations += 1 } }
    func reset() async { lock.withLock { resets += 1 } }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws { try await warm(messages: messages, settings: settings, tools: []) }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        lock.withLock { prepared.append(Preparation(kind: "warm", capture: Capture(messages: messages, tools: tools.map(\.name), settings: settings))) }
        await warmGate?.wait()
    }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> {
        stream(messages: messages, settings: settings, tools: [])
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let count = lock.withLock { recorded.append(Capture(messages: messages, tools: tools.map(\.name), settings: settings)); return recorded.count }
        return AsyncThrowingStream { stream in
            if mode == .emptyStream { stream.yield(.token("partial text")); stream.finish(); return }
            var calls: [RuntimeToolCall] = []
            let raw: String
            let content: String
            let last = messages.last?["content"] ?? ""
            if [.research, .researchSplit, .researchFallback, .researchSearchOnly, .researchUnrelated, .researchCappedReport, .researchNoSearchReport].contains(mode) {
                if last.hasPrefix(ResearchBrief.plan) {
                    content = mode == .researchFallback ? "I will research that question." : "1. What is the current identifier?\n2. What is the current revision?"
                } else if last.hasPrefix(ResearchBrief.finish) {
                    if mode == .researchNoSearchReport { calls = [RuntimeToolCall(id: "report-search", name: "web_search", arguments: "{\"query\":\"status\"}")] }
                    content = calls.isEmpty ? "# Findings\nCurrent identifier Cobalt, revision 73.\n## Sources\nhttps://example.com/current" : ""
                } else if messages.last?["role"] == "user", mode == .researchSplit, last.contains("The previous attempt did not finish") {
                    calls = [RuntimeToolCall(id: "retry-fetch-\(count)", name: "fetch_url", arguments: "{\"url\":\"https://example.com/status\"}")]
                    content = ""
                } else if messages.last?["role"] == "user" {
                    calls = [RuntimeToolCall(id: "search-\(count)", name: "web_search", arguments: "{\"query\":\"status\"}")]
                    content = ""
                } else if messages.last?["tool_call_id"]?.hasPrefix("search-") == true {
                    if mode == .researchSplit {
                        content = "The snippet does not supply the answer."
                    } else {
                        if mode == .researchSearchOnly {
                            calls = [RuntimeToolCall(id: "advance-\(count)", name: "advance", arguments: "{\"step\":1}")]
                        } else {
                            calls = [RuntimeToolCall(id: "fetch-\(count)", name: "fetch_url", arguments: "{\"url\":\"https://example.com/\(mode == .researchUnrelated ? "other" : "status")\"}")]
                        }
                        content = ""
                    }
                } else { content = "Read Cobalt revision 73 at https://example.com/current." }
                raw = calls.isEmpty ? content : calls.map { "<tool_call>{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}</tool_call>" }.joined(separator: "\n")
            } else if [.canvasRounds, .canvasBeyondRounds, .canvasCallCap].contains(mode) {
                if count <= 8 || mode == .canvasBeyondRounds {
                    let name = mode == .canvasCallCap ? "write_file" : "show_website"
                    let arguments = mode == .canvasCallCap ? "{\"path\":\"builder-\(count).txt\",\"content\":\"saved\"}" : "{\"path\":\"site/index.html\"}"
                    calls = [RuntimeToolCall(id: "builder-\(count)", name: name, arguments: arguments)]
                }
                content = calls.isEmpty ? "Builder answer." : ""
                raw = calls.isEmpty ? content : "<tool_call>{\"name\":\"\(calls[0].name)\",\"arguments\":\(calls[0].arguments)}</tool_call>"
            } else if mode == .canvas {
                if messages.last?["role"] == "user" {
                    calls = [RuntimeToolCall(id: "canvas-preview", name: "show_website", arguments: "{\"path\":\"site/index.html\"}")]
                }
                content = calls.isEmpty ? (messages.last?["content"] ?? "") : ""
                raw = calls.isEmpty ? content : "<tool_call>{\"name\":\"show_website\",\"arguments\":\(calls[0].arguments)}</tool_call>"
            } else if mode == .script || mode == .scriptThenSearch {
                if messages.last?["role"] == "user" && !(messages.last?["content"]?.hasPrefix("Finish the check using the available results.") ?? false) {
                    let args = lock.withLock { scriptArguments }
                    calls = [RuntimeToolCall(id: "script-\(count)", name: "run_script", arguments: args)]
                }
                if mode == .scriptThenSearch && count == 2 {
                    calls = [RuntimeToolCall(id: "script-search", name: "web_search", arguments: "{\"query\":\"Cedar\"}")]
                }
                content = calls.isEmpty ? (messages.last(where: { $0["role"] == "tool" })?["content"] ?? messages.last?["content"] ?? "") : ""
                raw = calls.isEmpty ? content : "<tool_call>{\"name\":\"\(calls[0].name)\",\"arguments\":\(calls[0].arguments)}</tool_call>"
            } else if mode == .watchStaleThenFetch || mode == .watchRefusedFetch {
                if (mode == .watchStaleThenFetch && count == 2) || (mode == .watchRefusedFetch && count == 1) {
                    calls = [RuntimeToolCall(id: "fresh-watch", name: "fetch_url", arguments: "{\"url\":\"https://example.com/page\"}")]
                    content = ""; raw = "<tool_call>{\"name\":\"fetch_url\",\"arguments\":\(calls[0].arguments)}</tool_call>"
                } else { content = "UNCHANGED."; raw = content }
            } else if [.media, .readThenMedia].contains(mode) {
                if mode == .readThenMedia && count == 1 { calls = [RuntimeToolCall(id: "read-private-media", name: "read_file", arguments: "{\"path\":\"user.txt\"}")] }
                else if count == 1 || (mode == .readThenMedia && count == 2) { calls = [RuntimeToolCall(id: "pictures", name: "show_pictures", arguments: "{\"query\":\"Cedar\",\"kind\":\"images\"}")] }
                content = calls.isEmpty ? "The picture results were handled." : ""
                raw = calls.isEmpty ? content : calls.map { "<tool_call>{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}</tool_call>" }.joined(separator: "\n")
            } else if [.fetch, .fetchTwice, .fetchThenWrite, .fetchSave].contains(mode), count == 1 {
                let args = mode == .fetchSave ? "{\"url\":\"https://example.com/page\",\"save_to\":\"page.txt\"}" : "{\"url\":\"https://example.com/page\"}"
                calls = [RuntimeToolCall(id: "fetch-1", name: "fetch_url", arguments: args)]
                if mode == .fetchThenWrite { calls.append(RuntimeToolCall(id: "write-after-web", name: "write_file", arguments: "{\"path\":\"after-web.txt\",\"content\":\"Cedar\"}")) }
                content = ""; raw = calls.map { "<tool_call>{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}</tool_call>" }.joined(separator: "\n")
            } else if mode == .fetchTwice && count == 2 {
                calls = [RuntimeToolCall(id: "fetch-2", name: "fetch_url", arguments: "{\"url\":\"https://example.com/next\"}")]
                content = ""; raw = "<tool_call>{\"name\":\"fetch_url\",\"arguments\":\(calls[0].arguments)}</tool_call>"
            } else if [.fetch, .fetchTwice, .fetchThenWrite, .fetchSave].contains(mode) {
                content = "Answer based on: " + (messages.last?["content"] ?? ""); raw = content
            } else if [.search, .searchTwice, .readThenSearch, .searchThenFetch, .searchThenWrite].contains(mode) {
                if mode == .readThenSearch && count == 1 {
                    calls = [RuntimeToolCall(id: "private-read", name: "read_file", arguments: "{\"path\":\"user.txt\"}")]
                } else if count == 1 || (mode == .searchTwice && count == 2) || (mode == .readThenSearch && count == 2) {
                    let query = mode == .readThenSearch ? "Original Cedar" : count == 2 ? "updated Cedar" : "Cedar status"
                    calls = [RuntimeToolCall(id: "search-\(count)", name: "web_search", arguments: "{\"query\":\"\(query)\"}")]
                    if mode == .searchThenWrite { calls.append(RuntimeToolCall(id: "write-after-search", name: "write_file", arguments: "{\"path\":\"after-search.txt\",\"content\":\"Cedar\"}")) }
                } else if mode == .searchThenFetch && count == 2 {
                    calls = [RuntimeToolCall(id: "fetch-search-result", name: "fetch_url", arguments: "{\"url\":\"https://example.com/\"}")]
                }
                content = calls.isEmpty ? "Answer based on: " + (messages.last?["content"] ?? "") : ""
                raw = calls.isEmpty ? content : calls.map { "<tool_call>{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}</tool_call>" }.joined(separator: "\n")
            } else if mode == .watchRequest {
                if count == 1 {
                    calls = [RuntimeToolCall(id: "watch-request", name: "watch", arguments: "{\"task\":\"Remind me to review Cedar\",\"every_minutes\":1}")]
                    content = ""; raw = "<tool_call>\n{\"name\":\"watch\",\"arguments\":\(calls[0].arguments)}\n</tool_call>"
                } else { content = "The request was handled."; raw = content }
            } else if mode == .watchReminder || mode == .watchCapped {
                content = "Review Cedar now.\nUNCHANGED"; raw = content
            } else if mode == .seeded {
                content = "Cedar."; raw = content
            } else if folding {
                content = mode == .foldingEmpty ? "" : messages.contains { $0["content"]?.contains(ConversationCompactor.instruction) == true } ? "Cedar moved from Porto to Osaka. Budget 730. Keep the vegetarian constraint." : "Continued with the saved context."
                raw = content
            } else if [.goalEmpty, .goalCapped, .goalUnknown, .goalRepeatPlan, .goalAdvance, .goalManyAdvance, .goalQuestion, .goal, .goalWrongAdvance, .goalFailedTools].contains(mode) {
                if mode == .goalQuestion, count == 1 {
                    calls = [RuntimeToolCall(id: "goal-question", name: "ask_user", arguments: "{\"question\":\"Which month?\"}")]
                    content = ""; raw = "<tool_call>\n{\"name\":\"ask_user\",\"arguments\":{\"question\":\"Which month?\"}}\n</tool_call>"
                } else if last.contains("Plan this out") || last == ChatController.planRepair || (mode == .goalQuestion && messages.last?["role"] == "tool") {
                    content = "1. Find the document\n2. Write the summary"; raw = content
                } else if last.contains("Carry out this one step"), mode == .goalAdvance || mode == .goalManyAdvance {
                    let steps = mode == .goalManyAdvance ? [1, 2] : [last.components(separatedBy: "\n\n").dropFirst().first == "Write the summary" ? 2 : 1]
                    calls = steps.map { RuntimeToolCall(id: "advance-\(count)-\($0)", name: "advance", arguments: "{\"step\":\($0)}") }
                    content = ""; raw = calls.map { "<tool_call>\n{\"name\":\"advance\",\"arguments\":\($0.arguments)}\n</tool_call>" }.joined(separator: "\n")
                } else if last.contains("Carry out this one step"), mode == .goalEmpty {
                    content = ""; raw = content
                } else if last.contains("Carry out this one step"), mode == .goalRepeatPlan {
                    content = "1. Find the document\n2. Write the summary"; raw = content
                } else if last.contains("Carry out this one step"), mode == .goalWrongAdvance {
                    calls = [RuntimeToolCall(id: "wrong-\(count)", name: "advance", arguments: "{\"step\":2}")]
                    content = ""; raw = "<tool_call>\n{\"name\":\"advance\",\"arguments\":{\"step\":2}}\n</tool_call>"
                } else if last.contains("Carry out this one step"), mode == .goalFailedTools {
                    calls = [RuntimeToolCall(id: "failed-\(count)", name: "invented_tool", arguments: "{}")]
                    content = ""; raw = "<tool_call>\n{\"name\":\"invented_tool\",\"arguments\":{}}\n</tool_call>"
                } else { content = "Finished the assigned step."; raw = content }
            } else if [.planRepair, .planNoRepair, .proseQuestion].contains(mode) {
                content = mode == .proseQuestion ? "Which city?" : mode == .planRepair && count > 1 ? "1. Read the question\n2. Calculate the answer" : "4"
                raw = content
            } else if last == ChatController.planRepair {
                content = "1. Find the document\n2. Write the summary"; raw = content
            } else if [.planning, .question, .advance, .invalidQuestion].contains(mode) {
                if mode == .planning { content = "1. Find the document\n2. Write the summary"; raw = content }
                else {
                    if count == 1 {
                        let name = mode == .advance ? "advance" : "ask_user"
                        let args = mode == .advance ? "{\"step\":1}" : mode == .invalidQuestion ? "{\"question\":\"  \"}" : "{\"question\":\"Which city?\",\"options\":[\"Osaka\",\"Porto\"]}"
                        calls = [RuntimeToolCall(id: "planning-1", name: name, arguments: args)]
                    }
                    content = calls.isEmpty ? "Answer based on: " + (messages.last?["content"] ?? "") : ""
                    raw = calls.isEmpty ? content : "<tool_call>\n{\"name\":\"\(calls[0].name)\",\"arguments\":\(calls[0].arguments)}\n</tool_call>"
                }
            } else if [.watchReadThenWrite, .fileWrite, .fileReplace, .fileRounds, .manyFiles, .readThenWrite, .fileSettled, .fileRefusal, .declinedThenWrite].contains(mode) {
                if (mode == .fileSettled || mode == .fileRefusal) && count <= 3 {
                    let name = mode == .fileSettled ? (count == 2 ? "delete_file" : "write_file") : (count == 2 ? "write_file" : "read_file")
                    let args = name == "write_file" ? "{\"path\":\"future.txt\",\"content\":\"Cedar\"}" : "{\"path\":\"future.txt\"}"
                    calls = [RuntimeToolCall(id: "file-\(count)", name: name, arguments: args)]
                } else if mode == .declinedThenWrite && count <= 2 {
                    let names = count == 1 ? ["declined.txt", "allowed.txt"] : ["declined.txt"]
                    calls = names.map { RuntimeToolCall(id: "file-\(count)-\($0)", name: "write_file",
                        arguments: "{\"path\":\"\($0)\",\"content\":\"Cedar\"}") }
                } else if (mode == .readThenWrite && (count == 1 || last.contains("Now save the note."))) || (mode == .watchReadThenWrite && count <= 2) {
                    calls = [RuntimeToolCall(id: "file-\(count)", name: count == 1 ? "read_file" : "write_file",
                        arguments: count == 1 ? "{\"path\":\"user.txt\"}" : "{\"path\":\"new.txt\",\"content\":\"Cedar\"}")]
                } else if mode == .fileRounds && count <= 4 {
                    let names = ["find_files", "read_file", "write_file", "delete_file"]
                    let args = ["{\"pattern\":\"*.txt\"}", "{\"path\":\"user.txt\"}", "{\"path\":\"scratch.txt\",\"content\":\"Cedar\"}", "{\"path\":\"scratch.txt\"}"]
                    calls = [RuntimeToolCall(id: "file-\(count)", name: names[count - 1], arguments: args[count - 1])]
                } else if mode == .manyFiles && count <= 3 {
                    for index in 0..<(count == 1 ? 4 : count == 2 ? 3 : 1) {
                        calls.append(RuntimeToolCall(id: "file-\(count)-\(index)", name: "write_file",
                            arguments: "{\"path\":\"file-\(count)-\(index).txt\",\"content\":\"saved\"}"))
                    }
                } else if count == 1 && (mode == .fileWrite || mode == .fileReplace) {
                    let args = mode == .fileReplace ? "{\"path\":\"user.txt\",\"content\":\"changed\",\"replace\":true}" : "{\"path\":\"new.txt\",\"content\":\"Cedar\"}"
                    calls = [RuntimeToolCall(id: "file-1", name: "write_file", arguments: args)]
                }
                content = calls.isEmpty ? "Answer based on: " + (messages.last?["content"] ?? "") : ""
                raw = calls.isEmpty ? content : calls.map { "<tool_call>\n{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}\n</tool_call>" }.joined(separator: "\n")
            } else if mode == .repeatWrites || mode == .repeatSame || count % 2 == 1 {
                let name = mode == .read ? "read_memory" : "save_memory"
                let arguments = mode == .read ? "{}" : mode == .repeatSame ? "{\"fact\":\"Prefers tea\"}" : "{\"fact\":\"Prefers tea \(count)\"}"
                calls = [RuntimeToolCall(id: "call-\(count)", name: name, arguments: arguments)]
                if mode == .multipleCalls {
                    calls = [RuntimeToolCall(id: "", name: name, arguments: arguments),
                             RuntimeToolCall(id: "", name: name, arguments: "{\"fact\":\"Prefers coffee\"}")]
                }
                raw = calls.map { "<tool_call>\n{\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}\n</tool_call>" }.joined(separator: "\n")
                content = ""
            } else { content = "Answer based on: " + (messages.last?["content"] ?? ""); raw = content }
            if count == 1 {
                do { try beforeFirstReply?() } catch { stream.finish(throwing: error); return }
            }
            let emit = { [self] in
            stream.yield(.token(raw))
            stream.yield(.reply(RuntimeReply(content: content, promptContent: mode == .seeded ? "<think>\n\n</think>\n\n" + content : nil, generatedTokens: 20, cachedTokens: 0,
                contextUsed: 40, contextSize: settings.contextTokens, firstTextMilliseconds: 1, tokensPerSecond: 100,
                cancelled: mode == .foldingCancelled, toolCalls: calls,
                stopReason: (mode == .researchCappedReport && last.hasPrefix(ResearchBrief.finish)) || (mode == .foldingCapped && !(completeMediaReadings && last.hasPrefix("Read only this attached file."))) || mode == .watchCapped || (mode == .goalCapped && last.contains("Carry out this one step")) ? .maxTokens : mode == .foldingUnknown || (mode == .goalUnknown && last.contains("Carry out this one step")) ? .unknown : mode == .foldingCancelled ? .cancelled : .endOfTurn,
                usage: usageMetrics)))
            stream.finish()
            }
            if let gate = self.streamGate { Task { await gate.wait(); emit() } } else { emit() }
        }
    }
}

@MainActor final class Fixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let runtime: FixtureRuntime
    let memory: MemoryController
    let files: WorkspaceController
    let chat: ChatController
    let downloads: ModelDownloads
    let watches: WatchController
    let web: WebController
    let conversationFile: URL
    init(scriptRunner: (any ScriptRunner)? = nil, mode: FixtureRuntime.Mode = .write, supportsTools: Bool = true, read: Bool = false, write: Bool = true, haltReason: @escaping @MainActor () -> String? = { nil }, watchHaltReason: (@MainActor (Bool) -> String?)? = nil, backend: ModelBackend = .llamaCPU, scheduler: (any WatchScheduling)? = nil, clock: @escaping () -> Date = Date.init, webClient: PublicWebClient = PublicWebClient(), searchTransport: any SearchHTTPTransport = SearchHTTPClient(), proxyCredentials: any SearchProxyCredentialStoring = AppleSearchProxyCredentialStore(), usage: Bool = false, attachmentsEnabled: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openweights-controller-" + UUID().uuidString)
        suite = "openweights.controller." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        runtime = FixtureRuntime(mode, supportsTools: supportsTools)
        memory = MemoryController(store: try MemoryStore(file: root.appendingPathComponent("memory.json")), defaults: defaults)
        memory.readEnabled = read; memory.writeEnabled = write
        files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        var model = LocalModel(name: "Host fixture", backend: backend, entryFile: "fixture.gguf", files: [ModelFile(path: "fixture.gguf")])
        let modelsRoot = root.appendingPathComponent("Models")
        let directory = modelsRoot.appendingPathComponent(model.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(model.entryFile)
        let data = Data("GGUF host fixture, not inference weights".utf8)
        try data.write(to: file)
        model.files[0].bytes = Int64(data.count); model.files[0].sha256 = try ModelFileTransfer.hash(file); model.state = .ready
        downloads = ModelDownloads(root: modelsRoot, models: [model])
        conversationFile = root.appendingPathComponent("conversations.json")
        let injected = runtime
        watches = WatchController(store: try WatchStore(file: root.appendingPathComponent("watches.json")), defaults: defaults, scheduler: scheduler, clock: clock)
        web = WebController(defaults: defaults, client: webClient, searchTransport: searchTransport, mediaCache: MediaPreviewCache(root: root.appendingPathComponent("Media"), client: webClient), proxyCredentials: proxyCredentials)
        web.searchEnabled = false; web.mediaEnabled = false
        chat = ChatController(store: try ConversationStore(file: conversationFile), downloads: downloads, memory: memory, files: files, goals: try GoalStore(file: root.appendingPathComponent("goal.json")),
                              watches: watches, web: web, scriptRunner: scriptRunner, defaults: defaults, runtimeFactory: { _ in injected }, goalHaltReason: haltReason, watchHaltReason: watchHaltReason ?? { _ in haltReason() },
                              usage: usage ? try UsageStore(file: root.appendingPathComponent("usage.json")) : nil,
                              attachments: attachmentsEnabled ? AttachmentController(store: try ChatAttachmentStore(root: root.appendingPathComponent("Attachments"))) : nil)
        watches.bind(chat)
    }
    func loadAndSend() async throws {
        await chat.load(chat.downloads.models[0]); try require(chat.error == nil, "Fixture load failed: \(chat.error ?? "")")
        chat.draft = "Use the enabled memory tools."; await chat.send()
    }
    var sharedFolder: URL { root.appendingPathComponent("Shared") }
    func prepareFiles(mode: AgentMode = .auto) async throws {
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        try Data("Original Cedar".utf8).write(to: sharedFolder.appendingPathComponent("user.txt"))
        await files.choose(sharedFolder)
        try require(files.error == nil, "Folder grant failed: \(files.error ?? "")")
        files.enabled = Set(FileToolDefinitions.all.map(\.name)); files.mode = mode
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@main struct ControllerChecks {
    @MainActor static func waitForGate(_ gate: PreparationGate) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await gate.entered) {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CheckFailure("Preparation never reached its async gate.") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func preparationChecks(_ passed: inout [String]) async throws {
        let inactive = try Fixture(mode: .seeded, supportsTools: false, write: false); defer { inactive.cleanup() }
        inactive.runtime.beforeFirstReply = { inactive.chat.prepareForInactivity() }
        try await inactive.loadAndSend(); try await wait("Inactive chat did not stop") { !inactive.chat.busy }
        try require(inactive.runtime.cancellationCount > 0 && inactive.chat.current?.messages.last?.status == .cancelled && inactive.chat.error == nil,
                    "App inactivity left a normal turn running or lost its interrupted state.")
        inactive.runtime.beforeFirstReply = nil
        inactive.chat.draft = "Continue after reopening"; await inactive.chat.send(); try await wait("Inactive chat did not recover") { !inactive.chat.busy }
        try require(inactive.chat.current?.messages.last?.status == .complete && inactive.chat.error == nil, "An inactive turn prevented the next foreground reply.")
        passed.append("app-inactivity-cancels-normal-turn-and-foreground-reply-recovers")

        let inactiveLoad = try Fixture(mode: .seeded, write: false); defer { inactiveLoad.cleanup() }
        let inactiveGate = PreparationGate(); inactiveLoad.runtime.loadGate = inactiveGate
        let inactiveTask = Task { await inactiveLoad.chat.load(inactiveLoad.chat.downloads.models[0]) }
        try await waitForGate(inactiveGate); inactiveLoad.chat.prepareForInactivity(); await inactiveGate.release(); await inactiveTask.value
        try require(inactiveLoad.runtime.cancellationCount > 0 && inactiveLoad.chat.loadedModel == nil && !inactiveLoad.chat.loading && inactiveLoad.chat.error == nil,
                    "App inactivity admitted a prepared model or left loading active.")
        passed.append("app-inactivity-cancels-published-runtime-during-model-preparation")

        let seeded = try Fixture(mode: .seeded, supportsTools: false, write: false); defer { seeded.cleanup() }
        try await seeded.loadAndSend(); try await wait("Seeded answer did not finish") { !seeded.chat.busy }
        let seed = "<think>\n\n</think>\n\nCedar."
        try require(seeded.chat.current?.messages.last?.content == "Cedar." && seeded.chat.current?.messages.last?.promptContent == seed,
                    "The adapter's rendered head was lost or leaked into displayed text.")
        seeded.chat.draft = "Recall the project"; await seeded.chat.send(); try await wait("Seeded continuation did not finish") { !seeded.chat.busy }
        try require(seeded.runtime.captures.last?.messages.contains { $0["role"] == "assistant" && $0["content"] == seed } == true,
                    "The next turn dropped the exact serialized assistant head.")
        let reopened = try ConversationStore(file: seeded.conversationFile)
        let saved = try await reopened.conversation(seeded.chat.current!.id)
        try require(saved.messages.filter { $0.role == .assistant }.allSatisfy { $0.content == "Cedar." && $0.promptContent == seed },
                    "Reopen lost the distinction between prompt history and visible answers.")
        passed.append("adapter-assistant-head-persists-for-next-turn-and-reopen-with-plain-display-text")
        let serialized = try Fixture(mode: .folding, write: false); defer { serialized.cleanup() }
        let model = serialized.chat.downloads.models[0]
        await serialized.chat.load(model)
        let warm = PreparationGate(); serialized.runtime.warmGate = warm
        let creating = Task { await serialized.chat.newConversation() }
        try await waitForGate(warm)
        let id = serialized.chat.current?.id
        serialized.chat.draft = "Keep this draft"
        await serialized.chat.send(); await serialized.chat.load(model)
        await serialized.chat.open(Conversation(title: "Blocked selection"))
        let second = await serialized.chat.newConversation()
        try require(serialized.chat.loading && !second && serialized.chat.current?.id == id && serialized.chat.draft == "Keep this draft" && serialized.runtime.captures.isEmpty,
                    "Preparation allowed competing selection, loading, creation or inference.")
        serialized.chat.cancel(); await warm.release()
        let created = await creating.value
        try require(!created && !serialized.chat.loading && !serialized.chat.busy && serialized.chat.error == nil && serialized.runtime.cancellationCount > 0,
                    "Stop failed to reach the preparing runtime or surfaced a cancellation error.")
        serialized.runtime.warmGate = nil
        await serialized.chat.send(); try await wait("Recovery after stopped warming failed") { !serialized.chat.busy }
        try require(serialized.chat.error == nil && serialized.runtime.captures.count == 1 && serialized.chat.current?.messages.first?.content == "Keep this draft",
                    "A stopped preparation lost its draft or prevented the next send.")
        passed.append("chat-preparation-serializes-selection-and-send-stop-preserves-draft-and-recovers")

        for goal in [false, true] {
            let stopped = try Fixture(mode: .folding, write: false); defer { stopped.cleanup() }
            await stopped.chat.load(stopped.chat.downloads.models[0])
            let gate = PreparationGate(); stopped.runtime.warmGate = gate
            stopped.chat.draft = "Do not generate yet"
            let task = Task { if goal { await stopped.chat.startGoal("Do not start yet") } else { await stopped.chat.send() } }
            try await waitForGate(gate)
            stopped.chat.cancel(); await gate.release(); await task.value
            try require(stopped.runtime.captures.isEmpty && stopped.chat.current?.messages.isEmpty == true && stopped.chat.workGoal == nil && !stopped.chat.busy && !stopped.chat.loading && stopped.chat.error == nil,
                        "Stopping implicit new-chat preparation still started an answer or goal.")
        }
        passed.append("stop-during-implicit-chat-warming-prevents-answer-and-goal-start")

        let counting = try Fixture(mode: .folding, write: false); defer { counting.cleanup() }
        await counting.chat.load(counting.chat.downloads.models[0])
        let count = PreparationGate(); let neverWarm = PreparationGate()
        counting.runtime.countGate = count; counting.runtime.warmGate = neverWarm
        let prepare = Task { await counting.chat.newConversation() }
        try await waitForGate(count); counting.chat.cancel(); await count.release()
        let prepared = await prepare.value
        let warmedAfterStop = await neverWarm.entered
        try require(!prepared && !warmedAfterStop && !counting.chat.loading && counting.chat.error == nil,
                    "Warming reset an earlier Stop after async token counting.")
        passed.append("stop-during-token-counting-prevents-subsequent-warming")

        let loading = try Fixture(mode: .folding, write: false); defer { loading.cleanup() }
        let load = PreparationGate(); loading.runtime.loadGate = load
        let loadTask = Task { await loading.chat.load(loading.chat.downloads.models[0]) }
        try await waitForGate(load); loading.chat.cancel(); await load.release(); await loadTask.value
        try require(loading.runtime.cancellationCount > 0 && loading.chat.loadedModel == nil && !loading.chat.loading && loading.chat.error == nil,
                    "Stop could not reach new weights or admitted a cancelled load.")
        loading.runtime.loadGate = nil
        await loading.chat.load(loading.chat.downloads.models[0])
        try require(loading.chat.loadedModel != nil && loading.chat.error == nil, "A cancelled model load could not recover.")
        passed.append("stop-reaches-new-model-load-and-recovery-can-load-again")
    }
    @MainActor static func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CheckFailure(message) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func planningChecks(_ passed: inout [String]) async throws {
        let planned = try Fixture(mode: .planning, write: false); defer { planned.cleanup() }
        planned.files.mode = .plan; try await planned.loadAndSend()
        try await wait("Plan reply did not finish") { !planned.chat.busy }
        try require(planned.chat.current?.plan?.steps.map(\.text) == ["Find the document", "Write the summary"], "Numbered plan was not captured.")
        let oldTail = planned.chat.current!.messages[0].promptContent
        await planned.chat.setPlanStep(0, done: true)
        let reopenedPlan = try ConversationStore(file: planned.conversationFile)
        let savedPlan = try await reopenedPlan.conversation(planned.chat.current!.id)
        try require(savedPlan.plan?.steps[0].done == true && savedPlan.messages[0].promptContent == oldTail, "Manual tick was not durable or rewrote old prompt bytes.")
        await planned.chat.clearPlan(); try require(planned.chat.current?.plan == nil, "Clear plan failed.")
        passed.append("numbered-plan-capture-manual-tick-clear-and-stable-historical-prompt")

        let advancing = try Fixture(mode: .advance, write: false); defer { advancing.cleanup() }
        await advancing.chat.load(advancing.chat.downloads.models[0]); await advancing.chat.newConversation()
        var conversation = advancing.chat.current!
        conversation.plan = TaskPlan(steps: [TaskStep(text: "Find"), TaskStep(text: "Read")])
        await advancing.chat.update(conversation)
        advancing.files.mode = .ask; advancing.chat.draft = "Finish step one"; await advancing.chat.send()
        try await wait("Advance asked for action approval or hung") { !advancing.chat.busy || advancing.chat.pendingToolApproval != nil }
        try require(!advancing.chat.busy && advancing.chat.pendingToolApproval == nil && advancing.chat.current?.plan?.steps[0].done == true, "Advance failed in Ask mode.")
        try require(advancing.runtime.captures[0].tools == ["advance"] && advancing.chat.current?.messages.first(where: { $0.toolName == "advance" })?.planAfterMessage?.steps[0].done == true, "Advance availability or checkpoint is wrong.")
        passed.append("advance-offered-with-active-plan-and-runs-without-action-approval")

        let asked = try Fixture(mode: .question, write: false); defer { asked.cleanup() }
        asked.files.mode = .plan; try await asked.loadAndSend()
        try await wait("Question absent") { asked.chat.pendingUserQuestion != nil }
        let question = asked.chat.pendingUserQuestion!
        try require(asked.chat.pendingToolApproval == nil && asked.runtime.captures.count == 1, "Question requested action approval or generated while waiting.")
        let pendingReopen = try ConversationStore(file: asked.conversationFile)
        let pending = try await pendingReopen.conversation(asked.chat.current!.id)
        try require(pending.messages.last?.userQuestion?.id == question.id && pending.messages.last?.status == .cancelled, "Question was shown before its durable checkpoint.")
        await asked.chat.answerUserQuestion("Porto", ticketID: UUID())
        try require(asked.chat.pendingUserQuestion?.id == question.id, "Stale answer changed the pending question.")
        await asked.chat.answerUserQuestion("Porto", ticketID: question.id)
        try await wait("Answered question did not continue") { !asked.chat.busy }
        try require(asked.runtime.captures.count == 3 && asked.runtime.captures[1].messages.last?["content"]?.contains("Porto") == true && asked.chat.current?.messages.contains { $0.role == .tool && $0.toolName == "ask_user" && $0.content == "Porto" && $0.promptContent?.contains("Do not ask the same question again") == true } == true, "Exact answer was not replayed as tool result.")
        passed.append("question-durable-before-ui-exact-ticket-answer-and-followup")

        let skipped = try Fixture(mode: .question, write: false); defer { skipped.cleanup() }
        skipped.files.mode = .plan; try await skipped.loadAndSend()
        try await wait("Skip question absent") { skipped.chat.pendingUserQuestion != nil }
        await skipped.chat.answerUserQuestion(nil, ticketID: skipped.chat.pendingUserQuestion!.id)
        try await wait("Skipped question did not continue") { !skipped.chat.busy }
        try require(skipped.runtime.captures.count == 3 && skipped.runtime.captures[1].messages.last?["content"]?.contains("did not answer") == true, "Skip did not produce the explicit fallback.")
        passed.append("skipped-question-continues-with-explicit-fallback")

        let stopped = try Fixture(mode: .question, write: false); defer { stopped.cleanup() }
        stopped.files.mode = .plan; try await stopped.loadAndSend()
        try await wait("Stop question absent") { stopped.chat.pendingUserQuestion != nil }
        stopped.chat.cancel(); try await wait("Stop left question suspended") { !stopped.chat.busy }
        try require(stopped.chat.pendingUserQuestion == nil && stopped.runtime.captures.count == 1 && stopped.chat.current?.messages.last?.status == .failed, "Stop ran another generation or retained question.")
        passed.append("stop-at-question-clears-continuation-without-another-model-pass")

        let recovering = try Fixture(mode: .question, write: false); defer { recovering.cleanup() }
        try await recovering.prepareFiles(mode: .plan); try await recovering.loadAndSend()
        try await wait("Recovery question absent") { recovering.chat.pendingUserQuestion != nil }
        let snapshot = recovering.root.appendingPathComponent("interrupted.json")
        try FileManager.default.copyItem(at: recovering.conversationFile, to: snapshot)
        recovering.chat.cancel(); try await wait("Original question did not stop") { !recovering.chat.busy }
        let followup = FixtureRuntime(.fileWrite)
        let restored = ChatController(store: try ConversationStore(file: snapshot), downloads: recovering.chat.downloads,
            memory: recovering.memory, files: recovering.files, defaults: recovering.defaults, runtimeFactory: { _ in followup })
        await restored.restore()
        try require(restored.questionRecovered && !restored.busy && followup.captures.isEmpty, "Reopen replayed a question automatically.")
        let recoveredID = restored.pendingUserQuestion!.id
        try FileManager.default.removeItem(at: snapshot); try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        await restored.answerUserQuestion("Osaka", ticketID: recoveredID)
        try require(restored.pendingUserQuestion?.id == recoveredID && restored.questionRecovered, "Failed answer checkpoint dismissed the recovered card.")
        try FileManager.default.removeItem(at: snapshot)
        await restored.answerUserQuestion("Osaka", ticketID: recoveredID)
        try require(restored.canContinueQuestionAnswer && restored.pendingUserQuestion == nil && followup.captures.isEmpty, "Answer without loaded model replayed or failed to save.")
        recovering.files.mode = .auto
        await restored.load(recovering.chat.downloads.models[0]); restored.continueQuestionAnswer()
        try await wait("Recovered answer did not continue") { !restored.busy }
        try require(followup.captures.first?.messages.last?["content"]?.contains("Osaka") == true && restored.current?.messages.contains { $0.role == .tool && $0.content == "Osaka" && $0.promptContent?.contains("Do not ask the same question again") == true } == true, "Recovered answer was not the next inference input.")
        try require(followup.captures.first?.tools == ["ask_user"] && !FileManager.default.fileExists(atPath: recovering.sharedFolder.appendingPathComponent("new.txt").path),
                    "Recovered planning question resumed with action tools instead of planning-only tools.")
        passed.append("recovered-question-failed-save-preserves-card-answer-before-load-explicit-resume")

        let failedIntent = try Fixture(mode: .question, write: false); defer { failedIntent.cleanup() }
        failedIntent.files.mode = .plan
        let failureFile = failedIntent.conversationFile
        failedIntent.runtime.beforeFirstReply = {
            try FileManager.default.removeItem(at: failureFile)
            try FileManager.default.createDirectory(at: failureFile, withIntermediateDirectories: false)
        }
        try await failedIntent.loadAndSend(); try await wait("Failed intent did not settle") { !failedIntent.chat.busy }
        try require(failedIntent.chat.pendingUserQuestion == nil && failedIntent.chat.error != nil && failedIntent.runtime.captures.count == 1,
                    "A question appeared after its transcript checkpoint failed.")
        passed.append("failed-transcript-checkpoint-prevents-question-ui-and-followup")
        let failedTick = try Fixture(mode: .planning, write: false); defer { failedTick.cleanup() }
        failedTick.files.mode = .plan; try await failedTick.loadAndSend()
        try await wait("Tick fixture did not finish") { !failedTick.chat.busy }
        let originalPlan = failedTick.chat.current?.plan
        try FileManager.default.removeItem(at: failedTick.conversationFile)
        try FileManager.default.createDirectory(at: failedTick.conversationFile, withIntermediateDirectories: false)
        await failedTick.chat.setPlanStep(0, done: true)
        try require(failedTick.chat.current?.plan == originalPlan && failedTick.chat.error != nil && !failedTick.chat.boardUpdating,
                    "A failed manual plan checkpoint changed the displayed plan.")
        passed.append("failed-manual-plan-checkpoint-preserves-current-board")

        let unavailable = try Fixture(mode: .question, write: false); defer { unavailable.cleanup() }
        try await unavailable.loadAndSend(); try await wait("Unsolicited question did not settle") { !unavailable.chat.busy }
        try require(unavailable.chat.pendingUserQuestion == nil && unavailable.chat.current?.messages.first(where: { $0.toolName == "ask_user" })?.status == .failed, "Auto mode accepted an unoffered question.")
        let malformed = try Fixture(mode: .invalidQuestion, write: false); defer { malformed.cleanup() }
        malformed.files.mode = .plan; try await malformed.loadAndSend()
        try await wait("Malformed question suspended") { !malformed.chat.busy }
        try require(malformed.chat.pendingUserQuestion == nil && malformed.chat.current?.messages.first(where: { $0.toolName == "ask_user" })?.status == .failed, "Empty question opened UI.")
        passed.append("question-offer-gate-and-malformed-question-refusal")
    }
    @MainActor static func goalChecks(_ passed: inout [String]) async throws {
        let repaired = try Fixture(mode: .planRepair, write: false); defer { repaired.cleanup() }
        repaired.files.mode = .plan; try await repaired.loadAndSend()
        try await wait("Plan repair did not finish") { !repaired.chat.busy }
        try require(repaired.runtime.captures.count == 2 && repaired.chat.current?.plan?.steps.count == 2,
                    "A plain answer did not receive one bounded correction.")
        try require(repaired.runtime.captures[1].messages.last?["content"] == ChatController.planRepair &&
                    repaired.runtime.captures[0].tools == ["ask_user"], "Repair tail or Plan-only catalogue was wrong.")
        let noPlan = try Fixture(mode: .planNoRepair, write: false); defer { noPlan.cleanup() }
        noPlan.files.mode = .plan; try await noPlan.loadAndSend()
        try await wait("Repeated plain answers looped") { !noPlan.chat.busy }
        try require(noPlan.runtime.captures.count == 2 && noPlan.chat.current?.plan == nil, "Plan repair ran more than once or invented a plan.")
        let prose = try Fixture(mode: .proseQuestion, write: false); defer { prose.cleanup() }
        prose.files.mode = .plan; try await prose.loadAndSend()
        try await wait("Prose question did not finish") { !prose.chat.busy }
        try require(prose.runtime.captures.count == 1, "A clarification question was overwritten by Plan repair.")
        let ordinary = try Fixture(mode: .planRepair, write: false); defer { ordinary.cleanup() }
        try await ordinary.loadAndSend(); try await wait("Ordinary answer did not finish") { !ordinary.chat.busy }
        try require(ordinary.runtime.captures.count == 1, "Auto mode received a Plan correction.")
        passed.append("plan-repair-once-with-durable-tail-preserves-questions-and-auto-answers")

        let completed = try Fixture(mode: .goal, write: false); defer { completed.cleanup() }
        completed.files.mode = .plan
        await completed.chat.load(completed.chat.downloads.models[0])
        completed.chat.draft = "/goal Find and summarise the report"; await completed.chat.send()
        try await wait("Goal did not complete") { !completed.chat.goalActive && !completed.chat.busy }
        try require(completed.chat.workGoal?.state == .done && completed.chat.workGoal?.stepsTaken == 2 &&
                    completed.chat.current?.plan?.isFinished == true && completed.runtime.captures.count == 3,
                    "Two-step goal did not progress through ordinary durable turns.")
        try require(completed.files.mode == .auto && completed.chat.current?.title == "Find and summarise the report", "Plan mode or title leaked after goal completion.")
        let storedGoal = try GoalStore(file: completed.root.appendingPathComponent("goal.json"))
        let durable = await storedGoal.snapshot()
        try require(durable.goal?.state == .done && durable.goal?.conversationID == completed.chat.current?.id, "Goal was not durably bound to its conversation.")
        passed.append("slash-goal-plans-two-steps-host-ticks-once-and-persists-bound-completion")

        let ticked = try Fixture(mode: .goalAdvance, write: false); defer { ticked.cleanup() }
        await ticked.chat.load(ticked.chat.downloads.models[0]); await ticked.chat.startGoal("Do one step per turn")
        try await wait("Model-ticked goal did not finish") { !ticked.chat.goalActive && !ticked.chat.busy }
        try require(ticked.chat.workGoal?.state == .done && ticked.chat.workGoal?.stepsTaken == 2 && ticked.runtime.captures.count == 5,
                    "Model advance result: state=\(ticked.chat.workGoal?.state.rawValue ?? "none") steps=\(ticked.chat.workGoal?.stepsTaken ?? -1) captures=\(ticked.runtime.captures.count) error=\(ticked.chat.error ?? "none") arguments=\(ticked.chat.current?.messages.compactMap { $0.toolCalls?.map(\.argumentsJSON).joined(separator: ",") }.joined(separator: ";") ?? "none")")
        passed.append("model-advance-closes-only-one-step-without-host-double-tick")
        let jumped = try Fixture(mode: .goalManyAdvance, write: false); defer { jumped.cleanup() }
        await jumped.chat.load(jumped.chat.downloads.models[0]); await jumped.chat.startGoal("Do not skip verification")
        try await wait("Multiple advances did not halt") { !jumped.chat.goalActive && !jumped.chat.busy }
        try require(jumped.chat.workGoal?.state == .halted && jumped.chat.workGoal?.stepsTaken == 0 && jumped.chat.current?.plan?.steps.allSatisfy({ !$0.done }) == true,
                    "Two advances in one turn were accepted as completed work.")
        passed.append("multiple-advance-calls-in-one-step-roll-back-before-retry")

        let wrong = try Fixture(mode: .goalWrongAdvance, write: false); defer { wrong.cleanup() }
        await wrong.chat.load(wrong.chat.downloads.models[0]); await wrong.chat.startGoal("Do each step")
        try await wait("Wrong advance did not halt") { !wrong.chat.goalActive && !wrong.chat.busy }
        try require(wrong.chat.workGoal?.state == .halted && wrong.chat.workGoal?.stepsTaken == 0 &&
                    wrong.chat.current?.plan?.steps.allSatisfy({ !$0.done }) == true && wrong.runtime.captures.count == 5,
                    "Wrong step was counted, not rolled back, or retried more than once.")
        try require(wrong.chat.workGoal?.note?.contains("two consecutive") == true, "Failure cap was not explained.")
        passed.append("wrong-advance-rolls-back-and-two-failed-attempts-halt")
        let repeating = try Fixture(mode: .goalRepeatPlan, write: false); defer { repeating.cleanup() }
        await repeating.chat.load(repeating.chat.downloads.models[0]); await repeating.chat.startGoal("Carry out the two steps.")
        try await wait("Repeated plan did not halt") { !repeating.chat.goalActive }
        try require(repeating.chat.workGoal?.state == .halted && repeating.chat.workGoal?.stepsTaken == 0 && repeating.chat.current?.plan?.steps.allSatisfy({ !$0.done }) == true,
                    "A repeated plan was treated as completed work.")
        passed.append("goal-repeated-plan-without-action-result-halts-without-marking-steps-done")

        for mode in [FixtureRuntime.Mode.goalEmpty, .goalCapped, .goalUnknown] {
            let incomplete = try Fixture(mode: mode, write: false); defer { incomplete.cleanup() }
            await incomplete.chat.load(incomplete.chat.downloads.models[0])
            await incomplete.chat.startGoal("Do the two steps.")
            try await wait("Unfinished answer did not halt") { !incomplete.chat.goalActive && !incomplete.chat.busy }
            try require(incomplete.chat.workGoal?.state == .halted && incomplete.chat.workGoal?.stepsTaken == 0 &&
                        incomplete.chat.current?.plan?.steps.allSatisfy({ !$0.done }) == true && incomplete.runtime.captures.count == 3,
                        "An empty, truncated or unproven answer completed goal work: \(mode)")
            passed.append("goal-\(mode)-answer-halts-without-marking-steps-done")
        }

        let failed = try Fixture(mode: .goalFailedTools, write: false); defer { failed.cleanup() }
        await failed.chat.load(failed.chat.downloads.models[0]); await failed.chat.startGoal("Use tools")
        try await wait("Failed tools did not halt goal") { !failed.chat.goalActive && !failed.chat.busy }
        try require(failed.chat.workGoal?.state == .halted && failed.chat.workGoal?.stepsTaken == 0 && failed.runtime.captures.count == 5,
                    "A failed tool was counted as completed work.")
        passed.append("all-refused-tools-cannot-implicitly-complete-a-goal-step")

        var safetyChecks = 0
        let heated = try Fixture(mode: .goal, write: false, haltReason: { safetyChecks += 1; return safetyChecks >= 2 ? "Critical heat fixture" : nil })
        defer { heated.cleanup() }
        await heated.chat.load(heated.chat.downloads.models[0]); await heated.chat.startGoal("Bounded task")
        try await wait("Heat boundary did not halt") { !heated.chat.goalActive }
        try require(heated.chat.workGoal?.state == .halted && heated.runtime.captures.count == 1 && heated.chat.workGoal?.note == "Critical heat fixture",
                    "The environmental check allowed another step.")
        let flat = try Fixture(mode: .goal, write: false, haltReason: { "Battery below 15% fixture" }); defer { flat.cleanup() }
        await flat.chat.load(flat.chat.downloads.models[0]); await flat.chat.startGoal("Bounded task")
        try await wait("Low-battery guard did not halt") { !flat.chat.goalActive }
        try require(flat.runtime.captures.isEmpty && flat.chat.workGoal?.state == .halted, "Low battery began inference.")
        passed.append("environmental-checks-halt-before-next-turn-or-planning")

        let steered = try Fixture(mode: .goalQuestion, write: false); defer { steered.cleanup() }
        await steered.chat.load(steered.chat.downloads.models[0]); await steered.chat.startGoal("Choose the month then summarise")
        try await wait("Goal question absent") { steered.chat.pendingUserQuestion != nil }
        let initialID = steered.chat.current!.id
        await steered.chat.newConversation(); try require(steered.chat.current?.id == initialID, "Conversation switched while goal waited.")
        await steered.chat.steerGoal("Only September notes")
        try require(steered.chat.workGoal?.steering == ["Only September notes"] && steered.runtime.captures.count == 1, "Steering interrupted the current turn.")
        await steered.chat.answerUserQuestion("September", ticketID: steered.chat.pendingUserQuestion!.id)
        try await wait("Steered goal did not finish") { !steered.chat.goalActive && !steered.chat.busy }
        let stepCaptures = steered.runtime.captures.filter { $0.messages.last?["content"]?.contains("Carry out this one step") == true }
        try require(steered.chat.workGoal?.state == .done && stepCaptures.count == 2 &&
                    stepCaptures[0].messages.last?["content"]?.contains("Only September notes") == true &&
                    stepCaptures[1].messages.last?["content"]?.contains("Since you started") == false,
                    "Steering was lost, applied in-flight or repeated on another step.")
        passed.append("goal-question-preserves-chat-and-steering-applies-at-one-boundary")

        let approvalMode = try Fixture(mode: .goalQuestion, write: false); defer { approvalMode.cleanup() }
        approvalMode.files.mode = .ask
        await approvalMode.chat.load(approvalMode.chat.downloads.models[0]); await approvalMode.chat.startGoal("Keep approval preferences")
        try await wait("Ask-mode goal question absent") { approvalMode.chat.pendingUserQuestion != nil }
        try require(approvalMode.defaults.string(forKey: "tools.mode") == "ask" && approvalMode.files.mode == .ask &&
                    approvalMode.runtime.captures[0].tools == ["ask_user"], "Planning overwrote the saved approval mode.")
        let recoveredFiles = WorkspaceController(bookmarkFile: approvalMode.root.appendingPathComponent("workspace.bookmark"), defaults: approvalMode.defaults)
        try require(recoveredFiles.mode == .ask, "Reopening during planning lost Ask mode.")
        approvalMode.chat.stopGoal(); try await wait("Approval-mode goal did not stop") { !approvalMode.chat.goalActive && !approvalMode.chat.busy }
        passed.append("goal-planning-override-keeps-ask-mode-durable-across-interruption")

        let stopped = try Fixture(mode: .goalQuestion, write: false); defer { stopped.cleanup() }
        await stopped.chat.load(stopped.chat.downloads.models[0]); await stopped.chat.startGoal("Ask first")
        try await wait("Goal Stop question absent") { stopped.chat.pendingUserQuestion != nil }
        stopped.chat.stopGoal()
        try await wait("Goal Stop left work alive") { !stopped.chat.goalActive && !stopped.chat.busy }
        try require(stopped.chat.workGoal?.state == .stopped && stopped.chat.pendingUserQuestion == nil && stopped.runtime.captures.count == 1,
                    "Stop retained a waiting question or generated another step.")
        passed.append("goal-stop-cancels-live-question-and-persists-stopped-state")

        let inactive = try Fixture(mode: .goalQuestion, write: false); defer { inactive.cleanup() }
        await inactive.chat.load(inactive.chat.downloads.models[0]); await inactive.chat.startGoal("Pause on leaving the app")
        try await wait("Inactive goal question absent") { inactive.chat.pendingUserQuestion != nil }
        inactive.chat.haltGoal("Paused while the app is inactive. Review the plan before resuming.")
        try await wait("Inactive goal left a live question") { !inactive.chat.goalActive && !inactive.chat.busy }
        try require(inactive.chat.workGoal?.state == .halted && inactive.chat.pendingUserQuestion == nil && inactive.runtime.captures.count == 1,
                    "Lifecycle halt continued inference or retained input for a stopped turn.")
        await inactive.chat.resumeGoal(); try await wait("Reviewed paused goal did not resume") { !inactive.chat.goalActive && !inactive.chat.busy }
        try require(inactive.chat.workGoal?.state == .done, "A reviewed lifecycle pause could not resume.")
        passed.append("lifecycle-halt-clears-live-question-and-waits-for-explicit-reviewed-resume")

        let freshRuntime = FixtureRuntime(.goal)
        let restored = ChatController(store: try ConversationStore(file: wrong.conversationFile), downloads: wrong.chat.downloads,
            memory: wrong.memory, files: wrong.files, goals: try GoalStore(file: wrong.root.appendingPathComponent("goal.json")),
            defaults: wrong.defaults, runtimeFactory: { _ in freshRuntime }, goalHaltReason: { nil })
        await restored.restore(); await restored.load(wrong.chat.downloads.models[0])
        try require(restored.workGoal?.state == .halted && freshRuntime.captures.isEmpty, "Recovered goal resumed automatically.")
        let oldID = restored.workGoal!.id
        await restored.resumeGoal(); try await wait("Explicit resumed goal did not finish") { !restored.goalActive && !restored.busy }
        try require(restored.workGoal?.id == oldID && restored.workGoal?.state == .done && freshRuntime.captures.count == 2,
                    "Explicit resume discarded its plan or replayed planning.")
        passed.append("goal-reopen-stays-halted-and-explicit-resume-keeps-identity-and-plan")
        let unwritable = try Fixture(mode: .goal, write: false); defer { unwritable.cleanup() }
        await unwritable.chat.load(unwritable.chat.downloads.models[0])
        try FileManager.default.createDirectory(at: unwritable.root.appendingPathComponent("goal.json"), withIntermediateDirectories: false)
        await unwritable.chat.startGoal("Do not run without checkpoint")
        try require(unwritable.runtime.captures.isEmpty && !unwritable.chat.goalActive && unwritable.chat.error != nil,
                    "A failed goal checkpoint started inference.")
        passed.append("failed-goal-start-checkpoint-prevents-model-execution")
    }
    @MainActor static func seedLongHistory(_ fixture: Fixture) async throws {
        await fixture.chat.load(fixture.chat.downloads.models[0]); await fixture.chat.newConversation()
        var value = fixture.chat.current!
        for turn in 0..<2 {
            value.messages.append(StoredMessage(role: .user, content: (turn == 0 ? "Cedar Porto 620 vegetarian. " : "Correction: Osaka 730 vegetarian. ") + String(repeating: "Context detail. ", count: 200)))
            value.messages.append(StoredMessage(role: .assistant, content: String(repeating: "Confirmed detail. ", count: 60)))
        }
        try await fixture.chat.store.save(value); await fixture.chat.open(value)
    }
    @MainActor static func foldingChecks(_ passed: inout [String]) async throws {
        let sentence = "Keep the latest correction in the briefing. "
        let quoted = "Keep \"Cedar\" and budget 730 exactly.\n"
        let unicode = "Keep Cedar, 大阪, café e\u{301}, and 👩🏽‍💻 in the written briefing. "
        let composed = "Keep café in the exact original briefing. "
        let decomposed = "Keep cafe\u{301} in the exact original briefing. "
        let cases = ["", "A decimal 6.20 stays exact. A unique tail", "Cedar. Cedar. Cedar. Cedar. ",
                     String(repeating: sentence, count: 180), String(repeating: quoted, count: 6),
                     composed + String(repeating: decomposed, count: 6),
                     "user:\nUnique facts Cedar and Porto. " + String(repeating: unicode, count: 9) + "\nassistant:\nCorrection: Osaka and 730.",
                     sentence + "A different sentence remains. " + sentence,
                     String(repeating: String(repeating: "a", count: 513) + ". ", count: 4),
                     sentence + sentence + sentence + "Keep the latest correction in the briefing.\n"]
        for original in cases {
            let runs = ConversationCompactor.sourceRuns(original)
            let expanded = runs.map { String(repeating: $0.text, count: $0.occurrences) }.joined()
            try require(expanded.utf8.elementsEqual(original.utf8), "Repeat grouping changed original bytes, roles, numbers or Unicode.")
            try require(runs.allSatisfy { !$0.text.isEmpty && $0.occurrences > 0 }, "An empty or invalid repeat run was created.")
        }
        let encoded = try ConversationCompactor.sourcePresentation(String(repeating: sentence, count: 180))
        try require(encoded.contains("180 occurrences") && encoded.utf8.count < sentence.utf8.count * 4,
                    "The long exact sentence run was not compactly represented with its count.")
        let escaped = String(decoding: try JSONEncoder().encode(quoted), as: UTF8.self)
        try require(try ConversationCompactor.sourcePresentation(String(repeating: quoted, count: 6)).contains(escaped),
                    "The quoted repeat literal did not retain JSON escaping.")
        let unchanged = sentence + "A different sentence remains. " + sentence
        try require(try ConversationCompactor.sourcePresentation(unchanged) == unchanged,
                    "Nonadjacent or nonrepeated source was rewritten.")
        passed.append("summary-repeat-presentation-retains-exact-counts-roles-unicode-and-unique-source")
        let folded = try Fixture(mode: .folding, write: false); defer { folded.cleanup() }
        try await seedLongHistory(folded)
        let original = folded.chat.current!.messages
        folded.chat.draft = "Continue with the corrected city."; await folded.chat.send()
        try await wait("Fold did not finish") { !folded.chat.busy }
        try require(folded.chat.error == nil && folded.chat.current?.fold?.messageCount == 4, "Automatic summary was not committed: \(folded.chat.error ?? "")")
        try require(Array(folded.chat.current!.messages.prefix(4)) == original && folded.chat.current!.messages.count == 6, "Folding changed the visible transcript.")
        let summaryPasses = folded.runtime.captures.filter { $0.messages.last?["content"]?.contains(ConversationCompactor.instruction) == true }
        try require(summaryPasses.count >= 2 && summaryPasses.allSatisfy { $0.tools.isEmpty }, "Long summary was not segmented without action tools.")
        let answer = folded.runtime.captures.last!
        try require(answer.messages.first?["content"] == ChatController.systemPrompt && answer.messages.contains { $0["content"]?.contains("Earlier conversation summary") == true } &&
                    answer.messages.last?["content"] == "Continue with the corrected city.", "Folded answer prompt lost its stable head or retained user turn.")
        let reopen = try ConversationStore(file: folded.conversationFile)
        let saved = try await reopen.conversation(folded.chat.current!.id)
        try require(saved.fold == folded.chat.current!.fold && saved.messages == folded.chat.current!.messages, "Fold or full transcript was not durable.")
        passed.append("automatic-segmented-complete-summary-retains-full-transcript-stable-head-and-reopen")
        var next = folded.chat.current!
        for _ in 0..<2 {
            next.messages.append(StoredMessage(role: .user, content: String(repeating: "New context. ", count: 230)))
            next.messages.append(StoredMessage(role: .assistant, content: String(repeating: "New answer. ", count: 90)))
        }
        try await folded.chat.store.save(next); await folded.chat.open(next)
        let capturesBefore = folded.runtime.captures.count
        folded.chat.draft = "Continue again."; await folded.chat.send()
        try await wait("Refold did not finish") { !folded.chat.busy }
        try require(folded.chat.error == nil && folded.chat.current!.fold!.messageCount > 4, "Growing history did not refold.")
        try require(folded.runtime.captures.dropFirst(capturesBefore).contains { $0.messages.last?["content"]?.contains("Previous summary (retain its relevant facts):") == true }, "Refold dropped previously summarized facts.")
        passed.append("growing-history-refold-carries-prior-summary-and-new-transcript")

        for mode in [FixtureRuntime.Mode.foldingCapped, .foldingUnknown, .foldingCancelled, .foldingEmpty] {
            let refused = try Fixture(mode: mode, write: false)
            defer { refused.cleanup() }
            try await seedLongHistory(refused)
            let history = refused.chat.current!.messages
            refused.chat.draft = "Continue"; await refused.chat.send()
            try await wait("Invalid summary did not finish") { !refused.chat.busy }
            try require(refused.chat.current?.fold == nil && Array(refused.chat.current!.messages.prefix(history.count)) == history && refused.chat.error != nil,
                        "An unfinished or empty summary replaced history: \(mode)")
            try require(refused.runtime.captures.count == 1 && refused.chat.current?.messages.last?.role == .user, "A refused summary generated an answer or stored partial summary text.")
        }
        passed.append("capped-unknown-cancelled-and-empty-summaries-preserve-history-and-refuse-answer")

        let stopped = try Fixture(mode: .folding, write: false); defer { stopped.cleanup() }
        try await seedLongHistory(stopped)
        stopped.runtime.beforeFirstReply = { stopped.chat.cancel() }
        stopped.chat.draft = "Continue"; await stopped.chat.send()
        try await wait("Stopped summary did not release chat") { !stopped.chat.busy }
        try require(stopped.chat.current?.fold == nil && stopped.runtime.captures.count == 1 && stopped.chat.error == nil && !stopped.chat.isCompacting, "Stop committed a fold or continued inference.")
        passed.append("stop-during-summary-clears-compacting-without-committing-or-answering")

        let unwritable = try Fixture(mode: .folding, write: false); defer { unwritable.cleanup() }
        try await seedLongHistory(unwritable)
        unwritable.runtime.beforeFirstReply = {
            try FileManager.default.removeItem(at: unwritable.conversationFile)
            try FileManager.default.createDirectory(at: unwritable.conversationFile, withIntermediateDirectories: false)
        }
        unwritable.chat.draft = "Continue"; await unwritable.chat.send()
        try await wait("Failed fold checkpoint did not finish") { !unwritable.chat.busy }
        try require(unwritable.chat.current?.fold == nil && unwritable.chat.error != nil && unwritable.chat.current!.messages.count == 5, "Failed summary persistence advanced displayed context or started an answer.")
        let retained = try await unwritable.chat.store.conversation(unwritable.chat.current!.id)
        try require(retained.fold == nil && retained.messages.count == 5, "Failed fold persistence advanced store RAM.")
        passed.append("failed-fold-checkpoint-preserves-controller-and-store-history")

        let masked = try Fixture(mode: .folding, write: false); defer { masked.cleanup() }
        try await masked.prepareFiles()
        await masked.chat.load(masked.chat.downloads.models[0]); await masked.chat.newConversation()
        var value = masked.chat.current!
        var call = StoredMessage(role: .assistant, content: "")
        call.promptContent = "<tool_call>read_file</tool_call>"
        call.toolCalls = [AgentToolCall(id: "read", name: "read_file", argumentsJSON: "{}")]
        var observation = StoredMessage(role: .tool, content: String(repeating: "Untrusted evidence. ", count: 330))
        observation.toolName = "read_file"; observation.toolCallID = "read"; observation.toolUntrustedText = true
        value.messages = [StoredMessage(role: .user, content: "Read the document"), call, observation, StoredMessage(role: .assistant, content: "I read it.")]
        try await masked.chat.store.save(value); await masked.chat.open(value)
        masked.chat.draft = "Continue."; await masked.chat.send()
        try await wait("Masking did not finish") { !masked.chat.busy }
        try require(masked.chat.error == nil && masked.chat.current?.fold == nil && masked.chat.current?.observationMask?.messageCount == 4,
                    "Cheaper observation masking did not avoid summarization.")
        try require(masked.runtime.captures.count == 1 && masked.runtime.captures[0].messages.contains { $0["tool_call_id"] == "read" && $0["content"]?.contains("omitted") == true }, "Masking lost paired tool ID or called the summarizer.")
        try require(masked.chat.current!.messages[2] == observation, "Masking removed durable read evidence or its untrusted-text marker.")
        let needsApproval = await masked.files.requiresApproval(AgentToolCall(id: "write", name: "write_file", argumentsJSON: "{\"path\":\"new.txt\",\"content\":\"text\"}"))
        try require(needsApproval, "Masking removed the untrusted-read approval requirement.")
        passed.append("observation-masking-avoids-summary-keeps-call-pair-full-evidence-and-write-approval")

        let tooLarge = try Fixture(mode: .folding, write: false); defer { tooLarge.cleanup() }
        await tooLarge.chat.load(tooLarge.chat.downloads.models[0])
        tooLarge.chat.draft = String(repeating: "Oversized current turn. ", count: 500); await tooLarge.chat.send()
        try await wait("Oversized turn did not finish") { !tooLarge.chat.busy }
        try require(tooLarge.runtime.captures.isEmpty && tooLarge.chat.error != nil && tooLarge.chat.current?.fold == nil, "An oversized current turn was silently truncated or generated past its context.")
        passed.append("oversized-current-turn-refused-without-dropping-history-or-starting-inference")
    }
    @MainActor static func main() async throws {
        var passed: [String] = []
        try await conversationMetadataChecks(&passed)
        try await attachmentChecks(&passed)
        try await mediaFoldingChecks(&passed)

        let approved = try Fixture(); defer { approved.cleanup() }
        try await approved.loadAndSend()
        try await wait("Approval was not presented") { approved.chat.pendingToolApproval != nil }
        let before = await approved.memory.store.list(); try require(before.isEmpty, "A write happened before approval.")
        let request = approved.chat.pendingToolApproval!
        try require(request.displayedCall.argumentsJSON == "{\"fact\":\"Prefers tea 1\"}", "Displayed arguments changed.")
        approved.chat.answerToolApproval(approved: true, ticketID: request.ticketID)
        try await wait("Approved turn did not finish") { !approved.chat.busy }
        let facts = await approved.memory.store.list(); try require(facts.map(\.text) == ["Prefers tea 1"], "Approved write was lost or duplicated.")
        try require(approved.runtime.captures.count == 2, "The answer pass did not follow the tool result.")
        let second = approved.runtime.captures[1].messages
        try require(second.contains { $0["role"] == "assistant" && ($0["content"] ?? "").contains("<tool_call>") }, "Raw tool request was lost from replay.")
        try require(second.contains { $0["role"] == "tool" && $0["tool_call_id"] == "call-1" && $0["content"] == "Remembered." }, "Matching tool result was not replayed.")
        let reopened = try ConversationStore(file: approved.conversationFile)
        let saved = try await reopened.conversation(approved.chat.current!.id)
        try require(saved.messages.contains { $0.toolCallID == "call-1" && $0.role == .tool }, "Tool result did not survive reopen.")
        passed.append("approve-exact-write-once-follow-with-answer-and-reopen-tool-history")

        let declined = try Fixture(); defer { declined.cleanup() }
        try await declined.loadAndSend(); try await wait("Decline prompt absent") { declined.chat.pendingToolApproval != nil }
        let oldTicket = declined.chat.pendingToolApproval!.ticketID
        declined.chat.answerToolApproval(approved: false, ticketID: oldTicket)
        try await wait("Declined turn did not finish") { !declined.chat.busy }
        let empty = await declined.memory.store.list(); try require(empty.isEmpty, "Declined write changed facts.")
        declined.chat.draft = "Try another explicit request."; await declined.chat.send()
        try await wait("Second approval absent") { declined.chat.pendingToolApproval != nil }
        let newTicket = declined.chat.pendingToolApproval!.ticketID
        declined.chat.answerToolApproval(approved: true, ticketID: oldTicket)
        try require(declined.chat.pendingToolApproval?.ticketID == newTicket, "A stale UI ticket approved a different call.")
        declined.chat.answerToolApproval(approved: true, ticketID: newTicket)
        try await wait("Fresh approved turn did not finish") { !declined.chat.busy }
        let fresh = await declined.memory.store.list(); try require(fresh.map(\.text) == ["Prefers tea 3"], "New exact approval did not write once.")
        passed.append("decline-without-write-and-reject-stale-approval-ticket")

        let cancelled = try Fixture(); defer { cancelled.cleanup() }
        try await cancelled.loadAndSend(); try await wait("Cancel prompt absent") { cancelled.chat.pendingToolApproval != nil }
        cancelled.chat.cancel(); try await wait("Stop left an approval suspended") { !cancelled.chat.busy }
        let cancelledFacts = await cancelled.memory.store.list(); try require(cancelledFacts.isEmpty, "Stop performed the pending write.")
        try require(cancelled.chat.pendingToolApproval == nil, "Stop retained an active approval.")
        try require(cancelled.runtime.captures.count == 1, "Stop started another model pass.")
        cancelled.chat.draft = "Answer another message."; await cancelled.chat.send()
        try await wait("A new message did not recover after Stop") { !cancelled.chat.busy }
        try require(cancelled.runtime.captures.count == 2 && cancelled.chat.error == nil, "Cancellation leaked into the next turn.")
        passed.append("stop-resolves-approval-without-write-or-next-pass-and-new-turn-recovers")

        let disabled = try Fixture(write: false); defer { disabled.cleanup() }
        try await disabled.loadAndSend(); try await wait("Disabled-tool turn did not finish") { !disabled.chat.busy }
        let disabledFacts = await disabled.memory.store.list(); try require(disabledFacts.isEmpty, "An unoffered tool changed facts.")
        try require(disabled.chat.pendingToolApproval == nil && disabled.runtime.captures[0].tools.isEmpty, "Disabled tools were offered or requested approval.")
        passed.append("disabled-and-unoffered-tools-cannot-write")

        let reader = try Fixture(mode: .read, read: true, write: false); defer { reader.cleanup() }
        try await reader.memory.store.remember("Prefers green tea")
        try await reader.loadAndSend(); try await wait("Read did not finish") { !reader.chat.busy }
        try require(reader.chat.pendingToolApproval == nil, "Read incorrectly required a write approval.")
        try require(reader.runtime.captures[0].tools == ["read_memory"], "Read/write gates were not independent.")
        try require(!reader.runtime.captures[0].messages.contains { ($0["content"] ?? "").contains("green tea") }, "Saved facts were injected before a read request.")
        try require(reader.runtime.captures[1].messages.contains { $0["role"] == "tool" && ($0["content"] ?? "").contains("green tea") }, "Requested private read did not reach the answer pass.")
        await reader.chat.newConversation(); reader.chat.draft = "What do I prefer?"; await reader.chat.send()
        try await wait("Cross-chat read did not finish") { !reader.chat.busy }
        try require(reader.runtime.captures[3].messages.contains { $0["role"] == "tool" && ($0["content"] ?? "").contains("green tea") }, "Memory was not retrievable in the next chat.")
        passed.append("read-on-demand-with-separate-switch-and-cross-chat-retrieval")

        let incompatible = try Fixture(supportsTools: false); defer { incompatible.cleanup() }
        try await incompatible.loadAndSend(); try await wait("Incompatible adapter did not stop") { !incompatible.chat.busy }
        try require(incompatible.chat.error != nil && incompatible.runtime.captures.isEmpty, "Incompatible adapter silently ignored enabled tools.")
        incompatible.memory.writeEnabled = false
        await incompatible.chat.load(incompatible.chat.downloads.models[0])
        try require(incompatible.chat.error == nil, "A successful reload kept a stale adapter error.")
        incompatible.chat.draft = "Answer without enabled tools."; await incompatible.chat.send()
        try await wait("Plain chat did not recover after disabling tools") { !incompatible.chat.busy }
        try require(incompatible.chat.error == nil && incompatible.runtime.captures.count == 2, "Disabled tools did not allow plain chat to recover.")
        passed.append("incompatible-adapter-fails-before-generation-and-reloads-after-tools-disabled")

        let repeated = try Fixture(mode: .repeatWrites); defer { repeated.cleanup() }
        try await repeated.loadAndSend(); try await wait("First bounded approval absent") { repeated.chat.pendingToolApproval != nil }
        repeated.chat.answerToolApproval(approved: true)
        try await wait("Second bounded approval absent") { repeated.chat.pendingToolApproval != nil }
        repeated.chat.answerToolApproval(approved: true)
        try await wait("Tool limit did not stop the model") { !repeated.chat.busy }
        let limitedFacts = await repeated.memory.store.list()
        try require(limitedFacts.count == 2 && repeated.runtime.captures.count == 3, "Tool-round ceiling permitted another write.")
        try require(repeated.chat.error != nil, "Model ignoring the limit was reported as successful.")
        passed.append("two-tool-round-limit-refuses-third-write")

        let truncated = try Fixture(mode: .emptyStream); defer { truncated.cleanup() }
        try await truncated.loadAndSend(); try await wait("Incomplete stream did not finish") { !truncated.chat.busy }
        try require(truncated.chat.error != nil && truncated.chat.current?.messages.last?.status == .failed,
                    "An incomplete stream was treated as a complete answer.")
        try require(truncated.chat.current?.messages.last?.content == "partial text", "Interrupted text was lost.")
        passed.append("stream-without-final-reply-preserves-partial-and-fails-explicitly")

        let multiple = try Fixture(mode: .multipleCalls); defer { multiple.cleanup() }
        try await multiple.loadAndSend(); try await wait("First multiple-call approval absent") { multiple.chat.pendingToolApproval != nil }
        let firstID = multiple.chat.pendingToolApproval!.displayedCall.id
        multiple.chat.answerToolApproval(approved: true)
        try await wait("Second multiple-call approval absent") { multiple.chat.pendingToolApproval != nil }
        let secondID = multiple.chat.pendingToolApproval!.displayedCall.id
        try require(!firstID.isEmpty && !secondID.isEmpty && firstID != secondID, "Missing model IDs were not normalized uniquely.")
        multiple.chat.answerToolApproval(approved: false)
        try await wait("Multiple-call turn did not finish") { !multiple.chat.busy }
        let multipleFacts = await multiple.memory.store.list()
        try require(multipleFacts.map(\.text) == ["Prefers tea 1"], "The declined second call wrote data.")
        let history = multiple.runtime.captures[1].messages.filter { $0["role"] == "tool" }
        try require(history.map { $0["tool_call_id"]! } == [firstID, secondID], "Results did not keep their normalized call IDs.")
        passed.append("multiple-calls-get-distinct-ids-and-independent-approval-results")
        let duplicate = try Fixture(mode: .repeatSame); defer { duplicate.cleanup() }
        try await duplicate.loadAndSend(); try await wait("Duplicate initial approval absent") { duplicate.chat.pendingToolApproval != nil }
        duplicate.chat.answerToolApproval(approved: true)
        try await wait("Duplicate call asked for approval again or ignored the limit") { !duplicate.chat.busy }
        let duplicateFacts = await duplicate.memory.store.list()
        try require(duplicateFacts.map(\.text) == ["Prefers tea"] && duplicate.runtime.captures.count == 3,
                    "Settled identical calls repeated their write.")
        passed.append("settled-identical-call-reuses-result-without-another-write-or-approval")
        let unwritable = try Fixture(); defer { unwritable.cleanup() }
        try await unwritable.loadAndSend(); try await wait("Storage-failure approval absent") { unwritable.chat.pendingToolApproval != nil }
        try FileManager.default.removeItem(at: unwritable.conversationFile)
        try FileManager.default.createDirectory(at: unwritable.conversationFile, withIntermediateDirectories: false)
        unwritable.chat.answerToolApproval(approved: true)
        try await wait("Intent checkpoint failure did not stop execution") { !unwritable.chat.busy }
        let unwritten = await unwritable.memory.store.list()
        try require(unwritten.isEmpty, "The tool changed memory despite a failed pending checkpoint.")
        try require(unwritable.chat.error != nil && unwritable.chat.current?.messages.last?.status == .failed,
                    "Storage failure left a fake streaming state or hid its error.")
        try require(unwritable.runtime.captures.count == 1, "Storage failure continued to another model pass.")
        passed.append("failed-pending-checkpoint-prevents-approved-effect-and-ends-stream-state")
        let queued = try Fixture(); defer { queued.cleanup() }
        await queued.chat.load(queued.chat.downloads.models[0])
        queued.chat.draft = "This turn will be stopped before generation."; await queued.chat.send()
        queued.chat.cancel()
        try await wait("Queued Stop did not finish") { !queued.chat.busy }
        try require(queued.runtime.captures.isEmpty && queued.chat.pendingToolApproval == nil,
                    "A stopped queued turn started a model pass or tool approval.")
        passed.append("queued-stop-does-not-enter-runtime-or-request-tools")
        let bookmarks = try Fixture(write: false); defer { bookmarks.cleanup() }
        try await bookmarks.prepareFiles()
        bookmarks.files.mode = .ask; bookmarks.files.mode = .yolo
        let restoredFiles = WorkspaceController(bookmarkFile: bookmarks.root.appendingPathComponent("workspace.bookmark"), defaults: bookmarks.defaults)
        await restoredFiles.restore()
        try require(restoredFiles.error == nil && restoredFiles.folderName == "Shared" && restoredFiles.definitions.count == 4,
                    "Folder bookmark or switches were not restored.")
        try require(restoredFiles.mode == .ask, "Yolo survived a controller restart.")
        let restoredID = restoredFiles.grantID
        await restoredFiles.revoke()
        try require(restoredID != nil && restoredFiles.grantID == nil && restoredFiles.definitions.isEmpty &&
                    !FileManager.default.fileExists(atPath: bookmarks.root.appendingPathComponent("workspace.bookmark").path),
                    "Revocation left a live grant or a restoring bookmark.")
        passed.append("saved-folder-bookmark-switches-revoke-and-ephemeral-yolo")
        let chain = try Fixture(mode: .fileRounds, write: false); defer { chain.cleanup() }
        try await chain.prepareFiles(); try await chain.loadAndSend()
        try await wait("Chained file write approval absent") { chain.chat.pendingToolApproval?.displayedCall.name == "write_file" }
        try require(!FileManager.default.fileExists(atPath: chain.sharedFolder.appendingPathComponent("scratch.txt").path), "Untrusted file text authorized an additive write.")
        try require(chain.chat.pendingToolApprovalContext == "Shared folder: Shared", "Approval omitted its destination folder.")
        chain.chat.answerToolApproval(approved: true)
        try await wait("Chained file delete approval absent") { chain.chat.pendingToolApproval?.displayedCall.name == "delete_file" }
        try require(try String(contentsOf: chain.sharedFolder.appendingPathComponent("scratch.txt"), encoding: .utf8) == "Cedar", "Approved file write did not persist.")
        chain.chat.answerToolApproval(approved: true)
        try await wait("Chained file task did not finish") { !chain.chat.busy }
        try require(chain.chat.error == nil && chain.runtime.captures.count == 5, "Four-round file work did not reach its answer pass.")
        try require(!FileManager.default.fileExists(atPath: chain.sharedFolder.appendingPathComponent("scratch.txt").path), "Approved delete did not run.")
        let reopenedFilesChat = try ConversationStore(file: chain.conversationFile)
        let savedFileChat = try await reopenedFilesChat.conversation(chain.chat.current!.id)
        try require(savedFileChat.messages.filter { $0.role == .tool }.count == 4 &&
                    savedFileChat.messages.filter { $0.role == .tool }.allSatisfy { $0.toolCallID != nil && $0.status == .complete },
                    "File results were not durably paired to their calls.")
        passed.append("four-round-find-read-write-delete-answer-with-untrusted-write-approval-and-history")
        let additive = try Fixture(mode: .fileWrite, write: false); defer { additive.cleanup() }
        try await additive.prepareFiles(); try await additive.loadAndSend()
        try await wait("Additive Auto file write did not finish") { !additive.chat.busy }
        try require(additive.chat.pendingToolApproval == nil && additive.chat.error == nil &&
                    (try String(contentsOf: additive.sharedFolder.appendingPathComponent("new.txt"), encoding: .utf8)) == "Cedar", "Clean additive Auto write failed.")
        passed.append("clean-additive-file-write-runs-in-auto-and-records-result")
        let declinedFile = try Fixture(mode: .fileReplace, write: false); defer { declinedFile.cleanup() }
        try await declinedFile.prepareFiles(); try await declinedFile.loadAndSend()
        try await wait("Foreign overwrite approval absent") { declinedFile.chat.pendingToolApproval != nil }
        declinedFile.chat.answerToolApproval(approved: false)
        try await wait("Declined file overwrite did not finish") { !declinedFile.chat.busy }
        try require(try String(contentsOf: declinedFile.sharedFolder.appendingPathComponent("user.txt"), encoding: .utf8) == "Original Cedar", "Declined overwrite changed the file.")
        passed.append("foreign-file-overwrite-decline-preserves-original")
        let stoppedFile = try Fixture(mode: .fileReplace, write: false); defer { stoppedFile.cleanup() }
        try await stoppedFile.prepareFiles(); try await stoppedFile.loadAndSend()
        try await wait("File Stop approval absent") { stoppedFile.chat.pendingToolApproval != nil }
        stoppedFile.chat.cancel()
        try await wait("Stop at file approval did not finish") { !stoppedFile.chat.busy }
        try require(try String(contentsOf: stoppedFile.sharedFolder.appendingPathComponent("user.txt"), encoding: .utf8) == "Original Cedar", "Stop changed the file.")
        try require(stoppedFile.chat.pendingToolApproval == nil, "Stop retained file approval.")
        passed.append("stop-at-file-approval-has-no-effect")
        let movedGrant = try Fixture(mode: .fileReplace, write: false); defer { movedGrant.cleanup() }
        try await movedGrant.prepareFiles(); try await movedGrant.loadAndSend()
        try await wait("Old-grant approval absent") { movedGrant.chat.pendingToolApproval != nil }
        let secondFolder = movedGrant.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try Data("Other original".utf8).write(to: secondFolder.appendingPathComponent("user.txt"))
        await movedGrant.files.choose(secondFolder)
        movedGrant.chat.answerToolApproval(approved: true)
        try await wait("Changed-grant turn did not finish") { !movedGrant.chat.busy }
        try require(try String(contentsOf: secondFolder.appendingPathComponent("user.txt"), encoding: .utf8) == "Other original", "An old approval authorized a different folder.")
        passed.append("approval-cannot-cross-a-replaced-folder-grant")
        let disabledFile = try Fixture(mode: .fileReplace, write: false); defer { disabledFile.cleanup() }
        try await disabledFile.prepareFiles(); try await disabledFile.loadAndSend()
        try await wait("Disabled-file approval absent") { disabledFile.chat.pendingToolApproval != nil }
        disabledFile.files.enabled.remove("write_file"); disabledFile.chat.answerToolApproval(approved: true)
        try await wait("Disabled file turn did not finish") { !disabledFile.chat.busy }
        try require(try String(contentsOf: disabledFile.sharedFolder.appendingPathComponent("user.txt"), encoding: .utf8) == "Original Cedar", "A switched-off tool wrote after approval.")
        passed.append("file-switch-rechecked-after-pending-approval")
        let cappedFiles = try Fixture(mode: .manyFiles, write: false); defer { cappedFiles.cleanup() }
        try await cappedFiles.prepareFiles(); try await cappedFiles.loadAndSend()
        try await wait("File call caps did not finish") { !cappedFiles.chat.busy }
        let fileNames = try FileManager.default.contentsOfDirectory(atPath: cappedFiles.sharedFolder.path).filter { $0.hasPrefix("file-") }
        try require(fileNames.count == 6 && !fileNames.contains("file-1-3.txt") && !fileNames.contains("file-3-0.txt"),
                    "The three-per-round or six-per-turn cap allowed an extra file effect.")
        passed.append("three-call-round-and-six-call-turn-caps-limit-durable-effects")
        let badFileCheckpoint = try Fixture(mode: .fileWrite, write: false); defer { badFileCheckpoint.cleanup() }
        try await badFileCheckpoint.prepareFiles(mode: .ask); try await badFileCheckpoint.loadAndSend()
        try await wait("File checkpoint approval absent") { badFileCheckpoint.chat.pendingToolApproval != nil }
        try FileManager.default.removeItem(at: badFileCheckpoint.conversationFile)
        try FileManager.default.createDirectory(at: badFileCheckpoint.conversationFile, withIntermediateDirectories: false)
        badFileCheckpoint.chat.answerToolApproval(approved: true)
        try await wait("Failed file checkpoint did not stop") { !badFileCheckpoint.chat.busy }
        try require(!FileManager.default.fileExists(atPath: badFileCheckpoint.sharedFolder.appendingPathComponent("new.txt").path) && badFileCheckpoint.chat.error != nil,
                    "A file effect happened after its pending checkpoint failed.")
        passed.append("file-effect-prevented-by-failed-intent-checkpoint")
        let planningFile = try Fixture(mode: .fileWrite, write: false); defer { planningFile.cleanup() }
        try await planningFile.prepareFiles(mode: .plan); try await planningFile.loadAndSend()
        try await wait("Plan file turn did not finish") { !planningFile.chat.busy }
        try require(!FileManager.default.fileExists(atPath: planningFile.sharedFolder.appendingPathComponent("new.txt").path) && planningFile.chat.pendingToolApproval == nil,
                    "Plan mode performed a file action.")
        try require(planningFile.runtime.captures[0].messages.last?["content"]?.contains("Tool mode: plan") == true,
                    "Plan instruction was missing from the durable prompt tail.")
        let askRead = try Fixture(mode: .read, read: true, write: false); defer { askRead.cleanup() }
        askRead.files.mode = .ask; try await askRead.loadAndSend()
        try await wait("Ask-mode memory read did not ask") { askRead.chat.pendingToolApproval?.displayedCall.name == "read_memory" }
        askRead.chat.answerToolApproval(approved: true)
        try await wait("Approved Ask-mode memory read did not finish") { !askRead.chat.busy }
        passed.append("plan-refuses-file-actions-and-ask-mode-prompts-for-memory-reads")
        let skippedRead = try Fixture(mode: .readThenWrite, write: false); defer { skippedRead.cleanup() }
        try await skippedRead.prepareFiles(mode: .plan); try await skippedRead.loadAndSend()
        try await wait("Skipped Plan read did not finish") { !skippedRead.chat.busy }
        try require(skippedRead.chat.current?.messages.first(where: { $0.role == .tool })?.toolUntrustedText == false,
                    "A refused Plan read was marked as consumed file data.")
        skippedRead.files.mode = .auto; skippedRead.chat.draft = "Now save the note."; await skippedRead.chat.send()
        try await wait("Clean post-Plan write did not finish automatically") { !skippedRead.chat.busy || skippedRead.chat.pendingToolApproval != nil }
        try require(skippedRead.chat.pendingToolApproval == nil && !skippedRead.chat.busy && FileManager.default.fileExists(atPath: skippedRead.sharedFolder.appendingPathComponent("new.txt").path),
                    "A skipped read unnecessarily gated the next turn's additive write.")
        let previousRead = try Fixture(mode: .readThenWrite, write: false); defer { previousRead.cleanup() }
        try await previousRead.prepareFiles(); try await previousRead.loadAndSend()
        try await wait("Actual file read did not finish") { !previousRead.chat.busy }
        try require(previousRead.chat.current?.messages.first(where: { $0.role == .tool })?.toolUntrustedText == true,
                    "Actual file data lost its durable untrusted marker.")
        previousRead.chat.draft = "Now save the note."; await previousRead.chat.send()
        try await wait("Cross-turn untrusted write approval absent") { previousRead.chat.pendingToolApproval != nil }
        try require(!FileManager.default.fileExists(atPath: previousRead.sharedFolder.appendingPathComponent("new.txt").path),
                    "A previous turn's file data authorized a durable write.")
        previousRead.chat.answerToolApproval(approved: true)
        try await wait("Cross-turn approved write did not finish") { !previousRead.chat.busy }
        passed.append("durable-file-taint-survives-turns-without-tainting-skipped-reads")
        let settledFile = try Fixture(mode: .fileSettled, write: false); defer { settledFile.cleanup() }
        try await settledFile.prepareFiles(); try await settledFile.loadAndSend()
        try await wait("Settled write/delete/repeat turn did not finish") { !settledFile.chat.busy }
        try require(!FileManager.default.fileExists(atPath: settledFile.sharedFolder.appendingPathComponent("future.txt").path),
                    "A successful write was repeated after a sibling delete. The file was recreated.")
        passed.append("successful-call-stays-settled-after-another-durable-change")
        let staleRefusal = try Fixture(mode: .fileRefusal, write: false); defer { staleRefusal.cleanup() }
        try await staleRefusal.prepareFiles(); try await staleRefusal.loadAndSend()
        try await wait("Post-refusal write approval absent") { staleRefusal.chat.pendingToolApproval != nil }
        staleRefusal.chat.answerToolApproval(approved: true)
        try await wait("Refusal/write/retry turn did not finish") { !staleRefusal.chat.busy }
        let readResults = staleRefusal.chat.current!.messages.filter { $0.toolName == "read_file" }
        try require(readResults.count == 2 && readResults[0].status == .failed && readResults[1].status == .complete && readResults[1].content == "Cedar",
                    "A missing-file refusal stayed settled after the file was created.")
        passed.append("durable-change-invalidates-a-missing-file-refusal")
        let rememberedDecline = try Fixture(mode: .declinedThenWrite, write: false); defer { rememberedDecline.cleanup() }
        try await rememberedDecline.prepareFiles(mode: .ask); try await rememberedDecline.loadAndSend()
        try await wait("First exact-call decline absent") { rememberedDecline.chat.pendingToolApproval != nil }
        rememberedDecline.chat.answerToolApproval(approved: false)
        try await wait("Sibling allowed write approval absent") { rememberedDecline.chat.pendingToolApproval != nil }
        try require(rememberedDecline.chat.pendingToolApproval!.displayedCall.argumentsJSON.contains("allowed.txt"), "Unexpected sibling approval.")
        rememberedDecline.chat.answerToolApproval(approved: true)
        try await wait("Remembered decline did not finish") { !rememberedDecline.chat.busy || rememberedDecline.chat.pendingToolApproval != nil }
        try require(!rememberedDecline.chat.busy && rememberedDecline.chat.pendingToolApproval == nil &&
                    !FileManager.default.fileExists(atPath: rememberedDecline.sharedFolder.appendingPathComponent("declined.txt").path),
                    "A sibling write cleared the user's exact-call decline.")
        passed.append("user-decline-stays-settled-after-another-durable-change")
        try await planningChecks(&passed)
        try await goalChecks(&passed)
        try await researchChecks(&passed)
        try await foldingChecks(&passed)
        try await memoryEditingChecks(&passed)
        try await preparationChecks(&passed)
        try await modelSettingsChecks(&passed)
        try await usageChecks(&passed)
        try await watchChecks(&passed)
        try await webChecks(&passed)
        try await searchChecks(&passed)
        try await mediaChecks(&passed)
        try await proxyChecks(&passed)
        try await scriptChecks(&passed)
        try await canvasChecks(&passed)
        let proof: [String: Any] = ["status": "canonical-controller-mock-runtime-integration-verified", "passedChecks": passed,
            "limitations": ["Uses canonical ChatController, WatchController, MemoryController and WorkspaceController sources with a scripted runtime, local folder and model-library fixture.",
                            "Does not prove native tool parsing, iPhone inference, UI rendering, touch navigation or background behavior.",
                            "Latency and token fields are fixture values, not performance measurements."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
