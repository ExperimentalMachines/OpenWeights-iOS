import Foundation
import OpenWeightsCore
@main struct FetchCompatibilityChecks {
    static func main() async throws {
        let outcomes = try await verifyFetchDecoderFixtures(); let results = outcomes.map(\.json)
        let matches = results.filter { $0["matchesJava"] as? Bool == true }.count
        guard results.count == 10, matches == 9 else { throw PublicWebError.refused("Decoder reference results did not match the captured probe inventory.") }
        let proof: [String: Any] = ["status": "fetch-decoder-host-reference-verified-with-declared-unpaired-surrogate-difference", "cases": results, "passedChecks": ["ten-captured-java-decoder-cases-have-declared-swift-outcomes", "nine-of-ten-captured-codepoint-results-match-java"], "limitations": ["JDK 21 Charset probes, not an Android SDK/OkHttp instrumentation run.", "JDK accepts a UTF-32 unpaired surrogate that cannot be represented as a valid Swift Unicode scalar. The iOS decoder replaces that malformed scalar with U+FFFD. This difference remains explicit rather than counted as Java parity.", "Captured probes do not prove every legacy codec or malformed sequence. Live/native iOS text decoding remains unverified."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("10 declared decoder outcomes passed, 9 matched the captured Java codepoints")
    }
}
