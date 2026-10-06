import Foundation
#if !GGUF_ONLY
import ExecuTorchLLM
#endif
#if !EXECUTORCH_DELEGATES
#if !GGUF_ONLY
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

final class LlamaEngine: BenchmarkEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.experimentalmachines.benchmark.llama", qos: .userInitiated)
    private let gpuLayers: Int32
    private var session: OWSession?
    var backend: String { session?.backend() ?? "unloaded" }
    init(gpuLayers: Int32) { self.gpuLayers = gpuLayers }
    func load(directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.session = try OWSession(path: directory.appendingPathComponent("Qwen3-0.6B-Q4_K_M.gguf").path, gpuLayers: self.gpuLayers)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func generate(messages: [[String: String]], maxTokens: Int, cancelAfter: Int?, cancellation: Cancellation,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> EngineReply {
        guard let session else { throw BenchmarkFailure.message("llama.cpp is not loaded") }
        cancellation.install { session.cancel() }
        defer { cancellation.install(nil) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    var count = 0; var requestedAt: Double?
                    let value = try session.generateMessages(messages, tools: [], maxTokens: Int32(maxTokens)) { piece in
                        count += 1; onToken(piece)
                        if let cancelAfter, count >= cancelAfter, requestedAt == nil { requestedAt = clockMilliseconds(); session.cancel() }
                        return !cancellation.isCancelled
                    }
                    let reason = (value["stopReason"] as? NSNumber)?.intValue ?? 4
                    continuation.resume(returning: EngineReply(output: value["content"] as? String ?? "",
                        generatedTokens: (value["generatedTokens"] as? NSNumber)?.intValue ?? 0,
                        promptTokens: (value["promptTokens"] as? NSNumber)?.intValue,
                        cachedTokens: (value["cachedTokens"] as? NSNumber)?.intValue,
                        prefillMs: (value["prefillMs"] as? NSNumber)?.doubleValue,
                        decodeMs: (value["decodeMs"] as? NSNumber)?.doubleValue,
                        stopReason: ["eos", "length", "context-full", "cancelled", "error"][min(max(reason, 0), 4)],
                        cancellationRequestedAt: requestedAt))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func reset() async { await withCheckedContinuation { continuation in queue.async { self.session?.reset(); continuation.resume() } } }
    func unload() async { await withCheckedContinuation { continuation in queue.async { self.session = nil; continuation.resume() } } }
}

#endif

#if !GGUF_ONLY
final class ExecuTorchEngine: BenchmarkEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.experimentalmachines.benchmark.executorch", qos: .userInitiated)
    private var runner: TextRunner?
    private let modelFile: String
    private let backendDescription: String
    var backend: String { backendDescription }
    init(modelFile: String = "xnnpack/Qwen3-0.6B-8da4w-2k.pte",
         backend: String = "XNNPACK CPU; 2k export; cache reset before each turn") {
        self.modelFile = modelFile; self.backendDescription = backend
    }
    func load(directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let runner = TextRunner(modelPath: directory.appendingPathComponent(self.modelFile).path,
                        tokenizerPath: directory.appendingPathComponent("tokenizer.json").path)
                    try runner.load(); self.runner = runner; continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func generate(messages: [[String: String]], maxTokens: Int, cancelAfter: Int?, cancellation: Cancellation,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> EngineReply {
        guard let runner else { throw BenchmarkFailure.message("ExecuTorch is not loaded") }
        cancellation.install { runner.stop() }
        defer { cancellation.install(nil) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    // The Objective-C runner appends prompts. Resetting avoids silently duplicating history.
                    runner.reset()
                    var output = ""; var count = 0; var stopped = false; var requestedAt: Double?
                    try runner.generate(renderPrompt(messages), Config {
                        $0.temperature = 0; $0.sequenceLength = 2048; $0.maximumNewTokens = maxTokens
                        $0.isEchoEnabled = false; $0.bosCount = 0; $0.eosCount = 0
                    }) { piece in
                        if piece == "<|im_end|>" || piece == "<|endoftext|>" { return }
                        count += 1; output += piece; onToken(piece)
                        if cancellation.isCancelled || (cancelAfter != nil && count >= cancelAfter!) {
                            if requestedAt == nil { requestedAt = clockMilliseconds() }; stopped = true; runner.stop()
                        }
                    }
                    continuation.resume(returning: EngineReply(output: output, generatedTokens: count,
                        promptTokens: nil, cachedTokens: 0, prefillMs: nil, decodeMs: nil,
                        stopReason: stopped ? "cancelled" : (count >= maxTokens ? "length" : "eos"), cancellationRequestedAt: requestedAt))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func reset() async { await withCheckedContinuation { continuation in queue.async { self.runner?.reset(); continuation.resume() } } }
    func unload() async { await withCheckedContinuation { continuation in queue.async { self.runner = nil; continuation.resume() } } }
}

#if !EXECUTORCH_DELEGATES
struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        LocalTokenizer(base: try await AutoTokenizer.from(modelFolder: directory))
    }
}

final class MLXEngine: BenchmarkEngine, @unchecked Sendable {
    private var container: ModelContainer?
    private var cache: [KVCache] = []
    private var recordedTokens: [Int] = []
    var backend: String { "MLX Metal; unquantized KV cache; prefix reuse enabled" }
    func load(directory: URL) async throws {
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
    }
    func generate(messages: [[String: String]], maxTokens: Int, cancelAfter: Int?, cancellation: Cancellation,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> EngineReply {
        guard let container else { throw BenchmarkFailure.message("MLX is not loaded") }
        return try await container.perform { context in
            let tokens = context.tokenizer.encode(text: renderPrompt(messages), addSpecialTokens: false)
            guard tokens.count + maxTokens <= 2048 else { throw BenchmarkFailure.message("MLX prompt exceeds the matched 2k context") }
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, repetitionPenalty: nil, prefillStepSize: 512)
            if self.cache.isEmpty { self.cache = context.model.newCache(parameters: parameters) }
            let offset = self.cache.first?.offset ?? 0
            var prefix = 0
            while prefix < min(tokens.count - 1, min(offset, self.recordedTokens.count)), tokens[prefix] == self.recordedTokens[prefix] { prefix += 1 }
            if offset > prefix {
                if !canTrimPromptCache(self.cache) || trimPromptCache(self.cache, numTokens: offset - prefix) != offset - prefix {
                    self.cache = context.model.newCache(parameters: parameters); prefix = 0
                }
            }
            let input = LMInput(tokens: MLXArray(Array(tokens.dropFirst(prefix))))
            let iterator = try TokenIterator(input: input, model: context.model, cache: self.cache, parameters: parameters)
            var generated: [Int] = []; var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var output = ""; var stopped = false; var requestedAt: Double?
            let info = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { token in
                generated.append(token); detokenizer.append(token: token)
                if let piece = detokenizer.next() { output += piece; onToken(piece) }
                if cancellation.isCancelled || (cancelAfter != nil && generated.count >= cancelAfter!) {
                    requestedAt = clockMilliseconds(); stopped = true; return .stop
                }
                return .more
            }
            eval(self.cache.flatMap { $0.state })
            self.recordedTokens = tokens + generated
            return EngineReply(output: output, generatedTokens: info.generationTokenCount,
                promptTokens: info.promptTokenCount, cachedTokens: prefix,
                prefillMs: info.promptTime * 1000, decodeMs: info.generateTime * 1000,
                stopReason: stopped ? "cancelled" : (info.generationTokenCount >= maxTokens ? "length" : "eos"), cancellationRequestedAt: requestedAt)
        }
    }
    func reset() async { cache = []; recordedTokens = [] }
    func unload() async { cache = []; recordedTokens = []; container = nil; Memory.clearCache() }
}
#endif
#endif
