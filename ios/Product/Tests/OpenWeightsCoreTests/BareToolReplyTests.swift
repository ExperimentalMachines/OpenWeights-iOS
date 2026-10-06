import XCTest
@testable import OpenWeightsCore

final class BareToolReplyTests: XCTestCase {
    func testCapturedCompiledReadMemoryCall() throws {
        let raw = "{\"name\": \"read_memory\", \"arguments\": {}}"
        let parsed = try XCTUnwrap(BareToolReply.parse(raw, offered: ["read_memory"]))
        XCTAssertEqual(parsed.content, ""); XCTAssertEqual(parsed.calls.map(\.name), ["read_memory"])
        XCTAssertEqual(parsed.calls[0].argumentsJSON, "{}")
    }
    func testAndroidToolKeyAndEscapedUnicodeArguments() throws {
        let raw = "{\"tool\":\"save_memory\",\"arguments\":{\"fact\":\"Café 🧠 \\\"Cedar\\\"\\nline\"}}"
        let parsed = try XCTUnwrap(BareToolReply.parse(raw, offered: ["save_memory"]))
        let args = try JSONSerialization.jsonObject(with: Data(parsed.calls[0].argumentsJSON.utf8)) as? [String: String]
        XCTAssertEqual(args?["fact"], "Café 🧠 \"Cedar\"\nline")
    }
    func testUnOfferedOrSwitchedOffCallsAreNeverAccepted() {
        let raw = "{\"name\":\"read_memory\",\"arguments\":{}}"
        XCTAssertNil(BareToolReply.parse(raw, offered: [])); XCTAssertNil(BareToolReply.parse(raw, offered: ["save_memory"]))
    }
    func testTruncatedMalformedAndNonObjectArgumentsAreRejected() {
        for raw in ["{\"name\":\"read_memory\",\"arguments\":", "{\"name\":\"read_memory\"}", "{\"name\":\"read_memory\",\"arguments\":[]}", "{\"name\":\"read_memory\",\"arguments\":null}", "{\"name\":\"read_memory\",\"arguments\":{}}{}"] {
            XCTAssertNil(BareToolReply.parse(raw, offered: ["read_memory"]))
        }
    }
    func testProseFencesThinkingAndExamplesCannotTriggerCalls() {
        let raw = "{\"name\":\"read_memory\",\"arguments\":{}}"
        for text in ["Example: " + raw, raw + " That's an example.", "```json\n" + raw + "\n```", "<think>" + raw + "</think>Answer.", "{\"example\":" + raw + "}"] {
            XCTAssertNil(BareToolReply.parse(text, offered: ["read_memory"]))
        }
    }
    func testOversizeRepliesFailButWhitespaceIsAllowed() throws {
        let raw = "{\"name\":\"read_memory\",\"arguments\":{}}"
        XCTAssertNotNil(BareToolReply.parse("\n " + raw + " \n", offered: ["read_memory"]))
        XCTAssertNil(BareToolReply.parse(String(repeating: " ", count: 65_537) + raw, offered: ["read_memory"]))
    }
}
