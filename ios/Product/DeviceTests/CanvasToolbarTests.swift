import XCTest
import UIKit
import SwiftUI
import WebKit
import SafariServices
import OpenWeightsCore
@testable import OpenWeights

@MainActor private func canvasViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(canvasViews) }
@MainActor private func canvasControllers(_ controller: UIViewController) -> [UIViewController] {
    [controller] + controller.children.flatMap(canvasControllers) + (controller.presentedViewController.map(canvasControllers) ?? [])
}
@MainActor private func toolbarWait(_ condition: () async throws -> Bool, seconds: Double = 20) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while try await !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(50))
    }
}
@MainActor private func canvasToolbarItems(_ hosting: UIViewController) -> [UIBarButtonItem] {
    var seen: Set<ObjectIdentifier> = []
    let controllerItems = canvasControllers(hosting).flatMap { ($0.navigationItem.rightBarButtonItems ?? []) + $0.navigationItem.trailingItemGroups.flatMap(\.barButtonItems) }
    let barItems = canvasViews(hosting.view).compactMap { $0 as? UINavigationBar }.flatMap { ($0.items ?? []).flatMap { ($0.rightBarButtonItems ?? []) + $0.trailingItemGroups.flatMap(\.barButtonItems) } }
    return (controllerItems + barItems).filter { seen.insert(ObjectIdentifier($0)).inserted }
}
@MainActor private func safariToolbarItem(_ hosting: UIViewController) -> UIBarButtonItem? {
    canvasToolbarItems(hosting).first { item in
        item.accessibilityIdentifier == "canvas.openSafari" || item.accessibilityLabel == "Open Safari preview here" ||
        item.customView.map { canvasViews($0).contains { $0.accessibilityIdentifier == "canvas.openSafari" || $0.accessibilityLabel == "Open Safari preview here" } } == true
    }
}
@MainActor private func dispatchCanvasToolbar(_ item: UIBarButtonItem) throws -> String {
    if let action = item.primaryAction { UIControl().sendAction(action); return "UIControl.sendAction(UIAction)" }
    if let action = item.action {
        guard UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) else { throw URLError(.cannotLoadFromNetwork) }
        return "UIApplication.sendAction(target-action)"
    }
    if let control = item.customView.flatMap({ canvasViews($0).compactMap { $0 as? UIControl }.first }) {
        if #available(iOS 17.4, *) { control.performPrimaryAction(); return "UIControl.performPrimaryAction" }
        control.sendActions(for:.primaryActionTriggered); return "UIControl.sendActions(primaryActionTriggered)"
    }
    throw NSError(domain: "CanvasToolbarFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:"The visible toolbar has no public UIKit action dispatch."])
}

