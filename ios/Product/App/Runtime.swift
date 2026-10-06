import Foundation
import Metal
import OpenWeightsCore

enum RuntimeStopReason: Int, Sendable { case endOfTurn, maxTokens, contextFull, cancelled, error, unknown }
struct RuntimePromptSize: Sendable { var tokens: Int; var exact: Bool }
struct RuntimeReply: Sendable {
    var content: String
    var reasoning = ""
    var promptContent: String? = nil
    var generatedTokens: Int
    var cachedTokens: Int
    var contextUsed: Int
    var contextSize: Int
    var firstTextMilliseconds: Double
    var tokensPerSecond: Double
    var cancelled: Bool
    var toolCalls: [RuntimeToolCall] = []
    var stopReason: RuntimeStopReason = .unknown
    var usage: UsageMeasurements? = nil
}
struct RuntimeToolCall: Codable, Sendable { var id: String; var name: String; var arguments: String }
enum RuntimeEvent: Sendable { case token(String), reply(RuntimeReply) }

struct RuntimeMediaSupport: Sendable, Equatable {
    var vision = false
    var audio = false
    var marker = ""
    func accepts(_ kind: ChatAttachment.Kind) -> Bool { kind == .audio ? audio : vision }
}
struct RuntimePrompt: Sendable {
    var messages: [[String: String]]
    var mediaPaths: [[String]]
    init(messages: [[String: String]], mediaPaths: [[String]]? = nil) {
        self.messages = messages; self.mediaPaths = mediaPaths ?? Array(repeating: [], count: messages.count)
    }
    var hasMedia: Bool { mediaPaths.contains { !$0.isEmpty } }
    func nativeMessages(marker: String) throws -> [[String: Any]] {
        guard mediaPaths.count == messages.count, !hasMedia || !marker.isEmpty else { throw AttachmentError.corrupt }
        return messages.enumerated().map { index, message in
            var value: [String: Any] = message
            let paths = mediaPaths[index]
            if !paths.isEmpty {
                value["content"] = Array(repeating: marker, count: paths.count).joined() + (message["content"] ?? "")
                value["media_paths"] = paths
            }
            return value
        }
    }
}

protocol ChatRuntime: AnyObject, Sendable {
    var supportsTools: Bool { get }
    var supportsReasoningEffort: Bool { get }
    var mediaSupport: RuntimeMediaSupport { get }
    func stream(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error>
    func warm(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws
    func promptSize(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize
    func load(model: LocalModel, directory: URL) async throws
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error>
    func cancel()
    func reset() async
    func warm(messages: [[String: String]], settings: ModelSettings) async throws
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error>
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize
}

extension ChatRuntime {
    var mediaSupport: RuntimeMediaSupport { RuntimeMediaSupport() }
    func stream(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        guard !prompt.hasMedia else { return AsyncThrowingStream { $0.finish(throwing: ModelError.unsupported("This adapter cannot read attachments. Select a compatible media model.")) } }
        return stream(messages: prompt.messages, settings: settings, tools: tools)
    }
    func warm(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        guard !prompt.hasMedia else { throw ModelError.unsupported("This adapter cannot read attachments.") }
        try await warm(messages: prompt.messages, settings: settings, tools: tools)
    }
    func promptSize(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        guard !prompt.hasMedia else { throw ModelError.unsupported("This adapter cannot read attachments.") }
        return try await promptSize(messages: prompt.messages, settings: settings, tools: tools)
    }

    var supportsTools: Bool { false }
    var supportsReasoningEffort: Bool { false }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        throw ModelError.unsupported("This adapter cannot measure conversation size.")
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        guard tools.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: ModelError.unsupported("This adapter does not support enabled tools. Select a tool-capable model or turn the tools off.")) }
        }
        return stream(messages: messages, settings: settings)
    }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        guard tools.isEmpty else { throw ModelError.unsupported("This adapter does not support enabled tools.") }
        try await warm(messages: messages, settings: settings)
    }
}

private extension AgentToolDefinition {
    func nativeDefinition() throws -> [String: Any] {
        guard let parameters = try JSONSerialization.jsonObject(with: Data(parametersJSON.utf8)) as? [String: Any] else {
            throw ModelError.unsupported("Tool parameters must be a JSON object.")
        }
        return ["name": name, "description": description, "parameters": parameters]
    }
}

