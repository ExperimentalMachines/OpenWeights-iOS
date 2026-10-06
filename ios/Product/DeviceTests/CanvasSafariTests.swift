import XCTest
import UIKit
import SafariServices
import OpenWeightsCore
@testable import OpenWeights

@MainActor private final class CanvasSafariObservation: NSObject, SFSafariViewControllerDelegate {
    private(set) var initialLoad: Bool?
    private(set) var redirects: [String] = []
    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) { initialLoad = didLoadSuccessfully }
    func safariViewController(_ controller: SFSafariViewController, initialLoadDidRedirectTo url: URL) { redirects.append(url.absoluteString) }
}

extension ProductTests {
    func testNativeCanvasSafariCandidateNavigationControl() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-canvas-safari-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site"), withIntermediateDirectories: true)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        try await workspace.write("site/receiver.html", content: "<html><body>Owned receiver positive control</body></html>")
        try await workspace.write("site/loaded.txt", content: "Owned page execution marker")
        var receiverRequests: [String] = [], previewRequests: [String] = []
        let receiver = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/receiver.html"), workspace: workspace, observeRequest: { receiverRequests.append($0) })
        let receiverURL = try await receiver.start()
        let (_, positive) = try await URLSession.shared.data(from: receiverURL)
        XCTAssertEqual((positive as? HTTPURLResponse)?.statusCode, 200)
        let positiveCount = receiver.acceptedConnectionCount
        let html = "<html><head><meta name='viewport' content='width=device-width'></head><body><h1>Cedar Safari candidate</h1><script>setTimeout(()=>fetch('loaded.txt?state=Cobalt'),300);setTimeout(()=>{fetch('\(receiverURL.absoluteString)').catch(()=>{});let i=new Image();i.src='\(receiverURL.absoluteString)';},800);setTimeout(()=>{location.href='\(receiverURL.absoluteString)';},1800);</script></body></html>"
        try await workspace.write("site/index.html", content: html)
        let preview = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/index.html"), workspace: workspace, observeRequest: { previewRequests.append($0) })
        let url = try await preview.start()
        let observation = CanvasSafariObservation(), safari = SFSafariViewController(url: url)
        safari.delegate = observation; safari.modalPresentationStyle = .fullScreen
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }), presenter = try XCTUnwrap(window.rootViewController)
        var measured = false
        defer {
            safari.dismiss(animated: false); preview.stop(); receiver.stop()
            let value: [String: Any] = ["purpose": "native-canvas-Safari-candidate-controlled-navigation", "completed": measured, "safariInitialLoad": observation.initialLoad ?? false, "sameOriginScriptMarkerObserved": previewRequests.contains { $0.contains("loaded.txt?state=Cobalt") }, "receiverPositiveControlConnections": positiveCount, "receiverConnectionsAfterPageAttempts": receiver.acceptedConnectionCount, "previewRequests": previewRequests, "receiverRequests": receiverRequests, "observedRedirects": observation.redirects, "applicationState": UIApplication.shared.applicationState.rawValue, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["Experimental SafariServices candidate, not enabled in the product or approved as a parity alternative.", "Only owned loopback endpoints are used. No internet receiver, external Safari app switch, UI gesture or general Safari privacy claim.", "Passing this diagnostic means the controlled measurement executed. It does not mean Safari prevented off-origin navigation."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Safari Canvas candidate"; attachment.lifetime = .keepAlways; add(attachment)
        }
        await withCheckedContinuation { continuation in presenter.present(safari, animated: false) { continuation.resume() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while observation.initialLoad == nil || !previewRequests.contains(where: { $0.contains("loaded.txt?state=Cobalt") }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(observation.initialLoad == true); XCTAssertGreaterThan(positiveCount, 0)
        try await Task.sleep(for: .seconds(4))
        measured = observation.initialLoad == true && previewRequests.contains { $0.contains("loaded.txt?state=Cobalt") }
        XCTAssertTrue(measured)
    }
}

extension ProductTests {
    func testNativeCanvasIsolatedSafariBlocksNavigationKeepsLocalStorageAndCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-isolated-safari-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site"), withIntermediateDirectories: true)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root)
        try await workspace.write("site/receiver.html", content: "<html>Owned navigation receiver</html>")
        try await workspace.write("site/loaded.txt", content: "Owned execution marker")
        let receiver = try CanvasLocalServer(canvas: CanvasDescriptor(kind: .site, entry: "site/receiver.html"), workspace: workspace)
        let receiverURL = try await receiver.start(); let (_, positive) = try await URLSession.shared.data(from: receiverURL)
        XCTAssertEqual((positive as? HTTPURLResponse)?.statusCode, 200); let before = receiver.acceptedConnectionCount
        let script = "let denied=false;try{parent.document.body.textContent='ESCAPED'}catch(e){denied=true}localStorage.setItem('canvas-test','Cobalt');document.getElementById('result').textContent=localStorage.getItem('canvas-test');fetch('loaded.txt?state='+document.getElementById('result').textContent+'&parentDenied='+denied+'&frameHidden='+(frameElement===null));setTimeout(()=>{fetch('\(receiverURL.absoluteString)').catch(()=>{});new Image().src='\(receiverURL.absoluteString)';window.open('\(receiverURL.absoluteString)');try{top.location.href='\(receiverURL.absoluteString)'}catch(e){}try{parent.location.href='\(receiverURL.absoluteString)'}catch(e){}location.href='\(receiverURL.absoluteString)'},1000);"
        try await workspace.write("site/index.html", content: "<html><head><meta name='viewport' content='width=device-width'></head><body><div id='result'>Cedar</div><script>\(script)</script></body></html>")
        let preview = CanvasSafariPreview(canvas: CanvasDescriptor(kind: .site, entry: "site/index.html"), workspace: workspace)
        var requests: [String] = [], completed = false
        var closedURLs = false
        let controller = try await preview.start(observeInnerRequest: { requests.append($0) })
        let previewURL = try XCTUnwrap(preview.previewURL), contentURL = try XCTUnwrap(preview.contentURL)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }), presenter = try XCTUnwrap(window.rootViewController)
        defer {
            controller.dismiss(animated: false); preview.stop(); receiver.stop()
            let value: [String: Any] = ["purpose": "native-canvas-isolated-Safari-script-navigation-boundary", "completed": completed, "initialLoad": preview.initialLoad ?? false, "ownedReceiverPositiveControlConnections": before, "ownedReceiverConnectionsAfterAllAttempts": receiver.acceptedConnectionCount, "innerRequests": requests, "bothFormerURLsRefused": closedURLs, "applicationState": UIApplication.shared.applicationState.rawValue, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString, "limitations": ["Programmatic SafariServices presentation and owned loopback origins. No touch/swipe, external Safari app switch, VoiceOver or internet receiver.", "This verifies one website fixture's local storage, DOM execution and scripted fetch/image/popup/top/parent/self navigation attempts. Browser document/deck rendering and broader website APIs remain unverified.", "This is a proposed in-app browser alternative. It is not approved as a resolution of external-browser Android parity."]]
            let attachment = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Isolated Safari Canvas evidence"; attachment.lifetime = .keepAlways; add(attachment)
        }
        await withCheckedContinuation { continuation in presenter.present(controller, animated: false) { continuation.resume() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while preview.initialLoad == nil || !requests.contains(where: { $0.contains("state=Cobalt&parentDenied=true&frameHidden=true") }) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(preview.initialLoad == true); XCTAssertEqual(UIApplication.shared.applicationState, .active)
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(receiver.acceptedConnectionCount, before)
        preview.stop(); preview.stop()
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 3
        let client = URLSession(configuration: configuration); defer { client.invalidateAndCancel() }
        var refused = 0
        for url in [previewURL, contentURL] {
            do { let (_, response) = try await client.data(from: url); if (response as? HTTPURLResponse)?.statusCode != 200 { refused += 1 } } catch { refused += 1 }
        }
        closedURLs = refused == 2; XCTAssertTrue(closedURLs)
        completed = closedURLs && preview.initialLoad == true && receiver.acceptedConnectionCount == before && requests.contains { $0.contains("state=Cobalt&parentDenied=true&frameHidden=true") }
        XCTAssertTrue(completed)
    }
}
