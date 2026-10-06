import XCTest
@testable import OpenWeightsCore

final class CompiledLlama32PromptTests: XCTestCase {
    private let date="26 Jul 2024"
    private func m(_ role:String,_ text:String)->[String:String] { ["role":role,"content":text] }
    private let tool=AgentToolDefinition(name:"web_search",description:"Search the web for current information.",parametersJSON:"{\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\", \"description\": \"What to search for\"}}, \"required\": [\"query\"]}")
    func testMatchesSixUpstreamGeneratedAndroidFixtures() throws {
        struct Reference:Decodable { let reference:[String:String] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"android-llama32-prompt-reference",withExtension:"json",subdirectory:"Fixtures"))
        let refs=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:url)).reference
        let city=m("user","What is the capital of Japan?"),weather=m("user","What is the weather in Manila?")
        let call=m("assistant","{\"name\": \"web_search\", \"parameters\": {\"query\": \"Manila weather\"}}")
        let cases:[(String,[[String:String]],[AgentToolDefinition])]=[
            ("PLAIN",[city],[]),("WITH_SYSTEM",[m("system","You are a terse assistant."),city],[]),
            ("WITH_TOOLS",[weather],[tool]),("TOOL_CALL",[weather,call],[tool]),
            ("TOOL_RUN",[weather,call,m("tool","Manila: 31C, humid.")],[tool]),
            ("MULTI_TURN",[m("user","What is 2+2?"),m("assistant","Four."),m("user","And 3+3?")],[])]
        for (label,messages,tools) in cases { XCTAssertEqual(try CompiledLlama32Prompt.render(messages,tools:tools,date:date),refs[label],label) }
    }
    func testVerbatimHistoryAndDateKeepConversationPrefixStable() throws {
        let head=[m("system","  Cedar  "),m("user","  Hello  ")],answer="answer  \n"
        let first=try CompiledModelFamily.llama32.render(head,thinking:false,date:date)
        let later=try CompiledModelFamily.llama32.render(head+[m("assistant",answer),m("user","Continue")],thinking:true,date:date)
        XCTAssertTrue(later.hasPrefix(first+answer+"<|eot_id|>"))
        XCTAssertEqual(first.components(separatedBy:"<|begin_of_text|>").count-1,1)
        XCTAssertTrue(first.contains("Today Date: "+date));XCTAssertFalse(first.contains("<think>"))
        XCTAssertEqual(try CompiledModelFamily.llama32.render(head,thinking:true,date:date),first)
    }
    func testSchemaEscapesOrderNumbersAndEmptyContainersStayIntact() throws {
        let schema=#"{"z":{},"a":[],"n":1.00,"description":"say \"hi\", then: go","unicode":"café"}"#
        let offered=AgentToolDefinition(name:"x",description:"Search for \"café: météo\", quoted.",parametersJSON:schema)
        let rendered=try CompiledLlama32Prompt.render([m("user","Weather?")],tools:[offered],date:date)
        XCTAssertTrue(rendered.contains(#"say \"hi\", then: go"#));XCTAssertTrue(rendered.contains("\"n\": 1.00"))
        XCTAssertTrue(rendered.contains("\"z\": {}"));XCTAssertTrue(rendered.contains("\"a\": []"))
        XCTAssertLessThan(try XCTUnwrap(rendered.range(of:"\"z\"")) .lowerBound,try XCTUnwrap(rendered.range(of:"\"a\"")) .lowerBound)
        XCTAssertThrowsError(try CompiledLlama32Prompt.render([m("user","Hello")],tools:[AgentToolDefinition(name:"x",description:"x",parametersJSON:"[]")],date:date))
    }
    func testToolResultsAreQuotedAndFamilySelectionRefusesBaseAndVision() throws {
        let rendered=try CompiledLlama32Prompt.render([m("tool","Café \"Cedar\"\nline")],date:date)
        XCTAssertTrue(rendered.contains("<|start_header_id|>ipython<|end_header_id|>\n\n\"Café \\\"Cedar\\\"\\nline\"<|eot_id|>"))
        XCTAssertEqual(CompiledModelFamily.from(sourceModel:"meta-llama/Llama-3.2-1B-Instruct"),.llama32)
        XCTAssertEqual(CompiledModelFamily.from(sourceModel:"meta-llama/Llama-3.2-3B-Instruct"),.llama32)
        for s in ["meta-llama/Llama-3.2-1B","meta-llama/Llama-3.2-11B-Vision-Instruct","meta-llama/Llama-3.1-8B-Instruct"] { XCTAssertNil(CompiledModelFamily.from(sourceModel:s)) }
        XCTAssertTrue(CompiledModelFamily.llama32.supportsTools);XCTAssertFalse(CompiledModelFamily.llama32.supportsThinking)
        XCTAssertEqual(CompiledModelFamily.llama32.endOfTurnTokens,["<|eot_id|>","<|eom_id|>","<|end_of_text|>"])
        XCTAssertThrowsError(try CompiledLlama32Prompt.render([m("invented","x")],date:date))
    }
    func testDateUsesGregorianEnglishAndChosenLocalDay() {
        let value=Date(timeIntervalSince1970:1721953800)
        XCTAssertEqual(CompiledLlama32Prompt.today(value,timeZone:TimeZone(secondsFromGMT:0)!),"26 Jul 2024")
        XCTAssertEqual(CompiledLlama32Prompt.today(value,timeZone:TimeZone(secondsFromGMT:-3600)!),"25 Jul 2024")
    }
}
