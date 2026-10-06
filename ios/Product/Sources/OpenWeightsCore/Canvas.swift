import Foundation
import Security

public enum CanvasKind: String, Sendable { case site, document, slides }
public struct CanvasDescriptor: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: CanvasKind
    public let entry: String
    public let root: String
    public var revision: Int = 0
    public init(kind: CanvasKind, entry: String) {
        id = UUID(); self.kind = kind; self.entry = entry
        root = entry.split(separator: "/").dropLast().joined(separator: "/")
    }
    public func contains(_ path: String) -> Bool {
        kind == .site ? root.isEmpty || path == entry || path == root || path.hasPrefix(root + "/") : path == entry
    }
}
public enum CanvasToolDefinitions {
    public static let all: [AgentToolDefinition] = [
        tool("show_website", "Show an HTML page you saved, rendered live. Its folder supplies CSS, scripts and images. Nothing loads from the network. Keep assets in the folder or inline. Call once after saving; later saves update it live."),
        tool("show_document", "Show a saved Markdown file as A4 pages. Call once after saving; later saves update the pages live."),
        tool("show_slides", "Show a saved Markdown file as a 16:9 slide deck. Separate slides with a line containing only ---. Later saves update the deck live.")
    ]
    private static func tool(_ name: String, _ description: String) -> AgentToolDefinition {
        AgentToolDefinition(name: name, description: description, parametersJSON: "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}")
    }
    public static func kind(_ name: String) -> CanvasKind? {
        switch name { case "show_website": return .site; case "show_document": return .document; case "show_slides": return .slides; default: return nil }
    }
    public static func path(_ call: AgentToolCall) throws -> String {
        guard let args = try JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any],
              let path = ["path", "file", "page", "document", "deck"].compactMap({ args[$0] as? String }).first else {
            throw WorkspaceError.operation("Give the relative path of the saved file to show.")
        }
        _ = try Workspace.segments(path)
        return path
    }
}
public struct CanvasPageReport: Sendable {
    public let errors: [String]
    public let missing: [String]
    public let blocked: [String]
    private var savedHTMLLooksCutOff = false
    public init(errors: [String] = [], missing: [String] = [], blocked: [String] = []) {
        self.errors = errors; self.missing = missing; self.blocked = blocked
    }
    public func includingSavedHTML(path: String?, content: String?) -> CanvasPageReport {
        var report = self; report.savedHTMLLooksCutOff = false
        guard let path, path.lowercased().hasSuffix(".html"), let content else { return report }
        // Browsers repair incomplete HTML silently. Match Android's last 400
        // UTF-16 units so a long trailing script does not hide a cut-off save.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(decoding: trimmed.utf16.suffix(400), as: UTF16.self).lowercased()
        report.savedHTMLLooksCutOff = !tail.contains("</html>") && !tail.contains("</body>")
        return report
    }
    public var verdict: String? {
        let missing = self.missing.filter { $0.lowercased() != "favicon.ico" }
        // Browser deduplication must not suppress a host warning when a missing
        // asset's name happens to be a word in that warning.
        let lines = (savedHTMLLooksCutOff ? ["The file ends before </body>: it looks cut off. Save the whole page."] : [])
            + errors.filter { error in !missing.contains { error.contains($0) } }
            + missing.map { "Missing file: " + $0 }
            + blocked.map { $0 + ": nothing loads from the network; keep assets in the folder" }
        guard !lines.isEmpty else { return nil }
        return "The page raised \(lines.count) error(s) when it loaded. Fix them and save again.\n" + lines.prefix(4).map { "- " + String($0.prefix(200)) }.joined(separator: "\n")
    }
}
public struct CanvasHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public var wire: Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 500: "Internal Server Error"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        return Data(head.utf8) + body
    }
}

