import Foundation
import OpenWeightsCore

struct LargePageFixtureResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}

actor LargePageFixtureConnector: PublicWebConnecting {
    let framing: String
    init(framing: String) { self.framing = framing }
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        let body = Data(("Cedar\n" + String(repeating: "readable words ", count: maximumBody / 15 + 10) + "\nGalena beyond the read limit").utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
        let wire: Data
        switch framing {
        case "length": wire = Data((headers + "Content-Length: \(body.count)\r\n\r\n").utf8) + body
        case "chunked": wire = Data((headers + "Transfer-Encoding: chunked\r\n\r\n\(String(body.count, radix: 16))\r\n").utf8) + body + Data("\r\n0\r\n\r\n".utf8)
        default: wire = Data((headers + "\r\n").utf8) + body
        }
        var decoder = WebHTTPResponseDecoder(maximumBody: maximumBody, allowsTextPrefix: true)
        for offset in stride(from: 0, to: wire.count, by: 16_384) {
            try Task.checkCancellation()
            if let response = try decoder.append(wire.subdata(in: offset..<min(offset + 16_384, wire.count))) { return response }
        }
        guard let response = try decoder.append(Data(), endOfStream: true) else { throw PublicWebError.refused("Fixture incomplete") }
        return response
    }
}

final class LargePageTransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
