import XCTest
@testable import OpenWeightsCore

final class CompiledSmolLM2PromptTests: XCTestCase {
    private func message(_ role: String, _ text: String) -> [String:String] { ["role":role,"content":text] }
    func testMatchesFourUpstreamGeneratedAndroidFixtures() throws {
        struct Reference: Decodable { let reference: [String:String] }
        let url=try XCTUnwrap(Bundle.module.url(forResource:"android-smollm2-prompt-reference",withExtension:"json",subdirectory:"Fixtures"))
        let reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:url)).reference
        let city=message("user","What is the capital of Japan?")
        let cases: [(String,[[String:String]])] = [
            ("PLAIN",[city]),("WITH_SYSTEM",[message("system","You are a terse assistant."),city]),
            ("MULTI_TURN",[message("user","What is 2+2?"),message("assistant","Four."),message("user","And 3+3?")]),
            ("SYSTEM_NOT_FIRST",[message("user","Hello."),message("system","Be brief from now on."),city])]
        for (name,messages) in cases { XCTAssertEqual(try CompiledSmolLM2Prompt.render(messages),reference[name],name) }
    }
    func testEmptySystemToolHistoryAndRawBytesArePreserved() throws {
        let messages=[message("system",""),message("user","é\nCedar"),message("assistant","  answer\n"),message("tool","raw result")]
        let expected="<|im_start|>system\n<|im_end|>\n<|im_start|>user\né\nCedar<|im_end|>\n<|im_start|>assistant\n  answer\n<|im_end|>\n<|im_start|>tool\nraw result<|im_end|>\n<|im_start|>assistant\n"
        XCTAssertEqual(try CompiledSmolLM2Prompt.render(messages),expected)
        XCTAssertFalse(expected.contains("<tool_response>"))
        XCTAssertThrowsError(try CompiledSmolLM2Prompt.render([message("invented","x")]))
    }
    func testFamilySelectionAndToolCapabilityDoNotGuessBaseOrOtherFamilies() {
        for size in ["135M","360M","1.7B"] { XCTAssertEqual(CompiledModelFamily.from(sourceModel:"HuggingFaceTB/SmolLM2-\(size)-Instruct"),.smollm2) }
        for source in ["HuggingFaceTB/SmolLM2-135M","HuggingFaceTB/SmolLM3-3B","HuggingFaceTB/SmolLM2-VL-135M-Instruct","smollm2",""] { XCTAssertNil(CompiledModelFamily.from(sourceModel:source)) }
        XCTAssertFalse(CompiledModelFamily.smollm2.supportsTools);XCTAssertFalse(CompiledModelFamily.smollm2.supportsThinking)
        XCTAssertTrue(CompiledModelFamily.qwen3.supportsTools);XCTAssertTrue(CompiledModelFamily.qwen25.supportsTools)
    }
    func testThinkingDoesNotInjectSeedAndEnabledToolsRefuse() throws {
        let messages=[message("user","Hello")], family=CompiledModelFamily.smollm2
        XCTAssertEqual(try family.render(messages,thinking:true),try family.render(messages,thinking:false))
        let tool=AgentToolDefinition(name:"read_memory",description:"Read",parametersJSON:"{}")
        XCTAssertThrowsError(try family.render(messages,tools:[tool],thinking:false))
    }
}
