import XCTest
@testable import OpenWeightsCore

final class CompiledQwen3PromptTests: XCTestCase {
    private let tool = AgentToolDefinition(name: "web_search", description: "Search the web for current information.", parametersJSON: "{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\", \"description\": \"What to search for\"}}, \"required\": [\"query\"]}")
    private func message(_ role: String, _ text: String) -> [String: String] { ["role": role, "content": text] }
    func testMatchesEightUpstreamGeneratedAndroidFixtures() throws {
        struct Reference: Decodable { let reference: [String: String] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "android-qwen3-prompt-reference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url)).reference
        let city = message("user", "What is the capital of Japan?"), system = message("system", "You are a terse assistant.")
        let weather = message("user", "What is the weather in Manila?")
        let call = "<think>\nI should look this up.\n</think>\n\n<tool_call>\n{\"name\": \"web_search\", \"arguments\": {\"query\": \"Manila weather\"}}\n</tool_call>"
        let cases: [(String, [[String: String]], [AgentToolDefinition], Bool)] = [
            ("PLAIN", [city], [], true), ("WITH_SYSTEM", [system, city], [], true), ("THINKING_DISABLED", [city], [], false),
            ("WITH_TOOLS", [weather], [tool], true), ("WITH_SYSTEM_AND_TOOLS", [system, weather], [tool], true),
            ("SYSTEM_NOT_FIRST", [message("user", "Hello."), message("system", "Be brief from now on."), city], [], true),
            ("TOOL_RUN", [weather, message("assistant", call), message("tool", "Manila: 31C, humid.")], [tool], true),
            ("TWO_TOOL_RESULTS", [message("user", "Compare Manila and Tokyo."), message("assistant", "Looking both up."), message("tool", "Manila: 31C."), message("tool", "Tokyo: 22C.")], [tool], true)
        ]
        for (name, messages, tools, thinking) in cases {
            XCTAssertEqual(try CompiledQwen3Prompt.render(messages, tools: tools, thinking: thinking), reference[name], name)
        }
    }
    func testVerbatimAssistantHistoryPreservesGeneratedPrefix() throws {
        let head = [message("system", "Remember Cedar."), message("user", "Read it.")]
        let raw = "<think>\nReasoning.\n</think>\n\n<tool_call>{\"name\":\"web_search\",\"arguments\":{}}</tool_call>"
        let initial = try CompiledQwen3Prompt.render(head, tools: [tool], thinking: false)
        let history = head + [message("assistant", "<think>\n\n</think>\n\n" + raw), message("tool", "Cedar.")]
        let extended = try CompiledQwen3Prompt.render(history, tools: [tool], thinking: false)
        XCTAssertTrue(extended.hasPrefix(initial + raw + "<|im_end|>\n"))
        let later = try CompiledQwen3Prompt.render(history + [message("user", "Next question.")], tools: [tool], thinking: false)
        XCTAssertTrue(later.contains(raw)); XCTAssertFalse(later.contains("<|im_start|>tool"))
    }
    func testToolWithdrawalChangesHeadAndStableDefinitionsDoNot() throws {
        let head = [message("system", "Remember Cedar.")]
        let offered = try CompiledQwen3Prompt.render(head, tools: [tool], thinking: false)
        XCTAssertEqual(offered, try CompiledQwen3Prompt.render(head, tools: [tool], thinking: false))
        XCTAssertNotEqual(offered, try CompiledQwen3Prompt.render(head, tools: [], thinking: false))
        let future = try CompiledQwen3Prompt.render(head + [message("user", "Next.")], tools: [tool], thinking: false)
        let stable = String(offered.prefix(upTo: try XCTUnwrap(offered.range(of: "<|im_start|>assistant")).lowerBound))
        XCTAssertTrue(future.hasPrefix(stable))
    }
    func testQuotedToolFieldsAndRawSchemaRoundTrip() throws {
        let name = "quote\"\\\n\u{0001}café 🧠", description = "url / and \t\r\u{0000} text"
        let schema = "{\"properties\": {\"fact\": {\"type\": \"string\"}}, \"type\": \"object\"}"
        let rendered = try CompiledQwen3Prompt.render([], tools: [AgentToolDefinition(name: name, description: description, parametersJSON: schema)], thinking: true)
        let start = try XCTUnwrap(rendered.range(of: "<tools>\n")), end = try XCTUnwrap(rendered.range(of: "\n</tools>"))
        let json = String(rendered[start.upperBound..<end.lowerBound])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let function = try XCTUnwrap(object["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, name); XCTAssertEqual(function["description"] as? String, description)
        XCTAssertTrue(json.contains(schema))
    }
    func testInvalidSchemasAndMessageRolesFailBeforeRendering() {
        for raw in ["[]", "null", "not JSON", "{\"type\":}"] {
            XCTAssertThrowsError(try CompiledQwen3Prompt.render([], tools: [AgentToolDefinition(name: "x", description: "x", parametersJSON: raw)], thinking: false))
        }
        XCTAssertThrowsError(try CompiledQwen3Prompt.render([message("invented", "Cedar")], thinking: false))
    }
    func testEmptyLeadingSystemIsOmittedLikeAndroid() throws {
        let user = message("user", "Cedar")
        XCTAssertEqual(try CompiledQwen3Prompt.render([message("system", ""), user], thinking: false), try CompiledQwen3Prompt.render([user], thinking: false))
    }
}
