import XCTest
@testable import OpenWeightsCore

final class CompiledQwen25PromptTests: XCTestCase {
    private let tool = AgentToolDefinition(name: "web_search", description: "Search the web for current information.", parametersJSON: "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\", \"description\": \"What to search for\"}}, \"required\": [\"query\"]}")
    private func message(_ role: String, _ text: String) -> [String: String] { ["role": role, "content": text] }
    func testMatchesSixUpstreamGeneratedAndroidFixtures() throws {
        struct Reference: Decodable { let reference: [String: String] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-qwen25-prompt-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url)).reference
        let city = message("user", "What is the capital of Japan?"), system = message("system", "You are a terse assistant.")
        let weather = message("user", "What is the weather in Manila?")
        let call = "<tool_call>\n{\"name\": \"web_search\", \"arguments\": {\"query\": \"Manila weather\"}}\n</tool_call>"
        let cases: [(String, [[String: String]], [AgentToolDefinition])] = [
            ("PLAIN", [city], []), ("WITH_SYSTEM", [system, city], []),
            ("WITH_TOOLS", [weather], [tool]), ("WITH_SYSTEM_AND_TOOLS", [system, weather], [tool]),
            ("TOOL_RUN", [weather, message("assistant", call), message("tool", "Manila: 31C, humid.")], [tool]),
            ("TWO_TOOL_RESULTS", [message("user", "Compare Manila and Tokyo."), message("assistant", "Looking both up."), message("tool", "Manila: 31C."), message("tool", "Tokyo: 22C.")], [tool])
        ]
        for (name, messages, tools) in cases { XCTAssertEqual(try CompiledQwen25Prompt.render(messages, tools: tools), reference[name], name) }
    }
    func testExplicitEmptySystemAndLaterSystemRemainVerbatim() throws {
        let messages = [message("system", ""), message("user", "Cedar"), message("system", "Be brief.")]
        let plain = try CompiledQwen25Prompt.render(messages)
        XCTAssertTrue(plain.hasPrefix("<|im_start|>system\n<|im_end|>\n"))
        XCTAssertTrue(plain.contains("<|im_start|>system\nBe brief.<|im_end|>\n"))
        let offered = try CompiledQwen25Prompt.render(messages, tools: [tool])
        XCTAssertTrue(offered.hasPrefix("<|im_start|>system\n\n\n# Tools"))
        XCTAssertFalse(plain.contains("created by Alibaba")); XCTAssertFalse(offered.contains("created by Alibaba"))
    }
    func testRawHistoryCachePrefixAndThinkingPreferenceDoNotAlterQwen25Protocol() throws {
        let head = [message("system", "Remember Cedar."), message("user", "Read it.")]
        let call = "<tool_call>{\"name\":\"web_search\",\"arguments\":{}}</tool_call>"
        let initial = try CompiledQwen25Prompt.render(head, tools: [tool])
        let history = try CompiledQwen25Prompt.render(head + [message("assistant", call), message("tool", "Cedar.")], tools: [tool])
        XCTAssertTrue(history.hasPrefix(initial + call + "<|im_end|>\n")); XCTAssertFalse(initial.contains("<think>"))
        XCTAssertEqual(try CompiledModelFamily.qwen25.render(head, tools: [tool], thinking: true), initial)
        XCTAssertEqual(try CompiledModelFamily.qwen25.render(head, tools: [tool], thinking: false), initial)
        XCTAssertFalse(CompiledModelFamily.qwen25.supportsThinking); XCTAssertTrue(CompiledModelFamily.qwen3.supportsThinking)
        XCTAssertThrowsError(try CompiledQwen25Prompt.render([message("invented", "Cedar")]))
        XCTAssertThrowsError(try CompiledQwen25Prompt.render(head, tools: [AgentToolDefinition(name: "x", description: "x", parametersJSON: "[]")]))
    }
    func testDeclaredSourceFamilyRefusesOtherProtocolsAndUninstructedQwen25() {
        XCTAssertEqual(CompiledModelFamily.from(sourceModel: "Qwen/Qwen2.5-1.5B-Instruct"), .qwen25)
        XCTAssertEqual(CompiledModelFamily.from(sourceModel: "Qwen/Qwen3-0.6B"), .qwen3)
        for source in ["Qwen/Qwen2.5-1.5B", "Qwen/Qwen2.5-Coder-1.5B-Instruct", "Qwen/Qwen2.5-VL-3B-Instruct", "Qwen/Qwen3.5-2B", "Qwen/Qwen3-VL-2B", "meta-llama/Llama-3.2-1B", "", "qwen25"] {
            XCTAssertNil(CompiledModelFamily.from(sourceModel: source), source)
        }
    }
}
