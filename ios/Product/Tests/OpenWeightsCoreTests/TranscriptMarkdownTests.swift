import XCTest
@testable import OpenWeightsCore

final class TranscriptMarkdownTests: XCTestCase {
    func testBlockAndNestedInlineStructurePreservesPriceProseAndHTMLAsText() throws {
        let value = TranscriptMarkdown("# Cedar\n\nIt costs $5 and $10. **Strong _nested_** and ~~old~~ and `**kwargs`.\n\n> Quoted\n\n<script>alert('inert')</script>")
        guard case .heading(1, let title) = value.blocks[0], case .paragraph(let spans) = value.blocks[1],
              case .quote = value.blocks[2], case .literal(let html) = value.blocks[3] else { return XCTFail("Missing block structure") }
        XCTAssertEqual(title.map(\.text).joined(), "Cedar")
        XCTAssertTrue(spans.contains { $0.text == "nested" && $0.bold && $0.italic })
        XCTAssertTrue(spans.contains { $0.text == "old" && $0.strike })
        XCTAssertTrue(spans.contains { $0.text == "**kwargs" && $0.code && !$0.bold })
        XCTAssertTrue(value.plainText.contains("$5 and $10")); XCTAssertTrue(html.contains("<script>"))
    }
    func testIncompleteStreamingFencesKeepLastLineAndLiteralImageAndCheckboxSyntax() throws {
        let source = "Before\n\n```swift\nlet value = 5\n![literal](https://example.com/x)\n- [ ] literal\nlast_line"
        let value = TranscriptMarkdown(source)
        guard case .code(let language, let text) = value.blocks.last else { return XCTFail("No streaming code block") }
        XCTAssertEqual(language, "swift"); XCTAssertTrue(text.hasSuffix("last_line\n"))
        XCTAssertTrue(text.contains("![literal]")); XCTAssertTrue(text.contains("- [ ] literal"))
        XCTAssertEqual(value.source, source)
        let closed = TranscriptMarkdown(source + "\n```")
        XCTAssertEqual(closed.blocks, value.blocks)
    }
    func testFenceLengthIndentedCodeAndTildeFenceAreParsedWithoutEditingCode() throws {
        let value = TranscriptMarkdown("````text\n``` is literal\n````\n\n~~~python\nprint('$5')\n~~~\n\n    **literal**\n    last")
        XCTAssertEqual(value.blocks, [.code(language: "text", text: "``` is literal\n"), .code(language: "python", text: "print('$5')\n"), .code(language: nil, text: "**literal**\nlast\n")])
    }
    func testTaskListsNestedListsAndOrderedStartAreRetained() throws {
        let value = TranscriptMarkdown("- [x] Finished\n- [ ] Pending\n  - Nested\n\n7. Seven\n8. Eight")
        guard case .list(start: nil, let tasks) = value.blocks[0], case .list(let start, let numbers) = value.blocks[1] else { return XCTFail("Lists missing") }
        XCTAssertEqual(tasks.map(\.checked), [true, false]); XCTAssertEqual(start, 7); XCTAssertEqual(numbers.count, 2)
        XCTAssertTrue(value.plainText.contains("☑ Finished")); XCTAssertTrue(value.plainText.contains("☐ Pending"))
        XCTAssertTrue(value.plainText.contains("• Nested")); XCTAssertTrue(value.plainText.contains("7. Seven"))
    }
    func testTableEscapedPipesEmptyCellsAlignmentAndLongRowsAreNotLost() throws {
        let source = "| Model | Note | Value |\n|:---|:---:|---:|\n| Cedar | A \\| B | 42 |\n| Pine | | " + String(repeating: "long ", count: 50) + " |"
        let value = TranscriptMarkdown(source)
        guard case .table(let table) = value.blocks[0] else { return XCTFail("No table") }
        XCTAssertEqual(table.header.count, 3); XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.alignments, [.left, .center, .right]); XCTAssertEqual(table.rows[0][1].map(\.text).joined(), "A | B")
        XCTAssertEqual(table.rows[1][1], []); XCTAssertEqual(table.rows[1][2].map(\.text).joined(), String(repeating: "long ", count: 50).trimmingCharacters(in: .whitespaces))
        XCTAssertTrue(value.plainText.contains("Cedar | A | B | 42"))
    }
    func testRemoteImagesAndReferenceLinksRemainTextAndNeverBecomeResourceLoads() throws {
        let value = TranscriptMarkdown("![Cedar plot](https://example.com/plot.png)\n\n[**Documentation** link][guide]\n\n[guide]: https://example.com/docs")
        guard case .paragraph(let image) = value.blocks[0], case .paragraph(let link) = value.blocks[1] else { return XCTFail("No inline links") }
        XCTAssertEqual(image.count, 1); XCTAssertEqual(image[0].text, "Cedar plot"); XCTAssertEqual(image[0].link?.absoluteString, "https://example.com/plot.png")
        XCTAssertTrue(link.first?.bold == true)
        XCTAssertEqual(value.plainText, "Cedar plot (https://example.com/plot.png)\n\nDocumentation link (https://example.com/docs)")
    }
    func testUnsupportedSchemesAndCredentialsAreInertWithAddressesPreserved() throws {
        for address in ["javascript:alert", "file:///private/a", "data:text/html,hello", "https://user:secret@example.com/path", "relative/path"] {
            XCTAssertNil(TranscriptMarkdown.browsableURL(address))
            let value = TranscriptMarkdown("[label](" + address + ")")
            guard case .paragraph(let spans) = value.blocks[0] else { return XCTFail("No paragraph") }
            XCTAssertTrue(spans.allSatisfy { $0.link == nil }); XCTAssertTrue(value.plainText.contains(address))
        }
        XCTAssertNotNil(TranscriptMarkdown.browsableURL("https://example.com/path"))
    }
    func testBlankAndGrowingStreamingRepliesKeepSourceAndFinalCode() throws {
        XCTAssertEqual(TranscriptMarkdown("").blocks, [])
        let source = "## Answer\n\n```swift\nlet cedar = 42\n```"
        for length in 0...source.count {
            let fragment = String(source.prefix(length)), value = TranscriptMarkdown(fragment)
            XCTAssertEqual(value.source, fragment)
            if fragment.contains("let cedar = 42") { XCTAssertTrue(value.plainText.contains("let cedar = 42")) }
        }
    }
}
