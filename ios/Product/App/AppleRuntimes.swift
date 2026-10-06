import Foundation
import OpenWeightsCore
import ExecuTorchLLM
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import OWInferenceProbe

struct ProductTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }; var eosToken: String? { base.eosToken }; var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
struct ProductTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer { ProductTokenizer(base: try await AutoTokenizer.from(modelFolder: directory)) }
}

private func productTemplateContext(_ settings: ModelSettings) -> [String: any Sendable] {
    var result: [String: any Sendable] = ["enable_thinking": settings.thinking]
    if let effort = settings.reasoningEffort, !effort.wireValue.isEmpty { result["reasoning_effort"] = effort.wireValue }
    return result
}

private func productToolValue(_ value: MLXLMCommon.JSONValue) -> any Sendable {
    switch value {
    case .null: return NSNull()
    case .bool(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .string(let value): return value
    case .array(let value): return value.map(productToolValue)
    case .object(let value): return value.mapValues(productToolValue)
    }
}
private func productToolDefinitions(_ tools: [AgentToolDefinition]) throws -> [[String: any Sendable]]? {
    guard !tools.isEmpty else { return nil }
    return try tools.map { tool in
        let parameters = try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(tool.parametersJSON.utf8))
        let function: [String: any Sendable] = ["name": tool.name, "description": tool.description, "parameters": parameters.mapValues(productToolValue)]
        return ["type": "function", "function": function]
    }
}
private func productMessages(_ messages: [[String: String]]) -> [[String: any Sendable]] {
    messages.map { $0.mapValues { $0 as any Sendable } }
}

