import Foundation

public protocol PublicWebResolving: Sendable {
    func resolve(host: String, timeout: TimeInterval) async throws -> [String]
}
public protocol PublicWebConnecting: Sendable {
    func exchange(address: PublicWebAddress, ip: String, timeout: TimeInterval, maximumBody: Int) async throws -> WebHTTPResponse
}
public struct PublicWebDocument: Sendable {
    public let address: PublicWebAddress
    public let response: WebHTTPResponse
    public let visited: [URL]
}
public struct PublicWebClient: Sendable {
    private let resolver: any PublicWebResolving
    private let connector: any PublicWebConnecting
    public init(resolver: any PublicWebResolving = SystemPublicWebResolver(), connector: any PublicWebConnecting = ApplePublicWebConnector()) {
        self.resolver = resolver; self.connector = connector
    }
    public func fetch(_ raw: String, maximumBody: Int = 1_048_576, timeout: TimeInterval = 60, validateHop: @Sendable (PublicWebAddress) throws -> Void = { _ in }) async throws -> PublicWebDocument {
        var address = try PublicWebAddress(raw); var visited: [URL] = []
        let end = ProcessInfo.processInfo.systemUptime + min(120, max(1, timeout.isFinite ? timeout : 60))
        func remaining() throws -> TimeInterval {
            let value = end - ProcessInfo.processInfo.systemUptime
            guard value > 0 else { throw PublicWebError.refused("The page request timed out.") }; return value
        }
        while true {
            try Task.checkCancellation()
            try validateHop(address)
            guard !visited.contains(address.url), visited.count <= 5 else { throw PublicWebError.refused("The page redirected in a loop or too many times.") }
            visited.append(address.url)
            let addresses = try await resolver.resolve(host: address.host, timeout: min(15, try remaining()))
            try Task.checkCancellation()
            // The connector receives the checked literal, never a hostname it can resolve again.
            let publicIPs = Array(NSOrderedSet(array: addresses.filter(PublicWebIP.isPublic))).compactMap { $0 as? String }.prefix(8)
            guard !publicIPs.isEmpty else { throw PublicWebError.refused("The page does not resolve to a public internet address.") }
            var response: WebHTTPResponse?
            var failure: Error?
            for ip in publicIPs {
                try Task.checkCancellation()
                do {
                    response = try await connector.exchange(address: address, ip: ip, timeout: min(20, try remaining()), maximumBody: min(4_194_304, max(1, maximumBody)))
                    break
                } catch is CancellationError { throw CancellationError() }
                catch { failure = error }
            }
            try Task.checkCancellation()
            guard let response else { throw failure ?? PublicWebError.refused("The public page could not be read.") }
            if [301, 302, 303, 307, 308].contains(response.status) {
                guard let location = response.headers["location"] else { throw PublicWebError.refused("The page redirect has no destination.") }
                address = try address.redirected(to: location)
                continue
            }
            return PublicWebDocument(address: address, response: response, visited: visited)
        }
    }
}
