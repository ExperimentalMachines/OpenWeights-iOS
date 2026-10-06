import XCTest
@testable import OpenWeightsCore

final class TaggedToolReplyTests: XCTestCase {
    private let offered: Set<String> = ["save_memory", "write_file", "ask_user"]
    func testCapturedDeviceCallsAndSurroundingProse() throws {
        let examples = [("save_memory", "{\"fact\":\"My project is Cedar.\"}"), ("write_file", "{\"content\":\"Cedar\",\"path\":\"note.txt\",\"replace\":false}"), ("ask_user", "{\"question\":\"Which city would you like to visit? Please choose either Osaka or Porto.\"}")]
        for (name, args) in examples {
            let parsed = try XCTUnwrap(TaggedToolReply.parse("Before.\n<tool_call>\n{\"name\":\"\(name)\",\"arguments\":\(args)}\n</tool_call>\nAfter.", offered: offered))
            XCTAssertEqual(parsed.calls.count, 1); XCTAssertEqual(parsed.calls[0].name, name)
            XCTAssertEqual(parsed.content, "Before.\n\nAfter.")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(parsed.calls[0].argumentsJSON.utf8)) as? NSDictionary, try JSONSerialization.jsonObject(with: Data(args.utf8)) as? NSDictionary)
        }
    }
    func testMultipleCallsKeepDistinctIDsAndEscapedUnicodeArguments() throws {
        let envelope = "<tool_call>{\"name\":\"save_memory\",\"arguments\":{\"fact\":\"Café 🧠 {Cedar} \\\"quote\\\"\\nline\"}}</tool_call>"
        let parsed = try XCTUnwrap(TaggedToolReply.parse(envelope + envelope, offered: offered))
        XCTAssertEqual(parsed.calls.count, 2); XCTAssertNotEqual(parsed.calls[0].id, parsed.calls[1].id); XCTAssertEqual(parsed.content, "")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(parsed.calls[0].argumentsJSON.utf8)) as? [String: String])?["fact"], "Café 🧠 {Cedar} \"quote\"\nline")
    }
    func testMissingDisabledUnknownOrMalformedCallsAreRefusedWhole() {
        let valid = "<tool_call>{\"name\":\"save_memory\",\"arguments\":{}}</tool_call>"
        XCTAssertNil(TaggedToolReply.parse(valid, offered: []))
        for raw in [valid.replacingOccurrences(of: "save_memory", with: "invented"), valid.replacingOccurrences(of: "{}", with: "[]"), valid.replacingOccurrences(of: "</tool_call>", with: ""), valid.replacingOccurrences(of: "{\"name\"", with: "{bad\"name\""), valid + "<tool_call>", String(repeating: "x", count: 65_537) + valid] {
            XCTAssertNil(TaggedToolReply.parse(raw, offered: offered))
        }
    }
    func testThinkingCallsAndFencedExamplesNeverBecomeEffects() throws {
        let call = "<tool_call>{\"name\":\"save_memory\",\"arguments\":{}}</tool_call>"
        XCTAssertNil(TaggedToolReply.parse("<think>" + call + "</think>Plain answer.", offered: offered))
        XCTAssertNil(TaggedToolReply.parse("<think>" + call, offered: offered))
        XCTAssertNil(TaggedToolReply.parse("```xml\n" + call + "\n```", offered: offered))
        XCTAssertNil(TaggedToolReply.parse("{\"name\":\"save_memory\",\"arguments\":{}}", offered: offered))
        XCTAssertEqual(try XCTUnwrap(TaggedToolReply.parse("Thought.</think>" + call, offered: offered)).calls.count, 1)
    }
}
