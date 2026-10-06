import XCTest
import UIKit
import SwiftUI
import OpenWeightsCore
@testable import OpenWeights

extension ProductTests {
    @MainActor func testNativeMarkdownBlocksWideTableAndNoImageRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-transcript-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = try Workspace(root: root)
        try await workspace.write("site/receiver.html", content: "Owned image receiver")
        let receiver = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/receiver.html"), workspace: workspace)
        let url = try await receiver.start()
        defer { receiver.stop(); try? FileManager.default.removeItem(at: root) }
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let baseline = receiver.acceptedConnectionCount; XCTAssertGreaterThan(baseline, 0)
        let content = """
        # Cedar benchmark

        Prices remain **$5 and $10**. An _italic_ note, ~~old~~, and `**kwargs`.

        ```swift
        let project = "Cedar"
        let longLine = "This entire line must remain reachable when scrolled horizontally."
        ```

        | Model | Description | Recall |
        |:---|:---:|---:|
        | Cedar | Every word in this long description stays available without an ellipsis. | 3/3 |
        | Pine | Updated fact | 3/3 |

        - [x] Complete
        - [ ] Pending

        > Local results only.

        ![Owned image link](\(url.absoluteString))
        """
        let parsed = TranscriptMarkdown(content)
        var message = StoredMessage(role: .assistant, content: content); message.tokensPerSecond = 42; message.firstTextMilliseconds = 850
        var scrolls: [[String: Double]] = []
        let image = try await NativeMountedView.capture(MessageRow(message: message).padding(16).background(OWTheme.canvas).foregroundStyle(OWTheme.text), size: CGSize(width: 390, height: 1000), inspect: { view in
            let candidates = Self.transcriptScrollViews(view).filter { $0.contentSize.width > $0.bounds.width + 20 }
            XCTAssertGreaterThanOrEqual(candidates.count, 2, "Both long code and table must have reachable horizontal overflow")
            scrolls = candidates.map { ["viewportWidth": Double($0.bounds.width), "contentWidth": Double($0.contentSize.width)] }
        })
        let capture = XCTAttachment(image: image); capture.name = "Native Markdown blocks and scrollable table, dark"; capture.lifetime = .keepAlways; add(capture)
        XCTAssertEqual(receiver.acceptedConnectionCount, baseline)
        XCTAssertTrue(parsed.plainText.contains("Every word in this long description stays available without an ellipsis."))
        transcriptEvidence(["purpose":"native-markdown-message-row-wide-table-code-and-no-image-egress", "completed":true,
            "source":content, "plainText":parsed.plainText, "horizontalScrollViews":scrolls,
            "receiverPositiveConnections":baseline,"receiverAfterRendering":receiver.acceptedConnectionCount,
            "limitations":["Actual mounted MessageRow and native scroll sizing. No touch scrolling, link handoff, VoiceOver or inference-quality claim.","Owned loopback positive control establishes no image request to this fixture while rendering. It does not establish general network absence."]])
    }

    @MainActor func testNativeMarkdownClipboardAndStreamingLightDynamicType() async throws {
        let source = "## Cedar\n\n**A fact** and [guide](https://example.com/guide).\n\n```swift\nlet value = \"**literal**\"\nlast_line"
        let parsed = TranscriptMarkdown(source)
        let originalPasteboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = originalPasteboard }
        TranscriptCopy.copyMarkdown(source); XCTAssertEqual(UIPasteboard.general.string, source)
        await TranscriptCopy.copyPlainText(source); XCTAssertEqual(UIPasteboard.general.string, parsed.plainText)
        XCTAssertTrue(UIPasteboard.general.string?.contains("guide (https://example.com/guide)") == true)
        guard case .code(_, let code) = parsed.blocks.last else { return XCTFail("Streaming code missing") }
        TranscriptCopy.copyCode(code); XCTAssertEqual(UIPasteboard.general.string, code)
        XCTAssertTrue(code.hasSuffix("last_line\n")); XCTAssertTrue(code.contains("**literal**"))
        let image = try await NativeMountedView.capture(TranscriptMarkdownView(content: source).padding(16).background(OWTheme.canvas)
            .foregroundStyle(OWTheme.text).dynamicTypeSize(.accessibility3), size: CGSize(width:390,height:850), style: .light)
        let capture = XCTAttachment(image:image); capture.name = "Native incomplete fence, light accessibility text size";capture.lifetime = .keepAlways;add(capture)
        transcriptEvidence(["purpose":"native-markdown-source-plain-code-clipboard-and-streaming-light-dynamic-type","completed":true,
            "source":source,"plainText":parsed.plainText,"code":code,"dynamicType":"accessibility3","appearance":"light",
            "limitations":["Direct production copy helpers verify actual native pasteboard. Context-menu and code-button gestures remain unverified.","The incomplete streaming fragment is mounted as actual production view. Token cadence and VoiceOver navigation are not measured."]])
    }

    @MainActor private static func transcriptScrollViews(_ view:UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { transcriptScrollViews($0) }
    }
    private func transcriptEvidence(_ value:[String:Any]) {
        let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json")
        attachment.name = value["purpose"] as? String ?? "Transcript";attachment.lifetime = .keepAlways;add(attachment)
    }
}