enum RuntimeFactory {
    static func make(_ model: LocalModel) throws -> any ChatRuntime {
        switch model.backend {
        case .llamaMetal:
            guard MTLCreateSystemDefaultDevice() != nil else {
                throw ModelError.unsupported("Metal is unavailable. Select the CPU backend in model settings.")
            }
            return LlamaRuntime(gpuLayers: 99)
        case .llamaCPU: return LlamaRuntime(gpuLayers: 0)
        case .mlx: return ProductMLXRuntime()
        case .xnnpack:
            guard CompiledModelFamily(rawValue: model.family ?? "") != nil else { throw ModelError.unsupported("This iOS compiled adapter supports Qwen3, Qwen2.5 Instruct, SmolLM2 Instruct and Llama 3.2 Instruct exports. Other Android families still need port verification.") }
            return ProductExecuTorchRuntime()
        case .executorchMLX:
            guard MTLCreateSystemDefaultDevice() != nil else { throw ModelError.unsupported("This compiled MLX export requires Metal. Select a CPU export instead.") }
            guard model.family == CompiledModelFamily.qwen3.rawValue else { throw ModelError.unsupported("The current ExecuTorch MLX adapter supports declared Qwen3 exports. Other families need device verification.") }
            return ProductExecuTorchRuntime(backend:.executorchMLX)
        }
    }
}