final class ProductMLXRuntime: ChatRuntime, @unchecked Sendable {
    private var container: ModelContainer?
    private var cache: [KVCache] = []
    private var recordedTokens: [Int] = []
    private let cancellation = RuntimeCancellation()
    private var effortSupport = false
    private var toolSupport = false
    var supportsTools: Bool { toolSupport }
    var supportsReasoningEffort: Bool { effortSupport }
    func load(model: LocalModel, directory: URL) async throws {
        try model.settings.validate(for: .mlx)
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: ProductTokenizerLoader())
        toolSupport = await container?.perform { context in
            // Enable only the tagged-JSON contract that this adapter can parse,
            // and only when the artifact template preserves a tool result.
            let name = "openweights_tool_capability_probe", result = "OpenWeights result capability 48371"
            let tool = AgentToolDefinition(name: name, description: "Template capability probe", parametersJSON: "{\"type\":\"object\",\"properties\":{}}")
            let probe: [[String: String]] = [["role": "user", "content": "OpenWeights capability probe"],
                ["role": "assistant", "content": "<tool_call>\n{\"name\":\"" + name + "\",\"arguments\":{}}\n</tool_call>"],
                ["role": "tool", "content": result, "tool_call_id": name + "-0"]]
            do {
                let tokens = try context.tokenizer.applyChatTemplate(messages: productMessages(probe), tools: productToolDefinitions([tool]), additionalContext: productTemplateContext(model.settings))
                let text = context.tokenizer.decode(tokenIds: tokens)
                let plain = try context.tokenizer.applyChatTemplate(messages: productMessages([["role": "user", "content": "OpenWeights capability probe"]]), tools: nil, additionalContext: productTemplateContext(model.settings))
                let definitions = try context.tokenizer.applyChatTemplate(messages: productMessages([["role": "user", "content": "OpenWeights capability probe"]]), tools: productToolDefinitions([tool]), additionalContext: productTemplateContext(model.settings))
                let definitionText = context.tokenizer.decode(tokenIds: definitions)
                return definitions != plain && definitionText.contains(name) && definitionText.contains("<tool_call>") && definitionText.contains("arguments") && text.contains(result) && text.contains("<tool_response>")
            } catch { return false }
        } ?? false
        effortSupport = await container?.perform { context in
            let probe: [[String: any Sendable]] = [["role":"user", "content":"OpenWeights capability probe"]]
            do {
                let low = try context.tokenizer.applyChatTemplate(messages: probe, tools: nil, additionalContext: ["enable_thinking":true, "reasoning_effort":"low"])
                let high = try context.tokenizer.applyChatTemplate(messages: probe, tools: nil, additionalContext: ["enable_thinking":true, "reasoning_effort":"high"])
                return low != high
            } catch { return false }
        } ?? false
    }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        try settings.validate(for: .mlx)
        guard let container else { throw ModelError.unsupported("Load a model first.") }
        guard tools.isEmpty || toolSupport else { throw ModelError.unsupported("This MLX artifact template cannot exchange supported tool calls and results.") }
        return try await container.perform { context in
            let formatted = productMessages(messages)
            return RuntimePromptSize(tokens: try context.tokenizer.applyChatTemplate(messages: formatted, tools: productToolDefinitions(tools),
                additionalContext: productTemplateContext(settings)).count, exact: true)
        }
    }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> {
        stream(messages: messages, settings: settings, tools: [])
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        cancellation.reset()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in if case .cancelled = reason { self?.cancel() } }
            Task {
                do {
                    guard let container = self.container else { throw ModelError.unsupported("Load a model first.") }
                    try settings.validate(for: .mlx)
                    guard tools.isEmpty || self.toolSupport else { throw ModelError.unsupported("This MLX artifact template cannot exchange supported tool calls and results.") }
                    let result = try await container.perform { context in
                        let formatted = productMessages(messages)
                        let tokens = try context.tokenizer.applyChatTemplate(messages: formatted, tools: productToolDefinitions(tools),
                            additionalContext: productTemplateContext(settings))
                        guard tokens.count + settings.outputTokens <= settings.contextTokens else { throw ModelError.unsupported("The conversation exceeds the model's selected context. Start a new chat or reduce the output limit.") }
                        let parameters = GenerateParameters(maxTokens: settings.outputTokens, temperature: Float(settings.temperature),
                            topP: Float(settings.topP), topK: settings.topK ?? 0, minP: Float(settings.minP ?? 0),
                            repetitionPenalty: Float(settings.repeatPenalty), prefillStepSize: 512)
                        if self.cache.isEmpty { self.cache = context.model.newCache(parameters: parameters) }
                        let offset = self.cache.first?.offset ?? 0
                        var prefix = 0
                        while prefix < min(tokens.count - 1, min(offset, self.recordedTokens.count)), tokens[prefix] == self.recordedTokens[prefix] { prefix += 1 }
                        if offset > prefix && (!canTrimPromptCache(self.cache) || trimPromptCache(self.cache, numTokens: offset - prefix) != offset - prefix) {
                            self.cache = context.model.newCache(parameters: parameters); prefix = 0
                        }
                        let input = LMInput(tokens: MLXArray(Array(tokens.dropFirst(prefix))))
                        let iterator = try TokenIterator(input: input, model: context.model, cache: self.cache, parameters: parameters)
                        var generated: [Int] = []; var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                        var output = ""; var first: Double?
                        let began = ProcessInfo.processInfo.systemUptime
                        let info = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { token in
                            generated.append(token); detokenizer.append(token: token)
                            if let piece = detokenizer.next() { output += piece; if first == nil { first = (ProcessInfo.processInfo.systemUptime - began) * 1000 }; continuation.yield(.token(piece)) }
                            return self.cancellation.isCancelled ? .stop : .more
                        }
                        eval(self.cache.flatMap { $0.state }); self.recordedTokens = tokens + generated
                        let stop: RuntimeStopReason = info.stopReason == .stop && context.tokenizer.unknownTokenId == nil ? .endOfTurn :
                            info.stopReason == .length ? .maxTokens : info.stopReason == .cancelled ? .cancelled : .unknown
                        var content = output; var calls: [RuntimeToolCall] = []
                        if !tools.isEmpty, stop == .endOfTurn, !self.cancellation.isCancelled, output.contains("<tool_call>") {
                            guard let parsed = TaggedToolReply.parse(output, offered: Set(tools.map(\.name))) else {
                                throw ModelError.unsupported("The model wrote a tool call that could not be read. No action was performed.")
                            }
                            content = parsed.content
                            calls = parsed.calls.map { RuntimeToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) }
                        }
                        return RuntimeReply(content: content, promptContent: calls.isEmpty ? nil : output, generatedTokens: info.generationTokenCount, cachedTokens: prefix,
                            contextUsed: tokens.count + generated.count, contextSize: settings.contextTokens, firstTextMilliseconds: first ?? 0,
                            tokensPerSecond: info.tokensPerSecond, cancelled: self.cancellation.isCancelled, toolCalls: calls,
                            // MLX groups EOS and unknown-token termination into .stop.
                            // Without the final token ID, an UNK-capable tokenizer cannot
                            // prove that a summary actually reached EOS.
                            stopReason: stop,
                            usage: UsageMeasurements(promptTokens: tokens.count - prefix, generatedTokens: info.generationTokenCount,
                                cachedTokens: prefix, inferenceMilliseconds: (info.promptTime + info.generateTime) * 1000,
                                prefillMilliseconds: info.promptTime * 1000, decodeMilliseconds: info.generateTime * 1000,
                                decodeTokens: max(0, info.generationTokenCount - 1)))
                    }
                    continuation.yield(.reply(result)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    func cancel() { cancellation.cancel() }
    func reset() async {
        guard let container else { cache = []; recordedTokens = []; return }
        await container.perform { _ in self.cache = []; self.recordedTokens = [] }
    }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws {
        try await warm(messages: messages, settings: settings, tools: [])
    }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        guard tools.isEmpty || toolSupport else { throw ModelError.unsupported("This MLX artifact template cannot exchange supported tool calls and results.") }
        try settings.validate(for: .mlx)
        cancellation.reset()
        guard let container else { throw ModelError.unsupported("Load a model first.") }
        try await container.perform { context in
            let formatted = productMessages(messages)
            let full = try context.tokenizer.applyChatTemplate(messages: formatted, tools: productToolDefinitions(tools),
                additionalContext: productTemplateContext(settings))
            let probed = try context.tokenizer.applyChatTemplate(messages: formatted + [["role": "user", "content": "OpenWeights warm prefix probe"]],
                tools: productToolDefinitions(tools), additionalContext: productTemplateContext(settings))
            var shared = 0
            while shared < min(full.count, probed.count), full[shared] == probed[shared] { shared += 1 }
            guard shared > 0 else { return }
            let tokens = Array(full.prefix(shared))
            guard tokens.count < settings.contextTokens else { return }
            let parameters = GenerateParameters(maxTokens: settings.outputTokens, temperature: Float(settings.temperature),
                topP: Float(settings.topP), topK: settings.topK ?? 0, minP: Float(settings.minP ?? 0),
                repetitionPenalty: Float(settings.repeatPenalty), prefillStepSize: 512)
            if self.cache.isEmpty { self.cache = context.model.newCache(parameters: parameters) }
            guard !self.cache.isEmpty else { return }
            var prefix = 0
            let offset = self.cache.first?.offset ?? 0
            while prefix < min(tokens.count, min(offset, self.recordedTokens.count)), tokens[prefix] == self.recordedTokens[prefix] { prefix += 1 }
            if offset > prefix && (!canTrimPromptCache(self.cache) || trimPromptCache(self.cache, numTokens: offset - prefix) != offset - prefix) {
                self.cache = context.model.newCache(parameters: parameters); prefix = 0
            }
            do {
                while prefix < tokens.count {
                    if self.cancellation.isCancelled { throw CancellationError() }
                    let end = min(tokens.count, prefix + 512)
                    let input = LMInput.Text(tokens: MLXArray(Array(tokens[prefix..<end])))
                    let result = context.model(input[text: .newAxis], cache: self.cache, state: nil)
                    eval(result.logits, self.cache.flatMap { $0.state })
                    // TokenIterator does not accept an initial non-cache decoder state.
                    // Such a model must start cold rather than reuse incomplete state.
                    if result.state != nil { self.cache = []; self.recordedTokens = []; return }
                    prefix = end; self.recordedTokens = Array(tokens.prefix(prefix))
                }
                if self.cancellation.isCancelled { throw CancellationError() }
            } catch {
                self.cache = []; self.recordedTokens = []
                throw error
            }
        }
    }
}

