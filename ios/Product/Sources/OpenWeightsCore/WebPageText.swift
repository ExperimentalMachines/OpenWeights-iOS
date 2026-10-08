import Foundation
import SwiftSoup
import CoreFoundation
import Darwin

public enum WebPageText {
    public static let maximumBytes = 512 * 1024
    static func isReadableContentType(_ contentType: String?) -> Bool {
        guard let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return ["text/", "application/json", "application/xml", "application/xhtml"].contains { type.hasPrefix($0) }
    }
    public static func extract(_ document: PublicWebDocument) throws -> String {
        let response = document.response
        guard (200..<300).contains(response.status) else { throw PublicWebError.refused("HTTP \(response.status). The page was not read.") }
        guard response.body.count <= maximumBytes else { throw PublicWebError.refused("The page exceeds the 512 KiB text limit.") }
        let encoding = response.headers["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
        guard encoding == nil || encoding == "identity" || (encoding == "gzip" && response.bodyWasGzipDecoded) else { throw PublicWebError.refused("The server returned unsupported compressed content. Try another source.") }
        let contentType = response.headers["content-type"]
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard isReadableContentType(contentType) else {
            throw PublicWebError.refused("That address is \(type!), which is not readable text.")
        }
        var stringEncoding = String.Encoding.utf8
        if let contentType {
            for part in contentType.split(separator: ";").dropFirst() {
                let fields = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if fields.count == 2 && fields[0].lowercased() == "charset" {
                    let name = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()
                    if name.utf8.count <= 128 {
                        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                        if encoding != kCFStringEncodingInvalidId { stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)) }
                    }
                    break
                }
            }
        }
        var bytes = response.body
        let marks: [(Data, String.Encoding)] = [(Data([0xef,0xbb,0xbf]), .utf8), (Data([0xfe,0xff]), .utf16BigEndian), (Data([0xff,0xfe,0x00,0x00]), .utf32LittleEndian), (Data([0xff,0xfe]), .utf16LittleEndian), (Data([0x00,0x00,0xfe,0xff]), .utf32BigEndian)]
        // OkHttp's BOM-aware body reader gives a byte-order mark precedence over Content-Type.
        if let (mark, encoding) = marks.first(where: { bytes.starts(with: $0.0) }) { stringEncoding = encoding; bytes = bytes.dropFirst(mark.count) }
        let body = try decoded(bytes, encoding: stringEncoding)
        try Task.checkCancellation()
        let text = type == nil || ["text/html", "application/xhtml"].contains(where: { type!.hasPrefix($0) })
            ? try html(body, baseURL: document.address.url.absoluteString) : body
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PublicWebError.refused("That page has no readable text. It may build its content in a browser. Try a different source.")
        }
        return text
    }
    public static func html(_ body: String, baseURL: String) throws -> String {
        // Legacy encodings can expand when converted to UTF-8. The network byte cap already applied.
        guard body.utf16.count <= maximumBytes else { throw PublicWebError.refused("The page exceeds the bounded text limit.") }
        let document = try SwiftSoup.parse(body, baseURL)
        try document.select("script,style,nav,header,footer,aside,form,noscript,iframe,svg,template,dialog,head").remove()
        func largest(_ selector: String) throws -> (Element, Int)? {
            var best: (Element, Int)?
            for element in try document.select(selector).array() {
                try Task.checkCancellation()
                let size = try element.text().utf16.count
                if size > (best?.1 ?? -1) { best = (element, size) }
            }
            return best
        }
        let article = try largest("article")
        let root = try article.flatMap { $0.1 >= 500 ? $0.0 : nil } ?? (try largest("main"))?.0 ?? document.body() ?? document
        // Iteration avoids a recursive stack on deeply nested, untrusted markup.
        var stack: [(Node, Bool, Int)] = [(root, false, 0)]
        var output = ""; var visited = 0; var outputBytes = 0
        func append(_ piece: String) { output += piece; outputBytes += piece.utf8.count }
        let blocks: Set<String> = ["p", "div", "section", "article", "main", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "tr", "table"]
        while let (node, closing, depth) = stack.popLast() {
            visited += 1
            guard visited <= 100_000, depth <= 256, outputBytes <= maximumBytes * 4 else {
                throw PublicWebError.refused("The page markup is too complex to read within its limits.")
            }
            if visited % 128 == 0 { try Task.checkCancellation() }
            if let text = node as? TextNode {
                append(text.getWholeText()); continue
            }
            guard let element = node as? Element else { continue }
            let tag = element.tagName().lowercased()
            if closing {
                if tag == "a", let url = URL(string: try element.attr("href"), relativeTo: URL(string: baseURL))?.absoluteURL,
                   ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
                    append(" (\(url.absoluteString))")
                }
                if ["td", "th"].contains(tag) { append(" | ") }
                if blocks.contains(tag) || tag == "li" { append("\n") }
            } else {
                if blocks.contains(tag) { append("\n") }
                if tag == "li" { append("\n- ") }
                if tag == "br" { append("\n") }
                stack.append((element, true, depth))
                for child in element.getChildNodes().reversed() { stack.append((child, false, depth + 1)) }
            }
        }
        return output.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private static func decoded(_ data: Data, encoding: String.Encoding) throws -> String {
        if encoding == .utf8 { return String(decoding: data, as: UTF8.self) }
        if encoding == .ascii {
            return String(String.UnicodeScalarView(data.map { UnicodeScalar($0 < 128 ? UInt32($0) : 0xfffd)! }))
        }
        if [.utf16, .utf16BigEndian, .utf16LittleEndian].contains(encoding) {
            let bytes = Array(data); let little = encoding == .utf16LittleEndian
            let units: [UInt16] = stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map {
                little ? UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 : UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
            }
            var scalars: [UInt32] = []; scalars.reserveCapacity(units.count)
            var index = 0; var trailingByte = bytes.count % 2 != 0
            while index < units.count {
                let unit = UInt32(units[index]); index += 1
                if (0xd800...0xdbff).contains(unit) {
                    if index < units.count {
                        let next = UInt32(units[index]); index += 1
                        scalars.append((0xdc00...0xdfff).contains(next) ? 0x10000 + (unit - 0xd800) * 1024 + next - 0xdc00 : 0xfffd)
                    } else { scalars.append(0xfffd); trailingByte = false }
                } else { scalars.append((0xdc00...0xdfff).contains(unit) ? 0xfffd : unit) }
            }
            return String(decoding: scalars, as: UTF32.self) + (trailingByte ? "\u{fffd}" : "")
        }
        if [.utf32, .utf32BigEndian, .utf32LittleEndian].contains(encoding) {
            let bytes = Array(data); let little = encoding == .utf32LittleEndian
            var units: [UInt32] = []; units.reserveCapacity(bytes.count / 4)
            for offset in stride(from: 0, to: bytes.count - bytes.count % 4, by: 4) {
                var value: UInt32 = 0
                for index in 0..<4 { let shift = UInt32((little ? index : 3 - index) * 8); value |= UInt32(bytes[offset + index]) << shift }
                units.append(value)
            }
            return String(decoding: units, as: UTF32.self) + (bytes.count % 4 == 0 ? "" : "\u{fffd}")
        }
        let foundation = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard let name = CFStringConvertEncodingToIANACharSetName(foundation) else { throw PublicWebError.refused("The declared charset cannot be decoded on this device.") }
        let converter = iconv_open("UTF-8", name as String)
        guard let converter, converter != OpaquePointer(bitPattern: -1) else {
            guard let body = String(data: data, encoding: encoding) else { throw PublicWebError.refused("The page bytes do not match its text encoding.") }; return body
        }
        defer { iconv_close(converter) }
        var input = data.map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: data.count * 4 + 16)
        let used = try input.withUnsafeMutableBufferPointer { source in
            try output.withUnsafeMutableBufferPointer { destination -> Int in
                var incoming = source.baseAddress; var remainingInput = source.count
                var outgoing = destination.baseAddress; var remainingOutput = destination.count
                while remainingInput > 0 {
                    let result = iconv(converter, &incoming, &remainingInput, &outgoing, &remainingOutput)
                    if result != -1 { continue }
                    guard errno == EILSEQ || errno == EINVAL, remainingOutput >= 3 else { throw PublicWebError.refused("The text conversion exceeded its limits.") }
                    let consumed = errno == EINVAL ? remainingInput : 1
                    outgoing![0] = CChar(bitPattern: 0xef); outgoing![1] = CChar(bitPattern: 0xbf); outgoing![2] = CChar(bitPattern: 0xbd)
                    incoming = incoming?.advanced(by: consumed); remainingInput -= consumed
                    outgoing = outgoing?.advanced(by: 3); remainingOutput -= 3
                }
                return destination.count - remainingOutput
            }
        }
        return String(decoding: output.prefix(used).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public enum WebPageSearch {
    public static func render(text: String, pattern: String) throws -> String {
        guard pattern.utf16.count <= 1024 else { throw PublicWebError.refused("Keep the page-search pattern at or below 1,024 characters.") }
        let regex = try (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]))
            ?? (try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive]))
        let source = text as NSString
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var count = 0; var spans: [NSRange] = []; var stopped = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime > deadline { stopped = true; stop.pointee = true; return }
            guard let match else { return }
            count += 1
            let low = max(0, match.range.location - 300)
            let high = min(source.length, NSMaxRange(match.range) + 300)
            if let last = spans.last, NSMaxRange(last) >= low {
                spans[spans.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), high) - last.location)
            } else { spans.append(NSRange(location: low, length: high - low)) }
            if count >= 12 { stop.pointee = true }
        }
        try Task.checkCancellation()
        if stopped { return "That pattern took too long and was stopped. Try simpler words or a simpler regular expression." }
        if count == 0 { return "Nothing on that page matches \"\(pattern)\". The page has \(source.length) characters of readable text. Fetch without find to read it, or try a simpler pattern." }
        var budget = 4000; var windows: [String] = []
        for span in spans where budget > 0 {
            let excerpt = prefix(source.substring(with: span).trimmingCharacters(in: .whitespacesAndNewlines), maximum: budget)
            budget -= excerpt.utf16.count; windows.append(excerpt)
        }
        return "\(count >= 12 ? "The first " : "")\(count) places matching \"\(pattern)\"\(count >= 12 ? " (there may be more)" : ""):\n\n" + windows.joined(separator: "\n\n---\n\n")
    }
    static func prefix(_ text: String, maximum: Int) -> String {
        var remaining = maximum; var end = text.startIndex
        for character in text {
            let length = character.utf16.count
            if length > remaining { break }
            remaining -= length; end = text.index(after: end)
        }
        return String(text[..<end])
    }
}
