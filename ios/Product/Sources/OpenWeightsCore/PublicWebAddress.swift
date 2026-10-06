import Foundation
import Darwin

public enum PublicWebError: LocalizedError, Sendable {
    case refused(String)
    public var errorDescription: String? { if case .refused(let reason) = self { return reason }; return nil }
}

public struct PublicWebAddress: Sendable, Equatable {
    public let url: URL
    public let host: String
    public let port: UInt16
    public let target: String
    public init(_ raw: String) throws {
        guard raw.utf8.count <= 8_192, !raw.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }),
              !raw.contains("\\"), var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              let original = components.host, !original.isEmpty else {
            throw PublicWebError.refused("Use a complete HTTPS page address without credentials or control characters.")
        }
        var hostname = original.lowercased()
        if hostname.utf8.contains(where: { $0 >= 128 }), let ascii = components.url?.host() { hostname = ascii.lowercased() }
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { hostname = String(hostname.dropFirst().dropLast()) }
        guard !hostname.contains("%"), !hostname.hasSuffix("."), !hostname.contains("\0") else {
            throw PublicWebError.refused("Scoped addresses and ambiguous host names cannot be fetched.")
        }
        if PublicWebIP.bytes(hostname) != nil {
            guard PublicWebIP.isPublic(hostname) else { throw PublicWebError.refused("Only public internet addresses can be fetched.") }
        } else {
            guard !hostname.contains(":"), !hostname.allSatisfy({ $0.isNumber || $0 == "." }),
                  hostname.contains("."), hostname.utf8.count <= 253,
                  hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
                  }), !["localhost", "local", "home.arpa", "internal", "invalid", "test"].contains(where: { hostname == $0 || hostname.hasSuffix("." + $0) }) else {
                throw PublicWebError.refused("Use a public internet host name.")
            }
        }
        let number = components.port ?? 443
        guard (1...65_535).contains(number) else { throw PublicWebError.refused("The page port is invalid.") }
        components.fragment = nil
        guard let url = components.url else { throw PublicWebError.refused("The page address is invalid.") }
        self.url = url; self.host = hostname; self.port = UInt16(number)
        self.target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    public func redirected(to location: String) throws -> PublicWebAddress {
        guard !location.isEmpty, location.utf8.count <= 8_192,
              !location.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 }), !location.contains("\\"),
              let resolved = URL(string: location, relativeTo: url)?.absoluteURL else {
            throw PublicWebError.refused("The page returned an invalid redirect.")
        }
        return try PublicWebAddress(resolved.absoluteString)
    }
    public var request: Data {
        let authority = (host.contains(":") ? "[" + host + "]" : host) + (port == 443 ? "" : ":\(port)")
        return Data("GET \(target) HTTP/1.1\r\nHost: \(authority)\r\nUser-Agent: OpenWeights/1.0\r\nAccept: text/html,text/plain,application/json;q=0.9,*/*;q=0.1\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
    }
}

public enum PublicWebIP {
    // Resolve elsewhere. inet_pton parses only strict literals and never performs DNS.
    static func bytes(_ value: String) -> [UInt8]? {
        if value.contains(".") {
            let dotted = value.split(separator: ":", omittingEmptySubsequences: false).last ?? ""
            let octets = dotted.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ octet in
                !octet.isEmpty && octet.count <= 3 && (octet.count == 1 || octet.first != "0") &&
                octet.utf8.allSatisfy({ (48...57).contains($0) }) && Int(octet).map({ $0 <= 255 }) == true
            }) else { return nil }
        }
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }
    public static func isPublic(_ value: String) -> Bool {
        guard let bytes = bytes(value) else { return false }
        if bytes.count == 4 { return publicIPv4(bytes) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 { return publicIPv4(Array(bytes.suffix(4))) }
        // NAT64's well-known prefix can carry private IPv4 addresses too.
        if bytes.prefix(12) == [0, 100, 255, 155, 0, 0, 0, 0, 0, 0, 0, 0] { return publicIPv4(Array(bytes.suffix(4))) }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] & 0xfe == 0 { return false }
        if bytes.prefix(4) == [0x20, 0x01, 0x0d, 0xb8] { return false }
        if bytes.prefix(2) == [0x20, 0x02] { return false }
        if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] & 0xf0 == 0 { return false }
        return true
    }
    private static func publicIPv4(_ b: [UInt8]) -> Bool {
        if [0, 10, 127].contains(b[0]) || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false }
        if b[0] == 169 && b[1] == 254 { return false }
        if b[0] == 172 && (16...31).contains(b[1]) { return false }
        if b[0] == 192 && b[1] == 168 { return false }
        if b[0] == 192 && b[1] == 0 && [0, 2].contains(b[2]) { return false }
        if b[0] == 192 && b[1] == 88 && b[2] == 99 { return false }
        if b[0] == 198 && (b[1] == 18 || b[1] == 19 || (b[1] == 51 && b[2] == 100)) { return false }
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
        return true
    }
}
