import Foundation
import OpenWeightsCore

struct FetchDecoderFixtureOutcome: Sendable {
    let charset: String; let inputHex: String; let decoded: [Int]; let java: [Int]
    var matchesJava: Bool { decoded == java }
    var json: [String: Any] { ["charset": charset, "inputHex": inputHex, "decodedCodePoints": decoded, "javaCodePoints": java, "matchesJava": matchesJava] }
}
private struct FetchDecoderFixtureResolver: PublicWebResolving {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String] { ["8.8.8.8"] }
}
private struct FetchDecoderFixtureConnector: PublicWebConnecting {
    let bytes: [UInt8]; let charset: String
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse {
        WebHTTPResponse(status: 200, headers: ["content-type": "text/plain; charset=" + charset], body: Data(bytes))
    }
}

/// Captured JDK 21 Charset probes. They are a decoder reference, not Android instrumentation.
func verifyFetchDecoderFixtures() async throws -> [FetchDecoderFixtureOutcome] {
    let cases: [(String, [UInt8], [Int], [Int])] = [
        ("UTF-8", [65, 195, 40], [65, 65533, 40], [65, 65533, 40]),
        ("UTF-16BE", [0, 65, 216, 0, 0], [65, 65533], [65, 65533]),
        ("UTF-16BE", [216, 0, 0, 65], [65533], [65533]),
        ("UTF-32BE", [0, 0, 216, 0], [55296], [65533]),
        ("UTF-32BE", [0, 0, 0, 65, 0], [65, 65533], [65, 65533]),
        ("US-ASCII", [65, 233, 66], [65, 65533, 66], [65, 65533, 66]),
        ("UTF-16", [0, 67, 0, 101, 0, 100, 0, 97, 0, 114], [67, 101, 100, 97, 114], [67, 101, 100, 97, 114]),
        ("UTF-32", [0, 0, 0, 67], [67], [67]),
        ("Shift_JIS", [130, 32], [65533, 32], [65533, 32]),
        ("windows-1252", [65, 129, 66], [65, 65533, 66], [65, 65533, 66]),
    ]
    let address = try PublicWebAddress("https://example.com/")
    var results: [FetchDecoderFixtureOutcome] = []
    for (charset, bytes, java, expected) in cases {
        let client = PublicWebClient(resolver: FetchDecoderFixtureResolver(), connector: FetchDecoderFixtureConnector(bytes: bytes, charset: charset))
        let document = try await client.fetch(address.url.absoluteString)
        let decoded = try WebPageText.extract(document); let actual = decoded.unicodeScalars.map { Int($0.value) }
        guard actual == expected else { throw PublicWebError.refused("The captured decoder reference disagreed for " + charset) }
        results.append(FetchDecoderFixtureOutcome(charset: charset, inputHex: bytes.map { String(format: "%02x", $0) }.joined(), decoded: actual, java: java))
    }
    return results
}
