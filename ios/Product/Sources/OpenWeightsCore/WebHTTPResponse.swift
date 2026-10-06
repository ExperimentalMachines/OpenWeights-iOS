import Foundation

public struct WebHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let setCookieHeaders: [String]
    public let bodyIsComplete: Bool
    public init(status: Int, headers: [String: String], body: Data, setCookieHeaders: [String] = [], bodyIsComplete: Bool = true) { self.status = status; self.headers = headers; self.body = body; self.setCookieHeaders = setCookieHeaders; self.bodyIsComplete = bodyIsComplete }
}

public struct WebHTTPResponseDecoder: Sendable {
    private var buffer = Data()
    private let maximumBody: Int
    private let allowsTextPrefix: Bool
    public init(maximumBody: Int = 1_048_576, allowsTextPrefix: Bool = false) {
        self.maximumBody = min(4_194_304, max(1, maximumBody))
        self.allowsTextPrefix = allowsTextPrefix
    }
    public mutating func append(_ data: Data, endOfStream: Bool = false) throws -> WebHTTPResponse? {
        guard data.count <= maximumBody + 262_144 - buffer.count else { throw refused("The page exceeds its transfer limit.") }
        buffer.append(data)
        let bytes = Array(buffer); var head = 0; var interim = 0
        while true {
            guard let end = separator(bytes, start: head) else {
                guard bytes.count - head <= 16_384, !endOfStream else { throw refused("The page headers are oversized or incomplete.") }
                return nil
            }
            guard end - head <= 16_384,
                  let text = String(bytes: bytes[head..<end], encoding: .isoLatin1) else { throw refused("The page headers are invalid.") }
            let lines = text.components(separatedBy: "\r\n")
            let statusLine = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(statusLine[0])),
                  statusLine[1].count == 3, statusLine[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let status = Int(statusLine[1]), (100...599).contains(status) else { throw refused("The page status line is invalid.") }
            var fields: [String: [String]] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      line[..<colon].utf8.allSatisfy({ Self.tokenByte($0) }) else { throw refused("The page contains malformed headers.") }
                let name = line[..<colon].lowercased(); let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else { throw refused("The page contains control characters in its headers.") }
                fields[name, default: []].append(value)
            }
            head = end + 4
            if status < 200 {
                interim += 1
                guard status != 101, interim <= 8, fields["transfer-encoding"] == nil, fields["content-length"] == nil else { throw refused("The page returned an unsupported informational response.") }
                continue
            }
            let headers = fields.mapValues { $0.joined(separator: ", ") }
            let encoding = headers["content-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
            let prefixAllowed = allowsTextPrefix && (200..<300).contains(status)
                && WebPageText.isReadableContentType(headers["content-type"])
                && (encoding == nil || encoding == "identity")
            func response(_ body: Data, complete: Bool = true) -> WebHTTPResponse {
                WebHTTPResponse(status: status, headers: headers, body: body,
                    setCookieHeaders: fields["set-cookie"] ?? [], bodyIsComplete: complete)
            }
            guard fields["location"]?.count ?? 0 <= 1 else { throw refused("The page returned ambiguous redirects.") }
            if status == 204 || status == 304 {
                guard bytes.count == head, fields["transfer-encoding"] == nil else { throw refused("A bodyless response carried unexpected data.") }
                return WebHTTPResponse(status: status, headers: headers, body: Data(), setCookieHeaders: fields["set-cookie"] ?? [])
            }
            if let transfer = headers["transfer-encoding"] {
                guard transfer.lowercased() == "chunked", fields["content-length"] == nil else { throw refused("The page has ambiguous or unsupported body framing.") }
                var offset = head; var body = Data(); var count = 0
                while true {
                    guard let lineEnd = crlf(bytes, start: offset) else {
                        guard bytes.count - offset <= 4_096, !endOfStream else { throw refused("The chunk header is incomplete or oversized.") }; return nil
                    }
                    guard lineEnd - offset <= 4_096 else { throw refused("The chunk header is oversized.") }
                    let sizePart = bytes[offset..<lineEnd].prefix { $0 != 59 }
                    guard !sizePart.isEmpty, sizePart.count <= 16, sizePart.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let length = Int(String(decoding: sizePart, as: UTF8.self), radix: 16), length <= Int.max - 2,
                          prefixAllowed || length <= maximumBody - body.count else { throw refused("The page chunk size is invalid or exceeds its limit.") }
                    offset = lineEnd + 2; count += 1
                    guard count <= 8_192 else { throw refused("The page has too many chunks.") }
                    if length == 0 {
                        let trailerStart = offset
                        while true {
                            guard let trailerEnd = crlf(bytes, start: offset) else {
                                guard bytes.count - trailerStart <= 16_384, !endOfStream else { throw refused("The page trailers are incomplete or oversized.") }; return nil
                            }
                            guard trailerEnd - trailerStart <= 16_384 else { throw refused("The page trailers are oversized.") }
                            if trailerEnd == offset {
                                guard trailerEnd + 2 == bytes.count else { throw refused("The page has data after its completed body.") }
                                return WebHTTPResponse(status: status, headers: headers, body: body, setCookieHeaders: fields["set-cookie"] ?? [])
                            }
                            guard let colon = bytes[offset..<trailerEnd].firstIndex(of: 58), colon > offset,
                                  bytes[offset..<colon].allSatisfy({ Self.tokenByte($0) }) else { throw refused("The page trailers are invalid.") }
                            let name = String(decoding: bytes[offset..<colon], as: UTF8.self).lowercased()
                            guard !["content-length", "transfer-encoding", "location", "content-encoding", "host"].contains(name),
                                  bytes[(colon + 1)..<trailerEnd].allSatisfy({ ($0 >= 32 && $0 != 127) || $0 == 9 }) else { throw refused("The page trailer changes protected response fields.") }
                            offset = trailerEnd + 2
                        }
                    }
                    if prefixAllowed, length > maximumBody - body.count {
                        let available = bytes.count - offset
                        if available >= length + 2 {
                            guard bytes[offset + length] == 13, bytes[offset + length + 1] == 10 else { throw refused("The page chunk terminator is invalid.") }
                        } else if endOfStream { throw refused("The page ended inside a chunk.") }
                        let needed = maximumBody - body.count
                        guard available >= needed else { return nil }
                        body.append(contentsOf: bytes[offset..<(offset + needed)])
                        return response(body, complete: false)
                    }
                    guard bytes.count - offset >= length + 2 else {
                        guard !endOfStream else { throw refused("The page ended inside a chunk.") }; return nil
                    }
                    guard bytes[offset + length] == 13, bytes[offset + length + 1] == 10 else { throw refused("The page chunk terminator is invalid.") }
                    body.append(contentsOf: bytes[offset..<(offset + length)]); offset += length + 2
                }
            }
            if let lengths = fields["content-length"] {
                let tokens = lengths.flatMap { $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                guard let first = tokens.first, !first.isEmpty, first.utf8.allSatisfy({ (48...57).contains($0) }),
                      tokens.allSatisfy({ $0 == first }), let length = Int(first), prefixAllowed || length <= maximumBody else { throw refused("The page has an invalid or oversized content length.") }
                guard bytes.count - head <= length else { throw refused("The page has data after its declared body.") }
                if endOfStream, bytes.count - head != length { throw refused("The page ended before its declared body length.") }
                if prefixAllowed, length > maximumBody, bytes.count - head >= maximumBody {
                    return response(Data(bytes[head..<(head + maximumBody)]), complete: false)
                }
                guard bytes.count - head == length else {
                    guard !endOfStream else { throw refused("The page ended before its declared body length.") }; return nil
                }
                return WebHTTPResponse(status: status, headers: headers, body: Data(bytes[head...]), setCookieHeaders: fields["set-cookie"] ?? [])
            }
            if prefixAllowed, bytes.count - head >= maximumBody {
                return response(Data(bytes[head..<(head + maximumBody)]), complete: endOfStream && bytes.count - head == maximumBody)
            }
            guard bytes.count - head <= maximumBody else { throw refused("The page exceeds its body limit.") }
            return endOfStream ? WebHTTPResponse(status: status, headers: headers, body: Data(bytes[head...]), setCookieHeaders: fields["set-cookie"] ?? []) : nil
        }
    }
    private func refused(_ message: String) -> PublicWebError { .refused(message) }
    private func separator(_ bytes: [UInt8], start: Int) -> Int? {
        guard bytes.count - start >= 4 else { return nil }
        return (start...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }
    }
    private func crlf(_ bytes: [UInt8], start: Int) -> Int? {
        guard bytes.count - start >= 2 else { return nil }
        return (start...(bytes.count - 2)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 }
    }
    private static func tokenByte(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || Array("!#$%&'*+-.^_`|~".utf8).contains(value)
    }
}
