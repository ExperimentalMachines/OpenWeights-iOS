import XCTest
import UIKit
import SafariServices
import CryptoKit
import OpenWeightsCore
@testable import OpenWeights

// SafariServices has no public JavaScript evaluation API. The fixture keeps the
// bundled renderer bytes and appends a read-only DOM probe in its existing nonce.
// It reports only to the already allowed entry URL, not a new server route.
private let safariViewerProbe = """
<script nonce="__OW_NONCE__">
(function(){
  var last = null;
  function measure(){
    if (!window.__ow) return;
    var stage = document.getElementById('stage');
    var rect = stage ? stage.getBoundingClientRect() : null;
    var pages = Array.from(document.querySelectorAll('.pagedjs_page'));
    var value = {
      renderer: window.__ow,
      text: stage ? stage.textContent : pages.map(function(p){return p.textContent}).join(' '),
      rawScript: typeof window.pwned,
      parentHidden: window.frameElement === null,
      viewport: {width: innerWidth, height: innerHeight},
      stageRect: rect ? {x:rect.x,y:rect.y,width:rect.width,height:rect.height} : null
    };
    var current = JSON.stringify(value);
    if (current === last) return;
    last = current;
    fetch('__OW_BASE__/' + '__OW_FILE__'.split('/').map(encodeURIComponent).join('/') + '?__ow_probe=' + encodeURIComponent(current)).catch(function(){});
  }
  setInterval(measure,150);
})();
</script>
"""

@MainActor private func safariViewerWait(_ condition: () -> Bool, seconds: Double = 20) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
private func viewerDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

