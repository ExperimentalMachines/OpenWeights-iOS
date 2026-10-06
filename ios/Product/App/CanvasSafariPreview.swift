import SwiftUI
import SafariServices
import OpenWeightsCore

// Safari cannot install our WebKit request rules. Its trusted outer page has a
// separate origin and frames only the owned inner server. The sandbox refuses
// popups/top navigation without taking scripts or local storage from the page.
@MainActor final class CanvasSafariPreview: NSObject, Identifiable, SFSafariViewControllerDelegate {
    let id = UUID()
    let canvas: CanvasDescriptor
    private let workspace: Workspace
    private var inner: CanvasLocalServer?
    private var outer: CanvasLocalServer?
    private(set) var controller: SFSafariViewController?
    private(set) var initialLoad: Bool?
    private(set) var previewURL: URL?
    private(set) var contentURL: URL?
    var didFinish: (() -> Void)?
    private var closed = false
    init(canvas: CanvasDescriptor, workspace: Workspace) { self.canvas = canvas; self.workspace = workspace }
    func start(bundle: Bundle = .main, observeInnerRequest: ((String) -> Void)? = nil) async throws -> SFSafariViewController {
        guard !closed, controller == nil else { throw WorkspaceError.cancelled }
        do {
            let inner = try CanvasLocalServer(canvas: canvas, workspace: workspace, bundle: bundle, observeRequest: observeInnerRequest); self.inner = inner
            let framed = try await inner.start()
            contentURL = framed
            let outer = try CanvasLocalServer(canvas: canvas, workspace: workspace, browserFrame: framed); self.outer = outer
            let url = try await outer.start()
            previewURL = url
            guard !closed, !Task.isCancelled, await workspace.isReady else { throw WorkspaceError.cancelled }
            let controller = SFSafariViewController(url: url)
            controller.delegate = self; controller.dismissButtonStyle = .close
            self.controller = controller
            return controller
        } catch { stop(); throw error }
    }
    func stop() {
        closed = true; inner?.stop(); outer?.stop(); inner = nil; outer = nil
        controller?.delegate = nil; controller = nil
        previewURL = nil; contentURL = nil
        didFinish = nil
    }
    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) { initialLoad = didLoadSuccessfully }
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) { didFinish?() }
}

struct CanvasSafariView: UIViewControllerRepresentable {
    let controller: SFSafariViewController
    func makeUIViewController(context: Context) -> SFSafariViewController { controller }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
