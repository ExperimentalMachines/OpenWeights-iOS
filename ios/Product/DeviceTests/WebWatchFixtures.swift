import Foundation
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

struct WebWatchExchange: Sendable {
    let address: String
    let status: Int
    let bytes: Int
    let bodySHA256: String
    var json: [String: Any] { ["address": address, "status": status, "bytes": bytes, "bodySHA256": bodySHA256] }
}
struct WebWatchFixtureResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
actor WebWatchFixtureConnector: PublicWebConnecting {
    let live: Bool
    private var identifier = "Saffron"
    private var exchanges: [WebWatchExchange] = []
    init(live: Bool) { self.live = live }
    func changeIdentifier() { identifier = "Cobalt" }
    func observations() -> [WebWatchExchange] { exchanges }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        let response: WebHTTPResponse
        if live { response = try await ApplePublicWebConnector().exchange(address: address, ip: ip, timeout: timeout, maximumBody: maximumBody) }
        else { response = WebHTTPResponse(status: 200, headers: ["content-type": "text/plain"], body: Data("Current status identifier: \(identifier).".utf8)) }
        exchanges.append(WebWatchExchange(address: address.url.absoluteString, status: response.status, bytes: response.body.count, bodySHA256: SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()))
        return response
    }
}
@MainActor final class WebWatchFixtureClock { var now = Date() }

/// Records inputs and replies while delegating every operation to the real CPU adapter.
final class WebWatchObservedRuntime: ChatRuntime, @unchecked Sendable {
    private let real = LlamaRuntime(gpuLayers: 0)
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    var supportsTools: Bool { real.supportsTools }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return records }
    func load(model: LocalModel, directory: URL) async throws { try await real.load(model: model, directory: directory) }
    func cancel() { real.cancel() }
    func reset() async { await real.reset() }
    func warm(messages: [[String: String]], settings: ModelSettings) async throws { try await real.warm(messages: messages, settings: settings) }
    func warm(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws { try await real.warm(messages: messages, settings: settings, tools: tools) }
    func promptSize(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) async throws -> RuntimePromptSize { try await real.promptSize(messages: messages, settings: settings, tools: tools) }
    func stream(messages: [[String: String]], settings: ModelSettings) -> AsyncThrowingStream<RuntimeEvent, Error> { stream(messages: messages, settings: settings, tools: []) }
    private func begin(_ messages: [[String: String]], tools: [AgentToolDefinition]) -> Int {
        lock.lock(); defer { lock.unlock() }
        records.append(["messages": messages, "offeredTools": tools.map(\.name)])
        return records.count - 1
    }
    private func record(_ reply: RuntimeReply, index: Int) {
        lock.lock(); defer { lock.unlock() }
        records[index]["reply"] = ["content": reply.content, "promptContent": reply.promptContent ?? "", "stopReason": reply.stopReason.rawValue, "cancelled": reply.cancelled,
                                  "toolCalls": reply.toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": $0.arguments] }]
    }
    func stream(messages: [[String: String]], settings: ModelSettings, tools: [AgentToolDefinition]) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let index = begin(messages, tools: tools), source = real.stream(messages: messages, settings: settings, tools: tools)
        return AsyncThrowingStream { continuation in
            let relay = Task {
                do {
                    for try await event in source {
                        if case .reply(let reply) = event { self.record(reply, index: index) }
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
