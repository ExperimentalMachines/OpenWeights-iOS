import Foundation
import Network
import OpenWeightsCore

struct WebCheckFailure: Error { let reason: String }
func requireWeb(_ condition: Bool, _ reason: String) throws { if !condition { throw WebCheckFailure(reason: reason) } }

@main struct PublicWebChecks {
    static func main() async {
        do { try await run() }
        catch { fputs("Live transport check failed: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var passed: [String] = []; var observations: [[String: Any]] = []
        func checkpoint() throws {
            let partial: [String: Any] = ["status": "host-live-check-in-progress", "passedChecks": passed, "observations": observations]
            try JSONSerialization.data(withJSONObject: partial, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
        try checkpoint()
        let resolver = SystemPublicWebResolver()
        fputs("Resolving the public IANA host\n", stderr)
        let addresses = try await resolver.resolve(host: "www.iana.org", timeout: 15)
        try requireWeb(!addresses.isEmpty && addresses.allSatisfy(PublicWebIP.isPublic), "System resolver returned no checked public IANA address.")
        passed.append("system-dns-produces-checked-public-iana-addresses")
        observations.append(["check": "DNS", "addressCount": addresses.count, "allPublic": true])
        try checkpoint()

        fputs("Fetching public IANA content with system TLS trust\n", stderr)
        let connector = ApplePublicWebConnector(observe: { event in fputs(event + "\n", stderr) })
        let document = try await PublicWebClient(connector: connector).fetch("https://www.iana.org/domains/reserved", maximumBody: 262_144, timeout: 45)
        try requireWeb(document.response.status == 200 && String(decoding: document.response.body, as: UTF8.self).contains("IANA"), "The TLS fetch did not return the expected public document.")
        passed.append("pinned-public-ip-tls-fetch-returns-iana-content")
        observations.append(["check": "HTTPS", "requestedURL": "https://www.iana.org/domains/reserved", "finalURL": document.address.url.absoluteString,
                             "status": document.response.status, "bodyBytes": document.response.body.count, "visitedURLs": document.visited.map(\.absoluteString)])
        try checkpoint()

        fputs("Checking the valid control for the public hostname-mismatch fixture\n", stderr)
        let controlIPs = try await resolver.resolve(host: "badssl.com", timeout: 15)
        let mismatchIPs = try await resolver.resolve(host: "wrong.host.badssl.com", timeout: 15)
        let common = try controlIPs.first(where: { mismatchIPs.contains($0) }).unwrapWebIP()
        let control = try await connector.exchange(address: PublicWebAddress("https://badssl.com/"), ip: common, timeout: 15, maximumBody: 262_144)
        try requireWeb(control.status == 200, "The valid public TLS control did not work.")
        passed.append("valid-badssl-control-trusts-the-same-public-ip")
        observations.append(["check": "TLS valid control", "status": control.status, "bodyBytes": control.body.count])
        try checkpoint()
        fputs("Verifying the public hostname-mismatch fixture is refused\n", stderr)
        do {
            _ = try await connector.exchange(address: PublicWebAddress("https://wrong.host.badssl.com/"), ip: common, timeout: 15, maximumBody: 65_536)
            throw WebCheckFailure(reason: "Mismatched TLS host was accepted.")
        } catch let error as NWError {
            guard case .tls(let code) = error else { throw WebCheckFailure(reason: "The mismatch failed outside TLS verification: \(error)") }
            passed.append("system-tls-rejects-original-host-certificate-mismatch")
            observations.append(["check": "TLS mismatch", "errorDomain": "NWError.tls", "errorCode": code])
            try checkpoint()
        }

        fputs("Cancelling an actual Network connection operation\n", stderr)
        let address = try PublicWebAddress("https://www.iana.org/domains/reserved")
        let start = ProcessInfo.processInfo.systemUptime
        let task = Task { try await connector.exchange(address: address, ip: addresses[0], timeout: 10, maximumBody: 262_144) }
        try await Task.sleep(nanoseconds: 10_000_000); task.cancel()
        do { _ = try await task.value; throw WebCheckFailure(reason: "Cancelled connection returned content.") }
        catch is CancellationError {
            passed.append("cancelled-network-operation-returns-cancellation-without-content")
            observations.append(["check": "Cancel", "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start])
        }
        let proof: [String: Any] = ["status": "apple-public-web-transport-host-live-checks-verified", "passedChecks": passed,
            "observations": observations, "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "limitations": ["Live macOS System DNS and Network/TLS checks against public IANA HTTPS and the public badssl valid/hostname-mismatch fixtures. No credentials or cookies were used.",
                             "The negative fixture returns a generic TLS certificate error. This test requires refusal, not one specific platform error code.",
                             "Cancellation verifies the live operation's API outcome, not that an HTTP request reached the server before cancellation.",
                             "Does not verify iPhone networking, full web-tool switches/approvals, providers, readable text extraction or image rendering."]]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Five Apple public web transport host checks passed")
    }
}

private extension Optional where Wrapped == String {
    func unwrapWebIP() throws -> String {
        guard let value = self else { throw WebCheckFailure(reason: "The positive and negative TLS fixture did not resolve to the same public IP.") }
        return value
    }
}