protocol ProductCompiledSession: AnyObject {
    func load() throws
    func countPrompt(_ prompt: String) throws -> NSNumber
    func generatePrompt(_ prompt: String, outputLimit: Int, temperature: Double, contextLimit: Int, callback: @escaping (String) -> Void) throws -> [String: Any]
    func warmPrompt(_ prompt: String, futurePrompt: String, contextLimit: Int) throws -> NSNumber
    func beginOperation()
    func stop()
    func reset()
}
extension OWExecuTorchRunner: ProductCompiledSession {}
extension OWMLXSession: ProductCompiledSession {}

final class ProductExecuTorchRuntime: ChatRuntime, @unchecked Sendable {
    private let promptDate: String
    private let backend: ModelBackend
    init(backend: ModelBackend = .xnnpack, promptDate: String = CompiledLlama32Prompt.today()) { self.backend = backend; self.promptDate = promptDate }
    private let queue = DispatchQueue(label: "org.experimentalmachines.openweights.executorch", qos: .userInitiated)
    private let lock = NSLock()
    private var runner: (any ProductCompiledSession)?
    private var toolSupport = false
    private var family: CompiledModelFamily?
    private let cancellation = RuntimeCancellation()
    private func nativeRunner() -> (any ProductCompiledSession)? { lock.lock(); defer { lock.unlock() }; return runner }
    private func nativeFamily() -> CompiledModelFamily? { lock.lock(); defer { lock.unlock() }; return family }
    var supportsTools: Bool { lock.lock(); defer { lock.unlock() }; return toolSupport }
    func load(model: LocalModel, directory: URL) async throws {
        try model.settings.validate(for: backend)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard model.backend == self.backend, [.xnnpack, .executorchMLX].contains(self.backend) else { throw ModelError.unsupported("This compiled model's declared backend does not match the selected runtime.") }
                    guard model.settings.contextTokens == 2048 else { throw ModelError.unsupported("This compiled export requires a 2,048-token context.") }
                    guard let family = CompiledModelFamily(rawValue: model.family ?? "") else { throw ModelError.unsupported("This compiled template requires a supported Qwen3, Qwen2.5 Instruct, SmolLM2 Instruct or Llama 3.2 Instruct export.") }
                    let path = try ModelFile(path: model.entryFile).destination(in: directory)
                    let value: any ProductCompiledSession
                    if self.backend == .executorchMLX {
                        guard family == .qwen3 else { throw ModelError.unsupported("This ExecuTorch MLX adapter requires a declared Qwen3 export.") }
                        value = try OWMLXSession(modelPath:path.path,tokenizerPath:directory.appendingPathComponent("tokenizer.json").path,
                            endOfTurnTokens:family.endOfTurnTokens,endOfTextToken:family.endOfTextToken)
                    } else {
                        value = try OWExecuTorchRunner(modelPath: path.path, tokenizerPath: directory.appendingPathComponent("tokenizer.json").path,
                            endOfTurnTokens:family.endOfTurnTokens,endOfTextToken:family.endOfTextToken)
                    }
                    self.lock.lock(); self.runner = value; self.family = family; self.toolSupport = false; self.lock.unlock()
                    if self.cancellation.isCancelled { value.stop() }
                    do { try value.load() }
                    catch { self.lock.lock(); self.runner = nil; self.lock.unlock(); throw error }
                    self.lock.lock(); self.toolSupport = family.supportsTools; self.lock.unlock()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try settings.validate(for: self.backend)
                    guard let runner = self.nativeRunner(), let family = self.nativeFamily() else { throw ModelError.unsupported("Load a supported compiled model first.") }
                    guard tools.isEmpty || self.supportsTools else { throw ModelError.unsupported("This compiled template does not support enabled tools. Turn the tools off or select a tool-capable model.") }
                    let count = try runner.countPrompt(family.render(messages, tools: tools, thinking: settings.thinking,date:self.promptDate))
                    continuation.resume(returning: RuntimePromptSize(tokens: count.intValue, exact: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> {
        stream(messages: messages, settings: settings, tools: [])
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        cancellation.reset(); nativeRunner()?.beginOperation()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in if case .cancelled = reason { self?.cancel() } }
            queue.async {
                do {
                    try settings.validate(for: self.backend)
                    guard let runner = self.nativeRunner(), let family = self.nativeFamily() else { throw ModelError.unsupported("Load a model first.") }
                    guard tools.isEmpty || self.supportsTools else { throw ModelError.unsupported("This compiled model cannot exchange supported tool calls and results.") }
                    var first: Double?
                    let began = ProcessInfo.processInfo.systemUptime
                    let result = try runner.generatePrompt(family.render(messages, tools: tools, thinking: settings.thinking,date:self.promptDate), outputLimit: settings.outputTokens,
                        temperature: settings.temperature, contextLimit: 2048) { piece in
                            if first == nil { first = (ProcessInfo.processInfo.systemUptime - began) * 1000 }
                            continuation.yield(.token(piece))
                        }
                    let total = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    func integer(_ key: String) -> Int { (result[key] as? NSNumber)?.intValue ?? 0 }
                    let generated = integer("generatedTokens")
                    let raw = result["content"] as? String ?? ""
                    let stop = RuntimeStopReason(rawValue: integer("stopReason")) ?? .unknown
                    let cancelled = self.cancellation.isCancelled || (result["cancelled"] as? NSNumber)?.boolValue == true
                    var content = raw; var calls: [RuntimeToolCall] = []
                    if !tools.isEmpty, stop == .endOfTurn, !cancelled {
                        let offered = Set(tools.map(\.name))
                        let parsed = family == .llama32 ? CompiledLlama32ToolReply.parse(raw,offered:offered)
                            : raw.contains("<tool_call>") ? TaggedToolReply.parse(raw, offered: offered) : BareToolReply.parse(raw, offered: offered)
                        if parsed == nil && (raw.contains("<tool_call>") || (family == .llama32 && raw.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<|python_tag|>"))) {
                            throw ModelError.unsupported("The model wrote a tool call that could not be read. No action was performed.")
                        }
                        if let parsed {
                            content = parsed.content
                            calls = parsed.calls.map { RuntimeToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) }
                        }
                    }
                    // The rendered assistant head is part of the actual KV prefix.
                    // Preserve its no-thinking seed in history, while displaying only the answer.
                    continuation.yield(.reply(RuntimeReply(content: content,
                        promptContent: family.supportsThinking && !settings.thinking ? "<think>\n\n</think>\n\n" + raw : (calls.isEmpty ? nil : raw), generatedTokens: generated,
                        cachedTokens: integer("cachedTokens"), contextUsed: integer("contextUsed"), contextSize: 2048,
                        firstTextMilliseconds: first ?? 0,
                        tokensPerSecond: total > (first ?? 0) ? Double(max(0, generated - 1)) * 1000 / (total - (first ?? 0)) : 0,
                        cancelled: cancelled, toolCalls: calls, stopReason: stop,
                        usage: UsageMeasurements(promptTokens: max(0, integer("promptTokens") - integer("cachedTokens")),
                            generatedTokens: generated, cachedTokens: integer("cachedTokens"), inferenceMilliseconds: total))))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    func cancel() { cancellation.cancel(); nativeRunner()?.stop() }
    func reset() async { await withCheckedContinuation { continuation in queue.async { self.nativeRunner()?.reset(); continuation.resume() } } }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws {
        try await warm(messages: messages, settings: settings, tools: [])
    }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        cancellation.reset(); nativeRunner()?.beginOperation()
        try settings.validate(for: self.backend)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let runner = self.nativeRunner(), let family = self.nativeFamily() else { throw ModelError.unsupported("Load a model first.") }
                    guard tools.isEmpty || self.supportsTools else { throw ModelError.unsupported("This compiled model cannot exchange supported tool calls and results.") }
                    let future = messages + [["role": "user", "content": "OpenWeights warm prefix probe"]]
                    _ = try runner.warmPrompt(family.render(messages, tools: tools, thinking: settings.thinking,date:self.promptDate),
                        futurePrompt: family.render(future, tools: tools, thinking: settings.thinking,date:self.promptDate), contextLimit: 2048)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
