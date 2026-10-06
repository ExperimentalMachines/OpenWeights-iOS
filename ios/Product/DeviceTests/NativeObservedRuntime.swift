import Foundation
import OpenWeightsCore
@testable import OpenWeights

/// Test-only observations of the real adapter. Prompts and settings pass through unchanged.
final class NativeObservedRuntime: ChatRuntime, @unchecked Sendable {
    private let real: any ChatRuntime
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    private var preparations: [[String: Any]] = []
    private var omittedPreparations = 0
    private var omitted = 0
    private let beforeReply: (@Sendable () async -> Void)?
    private let repeatMediaCount: Bool
    private var lastMediaRequest: (RuntimePrompt, ModelSettings)?
    init(_ real: any ChatRuntime, beforeReply: (@Sendable () async -> Void)? = nil, repeatMediaCount: Bool = true) {
        self.real = real; self.beforeReply = beforeReply; self.repeatMediaCount = repeatMediaCount
    }
    func capturedMediaRequest() -> (RuntimePrompt, ModelSettings)? {
        lock.lock(); defer { lock.unlock() }; return lastMediaRequest
    }
    var mediaSupport: RuntimeMediaSupport { real.mediaSupport }
    var supportsTools: Bool { real.supportsTools }
    var supportsReasoningEffort: Bool { real.supportsReasoningEffort }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["streams": records, "preparations": preparations, "omittedPreparations": omittedPreparations,
            "omittedStreams": omitted, "maximumStreams": 64, "maximumPreparations": 64, "maximumFieldCharacters": 16000]
    }
    func load(model: LocalModel, directory: URL) async throws { try await real.load(model: model, directory: directory) }
    func cancel() { real.cancel() }
    func reset() async { await real.reset() }
    private func prepare(_ kind: String, messages: [[String:String]], settings: ModelSettings, tools: [AgentToolDefinition]) {
        lock.lock(); defer { lock.unlock() }
        guard preparations.count < 64 else { omittedPreparations += 1; return }
        preparations.append(["kind":kind, "systemHead":String((messages.first?["content"] ?? "").prefix(16000)),
            "inputTruncated":(messages.first?["content"]?.count ?? 0) > 16000,
            "reasoningEffort":settings.reasoningEffort?.wireValue ?? "", "offeredTools":tools.map(\.name)])
    }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws { try await warm(messages:messages,settings:settings,tools:[]) }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        prepare("warm",messages:messages,settings:settings,tools:tools)
        try await real.warm(messages: messages, settings: settings, tools: tools)
    }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        prepare("count",messages:messages,settings:settings,tools:tools)
        return try await real.promptSize(messages: messages, settings: settings, tools: tools)
    }
    func warm(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        prepare("warm-media",messages:prompt.messages,settings:settings,tools:tools)
        try await real.warm(prompt:prompt,settings:settings,tools:tools)
    }
    func promptSize(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        prepare("count-prompt",messages:prompt.messages,settings:settings,tools:tools)
        return try await real.promptSize(prompt:prompt,settings:settings,tools:tools)
    }
    private func recordCount(_ size: RuntimePromptSize, again: RuntimePromptSize, prompt: RuntimePrompt, index: Int?) {
        guard let index else { return }
        lock.lock(); defer { lock.unlock() }
        records[index]["countedPrompt"] = size.tokens
        records[index]["countedAgain"] = again.tokens
        records[index]["countIsExact"] = size.exact && again.exact
        records[index]["mediaCounts"] = prompt.mediaPaths.map(\.count)
    }
    func stream(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        guard prompt.hasMedia else { return stream(messages:prompt.messages,settings:settings,tools:tools) }
        let index = begin(prompt.messages,settings:settings,tools:tools)
        lock.lock(); lastMediaRequest = (prompt, settings)
        if let index { records[index]["mediaPaths"] = prompt.mediaPaths }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    // Repeat the pure counter immediately before generation. Native usage
                    // then independently measures the cells actually decoded and reused.
                    if self.repeatMediaCount {
                        let first = try await real.promptSize(prompt:prompt,settings:settings,tools:tools)
                        let second = try await real.promptSize(prompt:prompt,settings:settings,tools:tools)
                        self.recordCount(first,again:second,prompt:prompt,index:index)
                    }
                    for try await event in real.stream(prompt:prompt,settings:settings,tools:tools) {
                        if case .reply(let reply) = event { await self.beforeReply?(); self.record(reply,index:index) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { relay.cancel(); self.real.cancel() }
            }
        }
    }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> { stream(messages: messages, settings: settings, tools: []) }
    private func begin(_ messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard records.count < 64 else { omitted += 1; return nil }
        records.append(["messages": messages.prefix(64).map { message in message.mapValues { String($0.prefix(16000)) } },
            "inputTruncated": messages.count > 64 || messages.contains { $0.values.contains { $0.count > 16000 } },
            "offeredTools": tools.map(\.name), "contextTokens": settings.contextTokens, "outputTokens": settings.outputTokens,
            "temperature": settings.temperature, "topP": settings.topP, "repeatPenalty": settings.repeatPenalty, "thinking": settings.thinking,
            "reasoningEffort":settings.reasoningEffort?.wireValue ?? ""])
        return records.count - 1
    }
    private func record(_ reply: RuntimeReply, index: Int?) {
        guard let index else { return }
        lock.lock(); defer { lock.unlock() }
        records[index]["reply"] = ["content": String(reply.content.prefix(16000)), "reasoning": String(reply.reasoning.prefix(16000)),
            "promptContent": String((reply.promptContent ?? "").prefix(16000)), "stopReason": reply.stopReason.rawValue,
            "cancelled": reply.cancelled, "generatedTokens": reply.generatedTokens, "cachedTokens": reply.cachedTokens,
            "contextUsed": reply.contextUsed, "contextSize": reply.contextSize,
            "outputTruncated": reply.content.count > 16000 || reply.reasoning.count > 16000 || (reply.promptContent?.count ?? 0) > 16000,
            "toolCalls": reply.toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": String($0.arguments.prefix(16000))] }]
        if let usage = reply.usage {
            records[index]["usage"] = ["promptTokens":usage.promptTokens,"generatedTokens":usage.generatedTokens,
                "cachedTokens":usage.cachedTokens,"inferenceMilliseconds":usage.inferenceMilliseconds,
                "prefillMilliseconds":usage.prefillMilliseconds as Any? ?? NSNull(),
                "decodeMilliseconds":usage.decodeMilliseconds as Any? ?? NSNull(),"decodeTokens":usage.decodeTokens as Any? ?? NSNull(),
                "prefillIncludesCompute":usage.prefillIncludesCompute as Any? ?? NSNull()]
        }
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let index = begin(messages, settings: settings, tools: tools)
        let source = real.stream(messages: messages, settings: settings, tools: tools)
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    for try await event in source {
                        if case .reply(let reply) = event {
                            await self.beforeReply?()
                            self.record(reply, index: index)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { relay.cancel(); self.real.cancel() }
            }
        }
    }
}
