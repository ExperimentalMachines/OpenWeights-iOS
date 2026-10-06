import XCTest
@testable import OpenWeightsCore

final class CanvasTests: XCTestCase {
    func testCutOffHTMLWarningSurvivesCleanBrowserAndBoundsCombinedDiagnostics() {
        let clean = CanvasPageReport()
        XCTAssertNotNil(clean.includingSavedHTML(path: "site/INDEX.HTML", content: "<html><body><div id=").verdict)
        for end in ["</HTML>", "</BoDy>"] {
            XCTAssertNil(clean.includingSavedHTML(path: "site/index.html", content: "<html>" + end + String(repeating: " ", count: 500)).verdict)
            XCTAssertNil(clean.includingSavedHTML(path: "site/index.html", content: end + String(repeating: "x", count: 391)).verdict)
            XCTAssertNotNil(clean.includingSavedHTML(path: "site/index.html", content: end + String(repeating: "x", count: 400)).verdict)
        }
        // The window counts UTF-16 units like Android, not Swift graphemes.
        XCTAssertNotNil(clean.includingSavedHTML(path: "site/index.html", content: "</body>" + String(repeating: "😀", count: 198)).verdict)
        for path in ["site/app.js", "site/file.htm", "notes.md"] { XCTAssertNil(clean.includingSavedHTML(path: path, content: "cut off").verdict) }
        XCTAssertNil(clean.includingSavedHTML(path: "site/index.html", content: nil).verdict)
        let report = CanvasPageReport(errors: [String(repeating: "E", count: 300), "second", "third", "fourth"], missing: ["missing.css"])
            .includingSavedHTML(path: "site/index.html", content: "<html>")
        let lines = report.verdict!.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5); XCTAssertTrue(lines[1].contains("looks cut off"))
        XCTAssertEqual(lines[2].count, 202); XCTAssertTrue(lines[0].contains("6 error"))
        let collision = CanvasPageReport(missing: ["file"]).includingSavedHTML(path: "index.html", content: "<html>")
        XCTAssertTrue(collision.verdict!.contains("looks cut off"))
        XCTAssertFalse(collision.includingSavedHTML(path: "index.html", content: "</body>").verdict!.contains("looks cut off"))
    }
    private func fixture(_ kind: CanvasKind = .site, entry: String = "site/index.html") throws -> (URL, Workspace, CanvasHTTPSession) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("site"), withIntermediateDirectories: true)
        try Data("<html><body>Cedar</body></html>".utf8).write(to: folder.appendingPathComponent("site/index.html"))
        try Data("body{color:navy}".utf8).write(to: folder.appendingPathComponent("site/style.css"))
        try Data([0, 1, 255, 7]).write(to: folder.appendingPathComponent("site/image.png"))
        try Data("private sibling".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let workspace = try Workspace(root: folder)
        let assets = ["doc.html": Data("<script nonce=\"__OW_NONCE__\">var FILE=\"__OW_FILE__\";var BASE=\"__OW_BASE__\";</script>".utf8), "deck.html": Data("deck __OW_FILE__".utf8), "marked.min.js": Data("viewer".utf8)]
        return (folder, workspace, try CanvasHTTPSession(canvas: CanvasDescriptor(kind: kind, entry: entry), workspace: workspace, assets: assets))
    }
    private func get(_ session: CanvasHTTPSession, _ path: String, method: String = "GET", host: String = "127.0.0.1:4567") async -> CanvasHTTPResponse {
        await session.answer(Data("\(method) /\(session.key)/\(path) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), port: 4567)
    }
    func testLocalSiteAssetsAndCSPWithoutSiblingDisclosure() async throws {
        let (root, _, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let page = await get(session, "site/index.html"), css = await get(session, "site/style.css"), binary = await get(session, "site/image.png"), sibling = await get(session, "notes.txt"), directory = await get(session, "site/")
        XCTAssertEqual(page.status, 200); XCTAssertEqual(css.status, 200); XCTAssertEqual(binary.body, Data([0,1,255,7])); XCTAssertEqual(sibling.status, 404); XCTAssertEqual(directory.body, page.body)
        XCTAssertEqual(page.headers["Content-Security-Policy"], CanvasHTTPSession.pagePolicy)
        XCTAssertEqual(page.headers["Cache-Control"], "no-store"); XCTAssertEqual(page.headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(page.headers["Content-Length"], String(page.body.count)); XCTAssertEqual(page.headers["Referrer-Policy"], "no-referrer")
    }
    func testMethodHostCapabilityAndMalformedRequestsRefused() async throws {
        let (root, _, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for host in ["localhost:4567", "127.0.0.1:4568", "example.com:4567", "127.0.0.1"] { let reply = await get(session, "site/index.html", host: host); XCTAssertEqual(reply.status, 400) }
        let post = await get(session, "site/index.html", method: "POST"); XCTAssertEqual(post.status, 405)
        for request in ["GET /wrong/site/index.html HTTP/1.1\r\nHost: 127.0.0.1:4567\r\n\r\n", "GET /\(session.key)/site/index.html HTTP/1.1\r\nHost: 127.0.0.1:4567\r\nHost: 127.0.0.1:4567\r\n\r\n", "GET /\(session.key)/site/index.html HTTP/1.1\r\n", String(repeating: "a", count: 16385)] {
            let reply = await session.answer(Data(request.utf8), port: 4567); XCTAssertNotEqual(reply.status, 200)
        }
    }
    func testTraversalAndSymlinkCannotEscapeActiveSite() async throws {
        let (root, _, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("site/escape.txt"), withDestinationURL: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("site/folder"), withDestinationURL: root)
        for path in ["site/../notes.txt", "site/%2e%2e/notes.txt", "site/%2e%2e%2fnotes.txt", "site/escape.txt", "site/folder/notes.txt", "site//index.html", "site/%00index.html", "site/%5cnotes.txt"] {
            let reply = await get(session, path); XCTAssertEqual(reply.status, 404, path)
        }
    }
    func testDocumentAndDeckServeOnlyEntryAndBundledViewer() async throws {
        for kind in [CanvasKind.document, .slides] {
            let (root, _, session) = try fixture(kind, entry: "notes.txt"); defer { try? FileManager.default.removeItem(at: root) }
            let viewer = kind == .document ? "doc" : "deck"
            let shell = await get(session, "__ow__/\(viewer)?file=notes.txt")
            XCTAssertEqual(shell.status, 200); XCTAssertTrue(shell.headers["Content-Security-Policy"]?.contains("nonce-") == true)
            XCTAssertTrue(shell.headers["Content-Security-Policy"]?.contains("frame-src 'none'") == true)
            let other = await get(session, "site/index.html"), asset = await get(session, "__ow__/asset/marked.min.js"), unlisted = await get(session, "__ow__/asset/notes.txt"), substitution = await get(session, "__ow__/\(viewer)?file=site/index.html")
            XCTAssertEqual(other.status, 404); XCTAssertEqual(asset.body, Data("viewer".utf8)); XCTAssertEqual(unlisted.status, 404); XCTAssertEqual(substitution.status, 404)
        }
    }
    func testShellEscapesNamesAndDoesNotUseWorkspaceViewerShadow() async throws {
        let entry = "site/quote\"\n<script>.md"
        let (root, _, session) = try fixture(.document, entry: entry); defer { try? FileManager.default.removeItem(at: root) }
        var url = URLComponents(url: session.url(port: 4567), resolvingAgainstBaseURL: false)!
        let reply = await session.answer(Data("GET \(url.percentEncodedPath)?\(url.percentEncodedQuery!) HTTP/1.1\r\nHost: 127.0.0.1:4567\r\n\r\n".utf8), port: 4567)
        let shell = String(decoding: reply.body, as: UTF8.self)
        XCTAssertEqual(reply.status, 200); XCTAssertFalse(shell.contains("<script>.md")); XCTAssertTrue(shell.contains("\\u003cscript>")); XCTAssertTrue(shell.contains("\\n")); XCTAssertTrue(shell.contains("\\\"")); XCTAssertFalse(shell.contains("__OW_NONCE__"))
        url.queryItems = [URLQueryItem(name: "file", value: "wrong")]
    }
    func testSessionAndGrantRevocationInvalidateKnownURLs() async throws {
        let (root, workspace, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try CanvasHTTPSession(canvas: session.canvas, workspace: workspace, assets: [:]); XCTAssertNotEqual(session.key, fresh.key)
        await session.revoke(); let closed = await get(session, "site/index.html"); XCTAssertEqual(closed.status, 404)
        await workspace.revoke(); let revoked = await get(fresh, "site/index.html"); XCTAssertEqual(revoked.status, 404)
    }
    func testWritesAreLiveAndCancellingChatDoesNotErasePreviewAccess() async throws {
        let (root, workspace, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await workspace.write("site/index.html", content: "<html><body>Cobalt</body></html>", replace: true)
        workspace.cancel()
        let reply = await get(session, "site/index.html"); XCTAssertEqual(reply.status, 200); XCTAssertTrue(String(decoding: reply.body, as: UTF8.self).contains("Cobalt"))
    }
    func testOversizedAndSpecialAssetsRefusedWithoutReading() async throws {
        let (root, _, session) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("site/large.png"); FileManager.default.createFile(atPath: path.path, contents: nil)
        let file = try FileHandle(forWritingTo: path); try file.truncate(atOffset: 8 * 1024 * 1024 + 1); try file.close()
        let reply = await get(session, "site/large.png"); XCTAssertEqual(reply.status, 404)
    }
    func testNavigationPermitsOnlyOwnPortAndInMemoryContent() {
        for raw in ["http://127.0.0.1:4567/key/site", "data:text/html,hello", "blob:http://127.0.0.1:4567/x", "about:blank"] { XCTAssertTrue(CanvasHTTPSession.permitsNavigation(URL(string: raw)!, port: 4567), raw) }
        for raw in ["http://127.0.0.1:4568/key", "http://localhost:4567/key", "https://example.com", "file:///private/data", "openweights://x", "about:config", "http://user@127.0.0.1:4567/key"] { XCTAssertFalse(CanvasHTTPSession.permitsNavigation(URL(string: raw)!, port: 4567), raw) }
    }
    func testSiteScopeAndDocumentRevisionScope() {
        XCTAssertTrue(CanvasDescriptor(kind: .site, entry: "index.html").contains("notes.txt"))
        let site = CanvasDescriptor(kind: .site, entry: "site/index.html"), doc = CanvasDescriptor(kind: .document, entry: "site/report.md")
        XCTAssertTrue(site.contains("site/style.css")); XCTAssertFalse(site.contains("sites/other")); XCTAssertFalse(site.contains("notes.txt"))
        XCTAssertTrue(doc.contains("site/report.md")); XCTAssertFalse(doc.contains("site/notes.md"))
    }
    func testGradingDeduplicatesMissingFilesAndBoundsHostileOutput() {
        let report = CanvasPageReport(errors: ["missing.css is not CSS", String(repeating: "a", count: 1000)], missing: ["favicon.ico", "missing.css"], blocked: ["example.com"])
        let text = report.verdict!
        XCTAssertFalse(text.contains("favicon.ico")); XCTAssertFalse(text.contains("is not CSS")); XCTAssertTrue(text.contains("Missing file: missing.css")); XCTAssertTrue(text.contains("example.com")); XCTAssertLessThan(text.count, 600)
    }
}

extension CanvasTests {
    func testBrowserWrapperCannotServeFilesOrUseSameOriginFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-wrapper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try Data("PRIVATE SIBLING".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let workspace = try Workspace(root: root)
        let frame = URL(string: "http://127.0.0.1:4568/innerkey/site/index.html")!
        let session = try CanvasHTTPSession(canvas: CanvasDescriptor(kind: .site, entry: "site/index.html"), workspace: workspace, assets: [:], browserFrame: frame)
        func get(_ path: String, port: UInt16 = 4567) async -> CanvasHTTPResponse {
            await session.answer(Data("GET /\(session.key)/\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), port: port)
        }
        let reply = await get("__ow_browser__/index.html"), sibling = await get("notes.txt"), sameOrigin = await get("__ow_browser__/index.html", port: 4568)
        let text = String(decoding: reply.body, as: UTF8.self)
        XCTAssertEqual(reply.status, 200); XCTAssertEqual(sibling.status, 404); XCTAssertEqual(sameOrigin.status, 404)
        XCTAssertTrue(text.contains("sandbox='allow-scripts allow-same-origin allow-forms'")); XCTAssertFalse(text.contains("allow-top-navigation")); XCTAssertFalse(text.contains("allow-popups"))
        XCTAssertTrue(reply.headers["Content-Security-Policy"]!.contains("frame-src http://127.0.0.1:4568")); XCTAssertTrue(reply.headers["Content-Security-Policy"]!.contains("default-src 'none'")); XCTAssertTrue(reply.headers["Content-Security-Policy"]!.contains("script-src 'none'"))
        XCTAssertTrue(session.url(port: 4567).path.contains("__ow_browser__"))
        await workspace.revoke(); let revoked = await get("__ow_browser__/index.html"); XCTAssertEqual(revoked.status, 404)
    }
    func testBrowserWrapperRefusesNonLocalOriginsAndEscapesItsFrameURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-frame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(root: root), canvas = CanvasDescriptor(kind: .document, entry: "report.md")
        for raw in ["https://example.com/x", "http://localhost:4568/x", "http://user@127.0.0.1:4568/x", "file:///x", "http://127.0.0.1:99999/x"] {
            do { _ = try CanvasHTTPSession(canvas: canvas, workspace: workspace, assets: [:], browserFrame: URL(string: raw)!); XCTFail("Accepted \(raw)") } catch {}
        }
        let session = try CanvasHTTPSession(canvas: canvas, workspace: workspace, assets: [:], browserFrame: URL(string: "http://127.0.0.1:4568/key/__ow__/doc?file=a&other=b")!)
        let request = Data("GET /\(session.key)/__ow_browser__/index.html HTTP/1.1\r\nHost: 127.0.0.1:4567\r\n\r\n".utf8)
        let reply = await session.answer(request, port: 4567), text = String(decoding: reply.body, as: UTF8.self)
        XCTAssertTrue(text.contains("width=860")); XCTAssertTrue(text.contains("file=a&amp;other=b"))
        await session.revoke(); let closed = await session.answer(request, port: 4567); XCTAssertEqual(closed.status, 404)
    }
}
