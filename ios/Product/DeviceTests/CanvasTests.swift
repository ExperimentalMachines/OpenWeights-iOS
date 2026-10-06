import XCTest
import UIKit
import WebKit
import OpenWeightsCore
@testable import OpenWeights

@MainActor private func canvasWait(_ condition: () async throws -> Bool, seconds: Double = 12) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while try await !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
private func canvasAttach(_ value: [String: Any], test: XCTestCase) {
    let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    attachment.name = value["purpose"] as? String ?? "Canvas evidence"; attachment.lifetime = .keepAlways; test.add(attachment)
}

extension ProductTests {
    func testNativeCanvasWebsiteAssetsEgressAndSessionClosure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-canvas-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root), receiver = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/receiver.html"), workspace: workspace)
        try await workspace.write("site/receiver.html", content: "<html>Owned receiver</html>")
        let receiverURL = try await receiver.start()
        let (_, positiveResponse) = try await URLSession.shared.data(from: receiverURL); XCTAssertEqual((positiveResponse as? HTTPURLResponse)?.statusCode, 200)
        let before = receiver.acceptedConnectionCount
        let html = "<html><head><link rel='stylesheet' href='style.css'></head><body><div id='result'>Cedar</div><script src='app.js'></script><img src='\(receiverURL.absoluteString)'><script>fetch('\(receiverURL.absoluteString)').catch(()=>{});</script></body></html>"
        try await workspace.write("site/index.html", content: html)
        try await workspace.write("site/style.css", content: "#result { color: rgb(1,2,3); }")
        try await workspace.write("site/app.js", content: "document.getElementById('result').textContent='Cobalt';")
        try await workspace.write("private.txt", content: "PRIVATE SIBLING")
        let server = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/index.html"), workspace: workspace), browser = CanvasBrowser()
        var completed = false; var observations: [String: Any] = [:]
        defer { browser.close(); server.stop(); receiver.stop(); canvasAttach(["purpose": "native-canvas-website-local-assets-egress-session-closure", "completed": completed, "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["Programmatic WebKit and owned loopback receiver. No external network requests or Safari app switching. No touch navigation or screenshot review."]], test: self) }
        let url = try await server.start(); try await browser.load(url)
        try await canvasWait { browser.loaded }
        let text = try await browser.web.evaluateJavaScript("document.getElementById('result').textContent") as? String
        let color = try await browser.web.evaluateJavaScript("getComputedStyle(document.getElementById('result')).color") as? String
        XCTAssertEqual(text, "Cobalt"); XCTAssertEqual(color, "rgb(1, 2, 3)")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(receiver.acceptedConnectionCount, before); XCTAssertTrue(browser.report.blocked.contains("127.0.0.1:" + String(receiver.port!)))
        let siblingURL = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("private.txt")
        let (_, siblingResponse) = try await URLSession.shared.data(from: siblingURL); XCTAssertEqual((siblingResponse as? HTTPURLResponse)?.statusCode, 404)
        try await workspace.write("site/index.html", content: "<html><body>Cedar updated</body></html>", replace: true)
        browser.reload(); try await canvasWait { (try? await browser.web.evaluateJavaScript("document.body.textContent")) as? String == "Cedar updated" }
        server.stop()
        var closed = false
        do { let (_, reply) = try await URLSession.shared.data(from: url); closed = (reply as? HTTPURLResponse)?.statusCode != 200 } catch { closed = true }
        XCTAssertTrue(closed)
        observations = ["renderedText": text ?? "", "renderedColor": color ?? "", "ownedReceiverPositiveControlConnections": before, "ownedReceiverConnectionsAfterRemoteAttempts": receiver.acceptedConnectionCount, "blocked": browser.report.blocked, "siblingStatus": (siblingResponse as? HTTPURLResponse)?.statusCode ?? 0, "closedURLRefused": closed]
        completed = text == "Cobalt" && color == "rgb(1, 2, 3)" && before > 0 && receiver.acceptedConnectionCount == before && closed
    }

    func testNativeCanvasDocumentPaginationSlidesAndLiveRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-viewers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        try await workspace.write("report.md", content: "# Cedar Report\n\nDocument body.\n<script>window.pwned='bad'</script><img src=x onerror=\"window.pwned='bad'\">")
        try await workspace.write("slides.md", content: "# Cedar\n\nFirst slide.\n\n---\n\n# Cobalt\n\nSecond slide.")
        let doc = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .document, entry: "report.md"), workspace: workspace), deck = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .slides, entry: "slides.md"), workspace: workspace)
        let documentBrowser = CanvasBrowser(), deckBrowser = CanvasBrowser()
        // Paged.js awaits animation frames. WebKit suspends those in a detached
        // view, so the rendering fixture uses the host scene as the product does.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        documentBrowser.web.frame = window.bounds; deckBrowser.web.frame = window.bounds
        window.addSubview(documentBrowser.web)
        defer { documentBrowser.web.removeFromSuperview(); deckBrowser.web.removeFromSuperview() }
        var completed = false; var observations: [String: Any] = [:]
        defer { documentBrowser.close(); deckBrowser.close(); doc.stop(); deck.stop(); canvasAttach(["purpose": "native-canvas-A4-slides-untrusted-markdown-live-update", "completed": completed, "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["DOM/layout measurements in actual WebKit. No touch/swipe, accessibility or visual screenshot verification. No general Markdown compatibility claim."]], test: self) }
        let docURL = try await doc.start(); try await documentBrowser.load(docURL)
        try await canvasWait {
            observations["documentDuringPagination"] = (try? await documentBrowser.web.evaluateJavaScript("JSON.stringify({state:window.__ow,viewport:{width:innerWidth,height:innerHeight},plain:document.getElementById('plain').textContent,body:document.body.innerText.slice(0,1000),pageCount:document.querySelectorAll('.pagedjs_page').length})")) as? String ?? ""
            observations["documentErrors"] = documentBrowser.report.errors
            observations["documentMissing"] = documentBrowser.report.missing
            observations["documentBlocked"] = documentBrowser.report.blocked
            return (try? await documentBrowser.web.evaluateJavaScript("window.__ow && window.__ow.pages > 0")) as? Bool == true
        }
        let pagination = try await documentBrowser.web.evaluateJavaScript("window.__ow") as? [String: Any]
        let size = pagination?["pageSize"] as? [String: Any], width = size?["width"] as? Double, height = size?["height"] as? Double
        XCTAssertEqual(width ?? 0, 794, accuracy: 3); XCTAssertEqual(height ?? 0, 1123, accuracy: 3)
        let attacked = try await documentBrowser.web.evaluateJavaScript("typeof window.pwned") as? String; XCTAssertEqual(attacked, "undefined")
        try await workspace.write("report.md", content: "# Cobalt Report\n\nUpdated live.", replace: true)
        try await canvasWait { (try? await documentBrowser.web.evaluateJavaScript("document.body.textContent.includes('Cobalt Report')")) as? Bool == true }
        documentBrowser.web.removeFromSuperview(); window.addSubview(deckBrowser.web)
        let deckURL = try await deck.start(); try await deckBrowser.load(deckURL)
        try await canvasWait { (try? await deckBrowser.web.evaluateJavaScript("window.__ow && window.__ow.slides === 2")) as? Bool == true }
        let slides = try await deckBrowser.web.evaluateJavaScript("window.__ow") as? [String: Any]
        let stage = slides?["stage"] as? [String: Any]
        XCTAssertEqual(stage?["width"] as? Int, 1280); XCTAssertEqual(stage?["height"] as? Int, 720)
        try await workspace.write("slides.md", content: "# Updated Cedar\n\n---\n\n# Cobalt\n\n---\n\n# Third slide", replace: true)
        try await canvasWait { (try? await deckBrowser.web.evaluateJavaScript("window.__ow && window.__ow.slides === 3")) as? Bool == true }
        observations = ["pagination": pagination ?? [:], "deckBefore": slides ?? [:], "rawMarkdownScriptResult": attacked ?? "", "documentLiveUpdateObserved": true, "slideCountAfterUpdate": 3]
        completed = abs((width ?? 0) - 794) < 3 && abs((height ?? 0) - 1123) < 3 && attacked == "undefined" && (slides?["slides"] as? Int) == 2
    }

    func testNativeCanvasPageGradingReportsTypoAndMissingAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-grade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        try await workspace.write("site/index.html", content: "<html><head><link rel='stylesheet' href='missing.css'></head><body><script>console.error('Controlled Cedar typo');throw new Error('Controlled Cobalt exception');</script></body></html>")
        let report = await CanvasPageChecker.check(CanvasDescriptor(kind: .site, entry: "site/index.html"), workspace: workspace)
        let errors = report?.errors ?? [], missing = report?.missing ?? []
        XCTAssertTrue(errors.contains { $0.contains("Controlled Cedar typo") }); XCTAssertTrue(errors.contains { $0.contains("Controlled Cobalt exception") }); XCTAssertTrue(missing.contains("missing.css"))
        canvasAttach(["purpose": "native-canvas-page-grading-errors-and-missing-resource", "completed": errors.contains { $0.contains("Controlled Cedar typo") } && errors.contains { $0.contains("Controlled Cobalt exception") } && missing.contains("missing.css"), "errors": errors, "missing": missing, "verdict": report?.verdict ?? "", "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["Owned malformed fixture in a real hidden WebKit instance. No claim that all site defects can be diagnosed."]], test: self)
    }

    func testNativeCanvasCutOffSaveWarnsDespiteCleanBrowserAndRepairClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-cutoff-" + UUID().uuidString)
        let suite = "openweights.cutoff." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Shared/site"), withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try Data("<html><body>Cedar</body></html>".utf8).write(to: root.appendingPathComponent("Shared/site/index.html"))
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await files.choose(root.appendingPathComponent("Shared")); XCTAssertNil(files.error)
        files.canvasEnabled = ["show_website"]; files.enabled = ["write_file"]
        var browserVerdicts: [String] = []
        files.pageChecker = { canvas, workspace in
            let report = await CanvasPageChecker.check(canvas, workspace: workspace)
            browserVerdicts.append(report?.verdict ?? "clean")
            return report
        }
        let grant = files.grantID
        let show = AgentToolCall(id: "show", name: "show_website", argumentsJSON: "{\"path\":\"site/index.html\"}")
        let opened = await files.execute(show, approval: nil, expectedGrantID: grant); XCTAssertFalse(opened.rejected)
        let cut = AgentToolCall(id: "cut", name: "write_file", argumentsJSON: "{\"path\":\"site/index.html\",\"content\":\"<html><body><h1>Cobalt\",\"replace\":true}")
        let warning = await files.execute(cut, approval: ApprovedToolCall(displayedCall: cut), expectedGrantID: grant)
        XCTAssertFalse(warning.rejected); XCTAssertTrue(warning.text.contains("looks cut off")); XCTAssertTrue(warning.untrustedText && warning.privateDataRead)
        let repair = AgentToolCall(id: "repair", name: "write_file", argumentsJSON: "{\"path\":\"site/index.html\",\"content\":\"<html><body><h1>Cobalt</h1></body></html>\",\"replace\":true}")
        let repaired = await files.execute(repair, approval: ApprovedToolCall(displayedCall: repair), expectedGrantID: grant)
        XCTAssertFalse(repaired.rejected); XCTAssertFalse(repaired.text.contains("looks cut off")); XCTAssertEqual(files.canvas?.revision, 2)
        XCTAssertEqual(browserVerdicts, ["clean", "clean", "clean"])
        let completed = !warning.rejected && warning.text.contains("looks cut off") && warning.untrustedText && warning.privateDataRead && !repaired.rejected && !repaired.text.contains("looks cut off") && browserVerdicts == ["clean", "clean", "clean"] && files.canvas?.revision == 2
        canvasAttach(["purpose": "native-canvas-cutoff-save-clean-browser-and-repair", "completed": completed, "browserVerdicts": browserVerdicts, "warning": warning.text, "repair": repaired.text, "revision": files.canvas?.revision ?? -1, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["Programmatic controller writes with exact approval and actual WebKit checks. This does not verify model-authored site creation or UI gestures."]], test: self)
        await files.revoke()
    }

    func testNativeModelGeneratedCanvasAskRoundTrip() async throws {
        let pinned = try NativeAgentArtifact.selected()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-model-canvas-" + UUID().uuidString), suite = "openweights.canvas." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.removePersistentDomain(forName: suite); UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Shared/site"), withIntermediateDirectories: true)
        try Data("<html><body><h1>Cedar Canvas</h1></body></html>".utf8).write(to: root.appendingPathComponent("Shared/site/index.html"))
        let downloads = ModelDownloads(root: root.appendingPathComponent("Models"), library: try ModelLibrary(file: root.appendingPathComponent("models.json")), sessionIdentifier: suite)
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults); await files.choose(root.appendingPathComponent("Shared")); files.canvasEnabled = ["show_website"]; files.mode = .ask
        var gradeCompleted = false
        files.pageChecker = { canvas, workspace in
            let result = await CanvasPageChecker.check(canvas, workspace: workspace); gradeCompleted = result != nil; return result
        }
        let observed = NativeObservedRuntime(LlamaRuntime(gpuLayers: 99))
        let chat = ChatController(store: try ConversationStore(file: root.appendingPathComponent("conversations.json")), downloads: downloads, files: files, defaults: defaults, runtimeFactory: { _ in observed })
        var completed = false; var result: [String: Any] = [:]
        defer { chat.cancel(); canvasAttach(["purpose": "native-model-generated-canvas-exact-ask-approval", "completed": completed, "observations": result, "runtimeTrace": observed.snapshot(), "artifact": NativeAgentArtifact.evidence(pinned), "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["One pinned greedy 1.7B Metal model opening a prepared local website through Ask mode. Programmatic controller approval and WebKit grading. No model-authored site generation, touch navigation or general agent-quality claim."]], test: self) }
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models/gguf/" + (try XCTUnwrap(pinned.revision)) + "/" + pinned.entryFile)
        try ModelDownloads.verify(source, file: try XCTUnwrap(pinned.files.first)); await downloads.importGGUF(source)
        var model = try XCTUnwrap(downloads.models.first); model.settings.temperature = 0; model.settings.topP = 1; model.settings.repeatPenalty = 1; model.settings.outputTokens = 192; model.settings.thinking = false
        try await downloads.save(model); await chat.load(model); XCTAssertNil(chat.error)
        chat.draft = "Use show_website to open the saved HTML file site/index.html for me. Do not ask a question. After it opens, tell me it is shown."; await chat.send()
        try await canvasWait({ chat.pendingToolApproval != nil || !chat.busy }, seconds: 90)
        let approval = try XCTUnwrap(chat.pendingToolApproval)
        XCTAssertEqual(approval.displayedCall.name, "show_website"); XCTAssertNil(files.canvas)
        chat.answerToolApproval(approved: true)
        try await canvasWait({ !chat.busy }, seconds: 90)
        let tool = chat.current?.messages.first { $0.toolName == "show_website" }
        XCTAssertEqual(files.canvas?.entry, "site/index.html"); XCTAssertEqual(tool?.status, .complete); XCTAssertEqual(tool?.toolPrivateDataRead, true); XCTAssertNil(chat.error); XCTAssertTrue(gradeCompleted)
        result = ["displayedCall": approval.displayedCall.argumentsJSON, "canvasEntry": files.canvas?.entry ?? "", "toolResult": tool?.content ?? "", "finalReply": chat.current?.messages.last?.content ?? "", "error": chat.error ?? "", "realWebKitGradingCompleted": gradeCompleted]
        completed = files.canvas?.entry == "site/index.html" && tool?.status == .complete && tool?.toolPrivateDataRead == true && chat.error == nil && gradeCompleted
    }
}
