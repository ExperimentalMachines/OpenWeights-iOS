import XCTest
@testable import OpenWeightsCore

final class SpeechTextTests: XCTestCase {
    func testSpeechAnnouncesCompleteAndIncompleteCodeWithoutReadingIt() {
        for source in ["Try this:\n```swift\nlet privateValue = 1\n```\nThat is all.", "Try this:\n~~~python\nprivate_value = 1"] {
            let speech = TranscriptMarkdown(source).speechText
            XCTAssertTrue(speech.contains("code sample")); XCTAssertFalse(speech.contains("private"))
        }
    }
    func testSpeechKeepsInlineWordsAndLabelsWithoutLinkAddressesOrMarkdownMarks() {
        let value = TranscriptMarkdown("# Results\n\n- **First** `loadModel`\n- [the docs](https://example.com/a/b) and ![plot](https://example.com/x.png)\n\n[unsafe](javascript:alert)")
        XCTAssertEqual(value.speechText, "Results\nFirst loadModel\nthe docs and plot\nunsafe")
        XCTAssertFalse(value.speechText.contains("https")); XCTAssertFalse(value.speechText.contains("javascript"))
        XCTAssertTrue(value.plainText.contains("https://example.com/a/b"))
        XCTAssertTrue(value.plainText.contains("javascript:alert"))
    }
    func testPlainProseAndTableValuesArePreservedForSpeech() {
        let prose = "The KV cache stores keys and values for previous tokens."
        XCTAssertEqual(TranscriptMarkdown(prose).speechText, prose)
        let table = TranscriptMarkdown("| Model | Recall |\n|---|---|\n| Cedar | 3/3 |")
        XCTAssertEqual(table.speechText, "Model, Recall\nCedar, 3/3")
        XCTAssertEqual(TranscriptMarkdown("<script>ignore_me()</script>").speechText, "(code sample)")
    }
    func testLongSpeechFragmentsPreserveEveryScalarWithinBoundedUtterances() {
        for text in ["", String(repeating: "Cedar ", count: 1500), String(repeating: "🧠é ", count: 2000), "a\u{301}b🧠c"] {
            for limit in [2, 7, 4000] {
                let fragments = SpeechText.fragments(text, maximumUTF16: limit)
                XCTAssertEqual(fragments.joined(), text)
                XCTAssertTrue(fragments.allSatisfy { !$0.isEmpty && $0.utf16.count <= limit })
            }
        }
    }
}