final class LlamaRuntime: ChatRuntime, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.experimentalmachines.openweights.llama", qos: .userInitiated)
    private let lock = NSLock()
    private let gpuLayers: Int32
    private var session: OWRuntimeSession?
    private var toolSupport = false
    private var effortSupport = false
    private var media = RuntimeMediaSupport()
    private let cancellation = RuntimeCancellation()
    init(gpuLayers: Int32) { self.gpuLayers = gpuLayers }
    var supportsTools: Bool { lock.lock(); defer { lock.unlock() }; return toolSupport }
    var supportsReasoningEffort: Bool { lock.lock(); defer { lock.unlock() }; return effortSupport }

    var mediaSupport: RuntimeMediaSupport { lock.lock(); defer { lock.unlock() }; return media }

    func load(model: LocalModel, directory: URL) async throws {
        try model.settings.validate(for: model.backend)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let path = try ModelFile(path: model.entryFile).destination(in: directory)
                    let projector = model.files.first { $0.path.lowercased().contains("mmproj") }
                    let projectorPath = try projector?.destination(in: directory).path ?? ""
                    let value = try OWRuntimeSession(path: path.path, projector: projectorPath,
                        context: Int32(model.settings.contextTokens), threads: Int32(model.settings.threads), gpuLayers: self.gpuLayers)
                    let capabilities = value.capabilities()
                    self.lock.lock(); self.session = value
                    self.toolSupport = (capabilities["tools"] as? Bool ?? false) && (capabilities["toolResults"] as? Bool ?? false)
                    self.effortSupport = capabilities["reasoningEffort"] as? Bool ?? false
                    self.media = RuntimeMediaSupport(vision: capabilities["vision"] as? Bool ?? false,
                        audio: capabilities["audio"] as? Bool ?? false, marker: capabilities["mediaMarker"] as? String ?? "")
                    self.lock.unlock()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> {
        stream(messages: messages, settings: settings, tools: [])
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        stream(prompt: RuntimePrompt(messages: messages), settings: settings, tools: tools)
    }
    func stream(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        cancellation.reset()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
            }
            queue.async {
                guard let session = self.session else { continuation.finish(throwing: ModelError.unsupported("Load a model before sending a message.")); return }
                do {
                    guard tools.isEmpty || self.supportsTools else { throw ModelError.unsupported("This model's template cannot exchange tool calls and results.") }
                    try settings.validate(for: self.gpuLayers == 0 ? .llamaCPU : .llamaMetal)
                    var options: [String: Any] = [
                        "temperature": settings.temperature, "topP": settings.topP, "repeatPenalty": settings.repeatPenalty,
                        "maxTokens": settings.outputTokens, "thinking": settings.thinking
                    ]
                    if let topK = settings.topK { options["topK"] = topK }
                    if let minP = settings.minP { options["minP"] = minP }
                    if let effort = settings.reasoningEffort { options["reasoningEffort"] = effort.wireValue }
                    let value = try session.generateMessages(try prompt.nativeMessages(marker: self.mediaSupport.marker), tools: try tools.map { try $0.nativeDefinition() }, options: options) {
                        piece in continuation.yield(.token(piece)); return !self.cancellation.isCancelled
                    }
                    let tokens = (value["generatedTokens"] as? NSNumber)?.intValue ?? 0
                    let decode = (value["decodeMs"] as? NSNumber)?.doubleValue ?? 0
                    let callsData = try JSONSerialization.data(withJSONObject: value["toolCalls"] ?? [])
                    var calls = try JSONDecoder().decode([RuntimeToolCall].self, from: callsData)
                    var content = value["content"] as? String ?? ""
                    let stop = RuntimeStopReason(rawValue: (value["stopReason"] as? NSNumber)?.intValue ?? 5) ?? .unknown
                    if calls.isEmpty, !tools.isEmpty, stop == .endOfTurn, content.contains("<tool_call>") {
                        guard let parsed = TaggedToolReply.parse(content, offered: Set(tools.map(\.name))) else {
                            throw ModelError.unsupported("The model wrote a tool call that could not be read. No action was performed.")
                        }
                        calls = parsed.calls.map { RuntimeToolCall(id: $0.id, name: $0.name, arguments: $0.argumentsJSON) }
                        content = parsed.content
                    }
                    continuation.yield(.reply(RuntimeReply(content: content,
                        reasoning: value["reasoning"] as? String ?? "", generatedTokens: tokens,
                        cachedTokens: (value["cachedTokens"] as? NSNumber)?.intValue ?? 0,
                        contextUsed: (value["contextUsed"] as? NSNumber)?.intValue ?? 0,
                        contextSize: (value["contextSize"] as? NSNumber)?.intValue ?? settings.contextTokens,
                        firstTextMilliseconds: (value["firstTextMs"] as? NSNumber)?.doubleValue ?? 0,
                        tokensPerSecond: decode > 0 ? Double(max(0, tokens - 1)) * 1000 / decode : 0,
                        cancelled: (value["stopReason"] as? NSNumber)?.intValue == 3, toolCalls: calls,
                        stopReason: RuntimeStopReason(rawValue: (value["stopReason"] as? NSNumber)?.intValue ?? 5) ?? .unknown,
                        usage: UsageMeasurements(promptTokens: (value["promptTokens"] as? NSNumber)?.intValue ?? 0,
                            generatedTokens: tokens, cachedTokens: (value["cachedTokens"] as? NSNumber)?.intValue ?? 0,
                            inferenceMilliseconds: ((value["prefillMs"] as? NSNumber)?.doubleValue ?? 0) + decode,
                            prefillMilliseconds: (value["prefillMs"] as? NSNumber)?.doubleValue,
                            decodeMilliseconds: decode, decodeTokens: max(0, tokens - 1), prefillIncludesCompute: true))))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
    func cancel() { cancellation.cancel(); lock.lock(); let value = session; lock.unlock(); value?.cancel() }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try settings.validate(for: self.gpuLayers == 0 ? .llamaCPU : .llamaMetal)
                    guard let session = self.session else { throw ModelError.unsupported("Load a model first.") }
                    let count = try session.countMessages(messages, tools: try tools.map { try $0.nativeDefinition() }, thinking: settings.thinking,
                        reasoningEffort: settings.reasoningEffort?.wireValue ?? "")
                    continuation.resume(returning: RuntimePromptSize(tokens: count.intValue, exact: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func promptSize(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize {
        guard prompt.hasMedia else { return try await promptSize(messages: prompt.messages, settings: settings, tools: tools) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try settings.validate(for: self.gpuLayers == 0 ? .llamaCPU : .llamaMetal)
                    guard let session = self.session else { throw ModelError.unsupported("Load a model first.") }
                    let count = try session.countMediaMessages(try prompt.nativeMessages(marker: self.mediaSupport.marker),
                        tools: try tools.map { try $0.nativeDefinition() }, thinking: settings.thinking,
                        reasoningEffort: settings.reasoningEffort?.wireValue ?? "")
                    continuation.resume(returning: RuntimePromptSize(tokens: count.intValue, exact: true))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func warm(prompt: RuntimePrompt, settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        guard !prompt.hasMedia else { return }
        try await warm(messages: prompt.messages, settings: settings, tools: tools)
    }
    func reset() async {
        await withCheckedContinuation { continuation in queue.async { self.session?.reset(); continuation.resume() } }
    }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws {
        try await warm(messages: messages, settings: settings, tools: [])
    }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try settings.validate(for: self.gpuLayers == 0 ? .llamaCPU : .llamaMetal)
                    guard tools.isEmpty || self.supportsTools else { throw ModelError.unsupported("This model's template cannot exchange tool calls and results.") }
                    _ = try self.session?.warmMessages(messages, tools: try tools.map { try $0.nativeDefinition() }, thinking: settings.thinking,
                        reasoningEffort: settings.reasoningEffort?.wireValue ?? "")
                    continuation.resume()
                }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func reset() { lock.lock(); stopped = false; lock.unlock() }
}

func qwenPrompt(_ messages: [[String: String]], thinking: Bool) -> String {
    messages.map { "<|im_start|>\($0["role"] ?? "user")\n\($0["content"] ?? "")<|im_end|>\n" }.joined()
        + "<|im_start|>assistant\n" + (thinking ? "" : "<think>\n\n</think>\n\n")
}