extension ProductTests {
    @MainActor func testNativeSafariCanvasDocumentDeckLayoutAndLiveSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("safari-viewers-" + UUID().uuidString)
        let bundleRoot = root.appendingPathComponent("ViewerProbe.bundle")
        try FileManager.default.createDirectory(at: bundleRoot.appendingPathComponent("Canvas"), withIntermediateDirectories: true)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        let metadata = ["CFBundleIdentifier":"org.experimentalmachines.canvas.probe", "CFBundlePackageType":"BNDL", "CFBundleVersion":"1"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: bundleRoot.appendingPathComponent("Info.plist"))
        var assets: [String: Any] = [:]
        for name in CanvasHTTPSession.assetNames {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Canvas"))
            let original = try Data(contentsOf: url)
            var measured = original
            if name == "doc.html" || name == "deck.html" {
                let source = try XCTUnwrap(String(data: original, encoding: .utf8))
                XCTAssertEqual(source.components(separatedBy: "</body>").count, 2)
                let instrumented = source.replacingOccurrences(of: "</body>", with: safariViewerProbe + "\n</body>")
                XCTAssertEqual(instrumented.replacingOccurrences(of: safariViewerProbe + "\n", with: ""), source)
                measured = Data(instrumented.utf8)
            }
            assets[name] = ["signedSourceSHA256":viewerDigest(original), "testBundleSHA256":viewerDigest(measured), "probeAppended":measured != original]
            try measured.write(to: bundleRoot.appendingPathComponent("Canvas/" + name))
        }
        let bundle = try XCTUnwrap(Bundle(url: bundleRoot))
        let workspaceRoot = root.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try Workspace(root: workspaceRoot)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        var completed = false, evidence: [[String: Any]] = []
        defer {
            let value: [String: Any] = ["purpose":"native-Safari-Canvas-instrumented-document-deck-layout-live-save", "completed":completed, "viewers":evidence, "assets":assets, "probeSHA256":viewerDigest(Data(safariViewerProbe.utf8)), "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString, "limitations":["Actual SafariServices in a sandboxed iframe using test-bundle HTML with an appended read-only DOM probe. Removing the probe exactly recovers signed HTML. Renderer dependencies and production assets are unchanged.", "The probe uses the same allowed local entry URL. No new route, remote endpoint, native bridge, UI gesture or screenshot.", "This measures A4/deck DOM layout and live changes. It does not verify touch/swipe, toolbar interaction, VoiceOver, visual review or OS lifecycle."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Safari viewer layout evidence"; attachment.lifetime = .keepAlways; add(attachment)
        }
        for kind in [CanvasKind.document, .slides] {
            let entry = kind == .document ? "report.md" : "deck.md"
            let initial = kind == .document ? "# Cedar Report\n\nA short local document.\n\n<script>window.pwned=1</script>" : "# Cedar Deck\n\nFirst slide\n\n---\n\n# Second slide"
            let updated = kind == .document ? "# Cobalt Report\n\nThe complete saved revision.\n\n<script>window.pwned=1</script>" : "# Cobalt Deck\n\nFirst slide\n\n---\n\n# Second slide\n\n---\n\n# Third slide"
            try await workspace.write(entry, content: initial)
            var probes: [[String: Any]] = []
            var requests: [String] = []
            var stage = "starting"
            var initialObservation: [String: Any]?
            var updatedObservation: [String: Any]?
            let conditionsBefore = nativeDeviceConditions()
            let preview = CanvasSafariPreview(canvas: CanvasDescriptor(kind: kind, entry: entry), workspace: workspace)
            defer {
                evidence.append(["kind":kind.rawValue, "stage":stage, "initial":initialObservation ?? [:],
                                 "updated":updatedObservation ?? [:], "initialLoad":preview.initialLoad.map { $0 as Any } ?? NSNull(),
                                 "probeCount":probes.count, "partialProbes":probes, "innerRequests":requests,
                                 "conditionsBefore":conditionsBefore, "conditionsAfter":nativeDeviceConditions()])
            }
            let controller = try await preview.start(bundle: bundle, observeInnerRequest: { target in
                requests.append(target.components(separatedBy: "?").first ?? target)
                guard let raw = URLComponents(string: target)?.queryItems?.first(where: { $0.name == "__ow_probe" })?.value,
                      let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return }
                probes.append(value)
            })
            defer { preview.stop(); controller.dismiss(animated: false) }
            stage = "presenting"
            await withCheckedContinuation { continuation in presenter.present(controller, animated: false) { continuation.resume() } }
            stage = "waiting-for-initial-Cedar-probe"
            try await safariViewerWait { preview.initialLoad == true && probes.contains { ($0["text"] as? String)?.contains("Cedar") == true } }
            let before = try XCTUnwrap(probes.last { ($0["text"] as? String)?.contains("Cedar") == true })
            initialObservation = before
            stage = "checking-initial-layout"
            XCTAssertEqual(before["rawScript"] as? String, "undefined"); XCTAssertEqual(before["parentHidden"] as? Bool, true)
            let renderer = try XCTUnwrap(before["renderer"] as? [String: Any])
            if kind == .document {
                XCTAssertEqual(renderer["pages"] as? Int, 1)
                let size = try XCTUnwrap(renderer["pageSize"] as? [String: Int])
                XCTAssertEqual(size, ["width":794,"height":1123])
            } else {
                XCTAssertEqual(renderer["slides"] as? Int, 2)
                XCTAssertEqual(renderer["stage"] as? [String: Int], ["width":1280,"height":720])
                let rect = try XCTUnwrap(before["stageRect"] as? [String: Double]), viewport = try XCTUnwrap(before["viewport"] as? [String: Double])
                XCTAssertGreaterThan(rect["width"] ?? 0, 0)
                XCTAssertEqual((rect["width"] ?? 0) / (rect["height"] ?? 1), 16.0 / 9.0, accuracy: 0.01)
                XCTAssertGreaterThanOrEqual(rect["x"] ?? -1, -1); XCTAssertGreaterThanOrEqual(rect["y"] ?? -1, -1)
                XCTAssertLessThanOrEqual((rect["x"] ?? 0) + (rect["width"] ?? 0), (viewport["width"] ?? 0) + 1)
                XCTAssertLessThanOrEqual((rect["y"] ?? 0) + (rect["height"] ?? 0), (viewport["height"] ?? 0) + 1)
            }
            try await workspace.write(entry, content: updated, replace: true)
            stage = "waiting-for-saved-Cobalt-probe"
            try await safariViewerWait { probes.contains { ($0["text"] as? String)?.contains("Cobalt") == true && ((kind == .document && ($0["renderer"] as? [String: Any])?["pages"] as? Int == 1) || (kind == .slides && ($0["renderer"] as? [String: Any])?["slides"] as? Int == 3)) } }
            let after = try XCTUnwrap(probes.last { ($0["text"] as? String)?.contains("Cobalt") == true })
            updatedObservation = after
            XCTAssertEqual(after["rawScript"] as? String, "undefined")
            stage = "complete"
            preview.stop()
            await withCheckedContinuation { continuation in controller.dismiss(animated: false) { continuation.resume() } }
        }
        completed = evidence.count == 2 && evidence.allSatisfy { $0["stage"] as? String == "complete" }
    }
}
