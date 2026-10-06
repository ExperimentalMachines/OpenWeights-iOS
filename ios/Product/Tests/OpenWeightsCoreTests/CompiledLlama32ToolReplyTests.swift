import XCTest
@testable import OpenWeightsCore

final class CompiledLlama32ToolReplyTests:XCTestCase {
    func testOneLeadingPythonTagParsesWithoutAdmittingProseOrDuplicateTags() throws {
        let object=#"{"name":"read_memory","parameters":{}}"#
        let plain=try XCTUnwrap(CompiledLlama32ToolReply.parse(object,offered:["read_memory"]))
        let tagged=try XCTUnwrap(CompiledLlama32ToolReply.parse(" \n<|python_tag|> \n"+object+" \n",offered:["read_memory"]))
        XCTAssertEqual(tagged.content,plain.content);XCTAssertEqual(tagged.calls,plain.calls)
        for raw in ["Example: <|python_tag|>"+object,"<|python_tag|><|python_tag|>"+object,"<|python_tag|>"+object+" Explanation","<|python_tag|>```json\n"+object+"\n```","<|python_tag|>","<|python_tag|>{broken}"] {
            XCTAssertNil(CompiledLlama32ToolReply.parse(raw,offered:["read_memory"]),raw)
        }
        XCTAssertNil(CompiledLlama32ToolReply.parse("<|python_tag|>"+object,offered:["save_memory"]))
        XCTAssertNil(BareToolReply.parse("<|python_tag|>"+object,offered:["read_memory"]))
    }
    func testBareParametersCallPreservesUnicodeAndIsFamilySpecific() throws {
        let raw=#"{"name":"save_memory","parameters":{"fact":"Café \"Cedar\"\nline"}}"#
        let value=try XCTUnwrap(CompiledLlama32ToolReply.parse(raw,offered:["save_memory"]))
        XCTAssertEqual(value.calls.map(\.name),["save_memory"])
        let args=try JSONSerialization.jsonObject(with:Data(value.calls[0].argumentsJSON.utf8)) as? [String:String]
        XCTAssertEqual(args?["fact"],"Café \"Cedar\"\nline")
        XCTAssertNil(BareToolReply.parse(raw,offered:["save_memory"]))
        XCTAssertNil(CompiledLlama32ToolReply.parse(#"{"name":"read_memory","arguments":{}}"#,offered:["read_memory"]))
    }
    func testUnofferedAmbiguousMalformedAndExampleCallsNeverExecute() {
        let raw=#"{"name":"read_memory","parameters":{}}"#
        XCTAssertNil(CompiledLlama32ToolReply.parse(raw,offered:[]));XCTAssertNil(CompiledLlama32ToolReply.parse(raw,offered:["save_memory"]))
        for text in ["Example: "+raw,raw+" Explanation","```json\n"+raw+"\n```",raw+"{}",#"{"name":"read_memory","parameters":[],"arguments":{}}"#,#"{"name":"read_memory","parameters":{},"arguments":{}}"#,#"{"name":"read_memory","parameters":null}"#,#"{"tool":"read_memory","parameters":{}}"#] {
            XCTAssertNil(CompiledLlama32ToolReply.parse(text,offered:["read_memory"]),text)
        }
        XCTAssertNotNil(CompiledLlama32ToolReply.parse("\n "+raw+" \n",offered:["read_memory"]))
        XCTAssertNil(CompiledLlama32ToolReply.parse(String(repeating:" ",count:65537)+raw,offered:["read_memory"]))
    }
}
