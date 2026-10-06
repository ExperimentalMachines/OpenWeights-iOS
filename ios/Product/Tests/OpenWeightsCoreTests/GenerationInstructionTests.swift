import XCTest
@testable import OpenWeightsCore

final class GenerationInstructionTests: XCTestCase {
    func testUnsetOrBlankFieldsPreserveLegacyPromptBytes() {
        var settings = ModelSettings()
        let base = "You are OpenWeights.\nCafé 🪶"
        for tools in [false, true] {
            XCTAssertEqual(Data(settings.systemInstructions(base:base,toolsAvailable:tools).utf8),Data(base.utf8))
        }
        settings.systemPrompt = " \n\t"; settings.toolPrompt = "\n "
        XCTAssertEqual(settings.systemInstructions(base:base,toolsAvailable:true),base)
    }
    func testLengthInstructionsMatchFrozenAndroidContract() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource:"android-answer-length",withExtension:"json",subdirectory:"Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        let instructions = try XCTUnwrap(fixture["instructions"] as? [String:String])
        for length in AnswerLength.allCases {
            XCTAssertEqual(length.instruction,instructions[length.rawValue])
            var settings = ModelSettings(); settings.answerLength = length
            XCTAssertEqual(settings.systemInstructions(base:"base",toolsAvailable:false),"base\n\n" + length.instruction)
        }
    }
    func testLiteralUnicodeInstructionsStayStableAndToolTextIsAvailabilityGated() {
        var settings = ModelSettings()
        let literal = "  Standing instruction: café e\u{301} 🪶\nKeep this second line.  "
        settings.systemPrompt = literal; settings.toolPrompt = "Use only checked references."
        let ordinary = settings.systemInstructions(base:"base",toolsAvailable:false)
        XCTAssertEqual(ordinary,"base\n\n" + literal)
        let withTools = settings.systemInstructions(base:"base",toolsAvailable:true)
        XCTAssertEqual(withTools,ordinary + "\n\nUse only checked references.")
        XCTAssertEqual(withTools,settings.systemInstructions(base:"base",toolsAvailable:true))
    }
    func testOldJSONAndUnknownEnumValuesRemainReadable() throws {
        let legacy = Data(#"{"contextTokens":2048,"outputTokens":512,"threads":4,"temperature":0.7,"topP":0.95,"repeatPenalty":1.1,"thinking":false}"#.utf8)
        let settings = try JSONDecoder().decode(ModelSettings.self,from:legacy)
        XCTAssertNil(settings.reasoningEffort); XCTAssertNil(settings.answerLength)
        XCTAssertNil(settings.systemPrompt); XCTAssertNil(settings.toolPrompt)
        XCTAssertEqual(settings,ModelSettings())
        XCTAssertEqual(try JSONDecoder().decode(ReasoningEffort.self,from:Data(#""future-value""#.utf8)),.default)
        XCTAssertEqual(try JSONDecoder().decode(AnswerLength.self,from:Data(#""future-value""#.utf8)),.balanced)
        XCTAssertEqual(ReasoningEffort.default.wireValue,"")
        XCTAssertEqual(ReasoningEffort.low.wireValue,"low")
    }
    func testInstructionPreferencesShareReopenAndResetWithoutResurrectingOldValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("models.json"), library = try ModelLibrary(file:file)
        var a = LocalModel(name:"A",backend:.llamaCPU,entryFile:"a.gguf",files:[])
        var b = LocalModel(name:"B",backend:.llamaMetal,entryFile:"b.gguf",files:[])
        b.settings.contextTokens = 4096; b.settings.threads = 2; b.settings.systemPrompt = "Legacy B instruction"
        try await library.save(a); try await library.save(b)
        a.settings.systemPrompt = "Use Cedar."; a.settings.toolPrompt = "Check files."
        a.settings.answerLength = .brief; a.settings.reasoningEffort = .low
        try await library.saveSettings(a)
        let reopened = try ModelLibrary(file:file), before = await reopened.list()
        let savedB = try XCTUnwrap(before.first { $0.id == b.id })
        XCTAssertEqual(savedB.settings.systemPrompt,"Use Cedar."); XCTAssertEqual(savedB.settings.toolPrompt,"Check files.")
        XCTAssertEqual(savedB.settings.answerLength,.brief); XCTAssertEqual(savedB.settings.reasoningEffort,.low)
        XCTAssertEqual(savedB.settings.contextTokens,4096); XCTAssertEqual(savedB.settings.threads,2)
        a.settings = ModelSettings(); try await reopened.saveSettings(a)
        // A stale metadata save must not revive the pre-shared instruction record.
        try await reopened.save(b)
        let final = try ModelLibrary(file:file), after = await final.list()
        let resetB = try XCTUnwrap(after.first { $0.id == b.id })
        XCTAssertNil(resetB.settings.systemPrompt); XCTAssertNil(resetB.settings.toolPrompt)
        XCTAssertNil(resetB.settings.answerLength); XCTAssertNil(resetB.settings.reasoningEffort)
        XCTAssertEqual(resetB.settings.contextTokens,4096); XCTAssertEqual(resetB.backend,.llamaMetal)
    }
    func testAnswerLengthDoesNotChangeTheUserOutputCeiling() throws {
        var settings = ModelSettings(); settings.outputTokens = 128
        for length in AnswerLength.allCases {
            settings.answerLength = length
            _ = settings.systemInstructions(base:"base",toolsAvailable:false)
            try settings.validate(for:.llamaCPU)
            XCTAssertEqual(settings.outputTokens,128)
        }
    }
}