extension ProductTests {
    @MainActor func testNativeCanvasActualToolbarSheetCloseAndBackgroundRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-toolbar-" + UUID().uuidString)
        let suite = "openweights.toolbar." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Shared/site"), withIntermediateDirectories: true)
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle; defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try Data("<html><body><h1>Cedar toolbar</h1></body></html>".utf8).write(to: root.appendingPathComponent("Shared/site/index.html"))
        let files = WorkspaceController(bookmarkFile: root.appendingPathComponent("workspace.bookmark"), defaults: defaults)
        await files.choose(root.appendingPathComponent("Shared")); files.canvasEnabled = ["show_website"]
        let call = AgentToolCall(id:"toolbar", name:"show_website", argumentsJSON:"{\"path\":\"site/index.html\"}")
        let opened = await files.execute(call, approval:nil, expectedGrantID:files.grantID); XCTAssertFalse(opened.rejected)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let presenter = try XCTUnwrap(scene.windows.first { $0.isKeyWindow }?.rootViewController)
        let hosting = UIHostingController(rootView: NavigationStack { CanvasScreen(files:files).environment(\.scenePhase,.active) })
        hosting.modalPresentationStyle = .fullScreen
        var completed = false, evidence: [String:Any] = [:]
        var previews: [CanvasSafariPreview] = []
        defer {
            previews.forEach { $0.stop() }; hosting.dismiss(animated:false)
            evidence["toolbarItems"] = canvasToolbarItems(hosting).map { ["title":$0.title ?? "", "label":$0.accessibilityLabel ?? "", "identifier":$0.accessibilityIdentifier ?? "", "hasPrimaryAction":$0.primaryAction != nil, "hasTargetAction":$0.action != nil] }
            let value: [String:Any] = ["purpose":"native-Canvas-actual-SwiftUI-toolbar-Safari-sheet-close-background-routing", "completed":completed, "observations":evidence, "operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString, "limitations":["Actual CanvasScreen hosted in the phone scene with public UIKit toolbar action dispatch. No touch gestures, XCUITest, computer-use controls or screenshots.", "Safari Done is delivered through the actual delegate callback. Background is a controlled SwiftUI scenePhase environment change while XCTest remains foreground, not an actual OS background/termination run."]]
            let attachment = XCTAttachment(data:try! JSONSerialization.data(withJSONObject:value, options:[.prettyPrinted,.sortedKeys]), uniformTypeIdentifier:"public.json")
            attachment.name = "Canvas toolbar lifecycle"; attachment.lifetime = .keepAlways; add(attachment)
        }
        await withCheckedContinuation { continuation in presenter.present(hosting, animated:false) { continuation.resume() } }
        try await toolbarWait {
            guard let web = canvasViews(hosting.view).compactMap({ $0 as? WKWebView }).first,
                  let text = try? await web.evaluateJavaScript("document.body.textContent") as? String else { return false }
            return text.contains("Cedar toolbar") && safariToolbarItem(hosting)?.isEnabled == true
        }
        let web = try XCTUnwrap(canvasViews(hosting.view).compactMap { $0 as? WKWebView }.first)
        let normalURL = try XCTUnwrap(web.url)
        let item = try XCTUnwrap(safariToolbarItem(hosting))
        evidence["firstActionDispatch"] = try dispatchCanvasToolbar(item)
        try await toolbarWait { canvasControllers(hosting).contains { $0 is SFSafariViewController } }
        let safari = try XCTUnwrap(canvasControllers(hosting).compactMap { $0 as? SFSafariViewController }.first)
        let preview = try XCTUnwrap(safari.delegate as? CanvasSafariPreview); previews.append(preview)
        let wrapperURL = try XCTUnwrap(preview.previewURL), contentURL = try XCTUnwrap(preview.contentURL)
        try await toolbarWait { preview.initialLoad == true }
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 3; configuration.timeoutIntervalForResource = 3
        let client = URLSession(configuration:configuration); defer { client.invalidateAndCancel() }
        func status(_ url:URL) async -> Int { (try? await client.data(from:url)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? -1 }
        var live: [Int] = []
        for url in [normalURL,wrapperURL,contentURL] { live.append(await status(url)) }
        evidence["statusesWhileSheetVisible"] = live; XCTAssertEqual(live,[200,200,200])
        preview.safariViewControllerDidFinish(safari)
        try await toolbarWait { !canvasControllers(hosting).contains { $0 is SFSafariViewController } }
        let wrapperClosed = await status(wrapperURL), contentClosed = await status(contentURL), normalStillLive = await status(normalURL)
        evidence["statusesAfterDone"] = [normalStillLive,wrapperClosed,contentClosed]
        XCTAssertEqual(normalStillLive,200); XCTAssertNotEqual(wrapperClosed,200); XCTAssertNotEqual(contentClosed,200)
        let secondItem = try XCTUnwrap(safariToolbarItem(hosting)); evidence["secondActionDispatch"] = try dispatchCanvasToolbar(secondItem)
        try await toolbarWait { canvasControllers(hosting).contains { $0 is SFSafariViewController } }
        let secondSafari = try XCTUnwrap(canvasControllers(hosting).compactMap { $0 as? SFSafariViewController }.first)
        let secondPreview = try XCTUnwrap(secondSafari.delegate as? CanvasSafariPreview); previews.append(secondPreview)
        let secondURLs = [try XCTUnwrap(secondPreview.previewURL),try XCTUnwrap(secondPreview.contentURL)]
        try await toolbarWait { secondPreview.initialLoad == true }
        hosting.rootView = NavigationStack { CanvasScreen(files:files).environment(\.scenePhase,.background) }
        try await toolbarWait { !canvasControllers(hosting).contains { $0 is SFSafariViewController } }
        var stopped: [Int] = []
        for url in [normalURL] + secondURLs { stopped.append(await status(url)) }
        evidence["statusesAfterControlledBackground"] = stopped
        XCTAssertTrue(stopped.allSatisfy { $0 != 200 })
        completed = live == [200,200,200] && normalStillLive == 200 && wrapperClosed != 200 && contentClosed != 200 && stopped.allSatisfy { $0 != 200 }
        await files.revoke()
    }
}