// The listener supplies the port. This session owns the capability and scope so
// the native WebView and an external browser receive exactly the same response.
public actor CanvasHTTPSession {
    public nonisolated let key: String
    public nonisolated let canvas: CanvasDescriptor
    private var workspace: Workspace?
    private let assets: [String: Data]
    private let browserFrame: URL?
    public static let assetNames = ["doc.html", "deck.html", "marked.min.js", "paged.polyfill.min.js", "doc-paged.css"]
    public static let pagePolicy = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; connect-src 'self'; form-action 'self'; base-uri 'none'; object-src 'none'"
    public init(canvas: CanvasDescriptor, workspace: Workspace, assets: [String: Data], browserFrame: URL? = nil) throws {
        if let browserFrame {
            guard let port = browserFrame.port, (1...65535).contains(port),
                  Self.permitsNavigation(browserFrame, port: UInt16(port)), browserFrame.scheme == "http" else { throw WorkspaceError.invalidPath }
        }
        self.canvas = canvas; self.workspace = workspace; self.assets = assets; self.browserFrame = browserFrame
        key = try Self.randomKey()
    }
    public func revoke() { workspace = nil }
    public nonisolated func url(port: UInt16) -> URL {
        let base = "http://127.0.0.1:\(port)/\(key)/"
        if browserFrame != nil { return URL(string: base + "__ow_browser__/index.html")! }
        if canvas.kind == .site { return URL(string: base + Self.encodePath(canvas.entry))! }
        let kind = canvas.kind == .document ? "doc" : "deck"
        var components = URLComponents(string: base + "__ow__/" + kind)!
        components.queryItems = [URLQueryItem(name: "file", value: canvas.entry)]
        return components.url!
    }
    public nonisolated static func permitsNavigation(_ url: URL, port: UInt16) -> Bool {
        if url.scheme == "http" { return url.host == "127.0.0.1" && url.port == Int(port) && url.user == nil && url.password == nil }
        return ["data", "blob"].contains(url.scheme ?? "") || url.absoluteString == "about:blank"
    }
    public func answer(_ request: Data, port: UInt16) async -> CanvasHTTPResponse {
        guard request.count <= 16384, let text = String(data: request, encoding: .utf8), text.hasSuffix("\r\n\r\n") else { return response(400) }
        let lines = text.components(separatedBy: "\r\n"), parts = lines[0].split(separator: " ")
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else { return response(400) }
        guard parts[0] == "GET" else { return response(405) }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard hosts == ["127.0.0.1:\(port)"] else { return response(400) }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), let components = URLComponents(string: target),
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/" + key + "/"), let workspace else { return response(404) }
        let path = String(decoded.dropFirst(key.count + 2))
        if let browserFrame {
            guard path == "__ow_browser__/index.html", browserFrame.port != Int(port), await workspace.isReady else { return response(404) }
            let frameOrigin = "http://127.0.0.1:\(browserFrame.port!)"
            let frameURL = browserFrame.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            let viewport = canvas.kind == .document ? "width=860" : "width=device-width,initial-scale=1"
            guard let nonce = try? Self.randomKey() else { return response(500) }
            // The page and wrapper need different ports. Otherwise allow-same-origin
            // lets page code reach this DOM and remove its own sandbox attribute.
            let html = "<!doctype html><html><head><meta name='viewport' content='\(viewport)'><title>Canvas browser preview</title><style nonce='\(nonce)'>html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}</style></head><body><iframe title='Local Canvas preview' sandbox='allow-scripts allow-same-origin allow-forms' referrerpolicy='no-referrer' src=\"\(frameURL)\"></iframe></body></html>"
            let policy = "default-src 'none'; frame-src \(frameOrigin); style-src 'nonce-\(nonce)'; script-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
            guard self.workspace != nil, !Task.isCancelled else { return response(404) }
            return response(200, type: "text/html; charset=utf-8", body: Data(html.utf8), policy: policy)
        }
        if path.hasPrefix("__ow__/") {
            // Viewer machinery is bundled, never shadowed by workspace files.
            guard canvas.kind != .site else { return response(404) }
            let viewer = canvas.kind == .document ? "doc" : "deck"
            if path == "__ow__/" + viewer {
                guard components.queryItems?.filter({ $0.name == "file" }).map(\.value) == [canvas.entry],
                      let shell = assets[viewer + ".html"].flatMap({ String(data: $0, encoding: .utf8) }),
                      let nonce = try? Self.randomKey() else { return response(404) }
                let file = Self.jsStringBody(canvas.entry)
                let body = shell.replacingOccurrences(of: "__OW_FILE__", with: file)
                    .replacingOccurrences(of: "__OW_BASE__", with: "/" + key)
                    .replacingOccurrences(of: "__OW_NONCE__", with: nonce)
                let policy = "default-src 'self'; script-src 'self' 'nonce-\(nonce)'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; form-action 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'"
                return response(200, type: "text/html; charset=utf-8", body: Data(body.utf8), policy: policy)
            }
            let name = String(path.dropFirst("__ow__/asset/".count))
            guard path == "__ow__/asset/" + name, Self.assetNames.contains(name), !name.hasSuffix(".html"), let asset = assets[name] else { return response(404) }
            return response(200, type: Self.contentType(name), body: asset)
        }
        let wanted = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "index.html" : path.hasSuffix("/") ? String(path.dropLast()) : path
        guard (try? Workspace.segments(wanted)) != nil, canvas.contains(wanted) else { return response(404) }
        do {
            let entry = try await workspace.canvasEntry(wanted)
            guard canvas.contains(entry) else { return response(404) }
            let bytes = try await workspace.readCanvas(entry)
            // Revocation can arrive while the provider is reading. Its late bytes
            // are never handed to a browser after the session is closed.
            guard self.workspace != nil, !Task.isCancelled else { return response(404) }
            let type = Self.contentType(entry)
            return response(200, type: type, body: bytes, policy: type.hasPrefix("text/html") ? Self.pagePolicy : nil)
        } catch { return response(404) }
    }
    private func response(_ status: Int, type: String = "text/plain; charset=utf-8", body: Data = Data(), policy: String? = nil) -> CanvasHTTPResponse {
        var headers = ["Content-Type": type, "Content-Length": String(body.count), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Connection": "close", "Referrer-Policy": "no-referrer"]
        if let policy { headers["Content-Security-Policy"] = policy }
        return CanvasHTTPResponse(status: status, headers: headers, body: body)
    }
    private nonisolated static func randomKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WorkspaceError.operation("The local preview key could not be created.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private nonisolated static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/%?#")
        return path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
    }
    private nonisolated static func jsStringBody(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        let quoted = String(data: data, encoding: .utf8)!
        return String(quoted.dropFirst(2).dropLast(2)).replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
    private nonisolated static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "md", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
