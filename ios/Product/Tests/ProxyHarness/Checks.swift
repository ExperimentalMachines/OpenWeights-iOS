import Foundation
import Network
import OpenWeightsCore

@main struct ProxyChecks {
    static func main() async throws {
        let result = try await verifyProxyTransport(); let passed = result.checks; let ip = result.ip
        let proof: [String: Any] = ["status": "scoped-apple-proxy-transport-host-verified", "passedChecks": passed, "checkedPublicIP": ip,
            "limitations": ["Owned loopback HTTP CONNECT and SOCKS5 forwarding fixtures dial only one public badssl IP on port 443. Synthetic credentials only.", "HTTPS proxy certificate mismatch is refused. A successfully authenticated HTTPS proxy with a trusted proxy certificate and remote commercial proxy services were not measured.", "Host transport evidence does not establish iPhone behavior or native UI interaction."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("\(passed.count) actual proxy checks passed")
    }
}
