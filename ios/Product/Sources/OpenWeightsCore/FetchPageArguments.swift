import Foundation
import CoreFoundation

public struct FetchPageArguments: Sendable {
    public let address: PublicWebAddress
    public let find: String?
    public let savePath: String?
    public init(_ json: String) throws {
        guard json.utf8.count <= 16_384, let raw = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw PublicWebError.refused("Page-fetch arguments must be a JSON object within 16 KiB.")
        }
        func value(_ names: [String]) -> String? {
            for name in names {
                let text: String?
                if let string = raw[name] as? String { text = string }
                else if let number = raw[name] as? NSNumber {
                    text = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
                } else if raw[name] is NSNull { text = "null" }
                else { text = nil }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return nil
        }
        guard let url = value(["url", "link", "address", "input"]) else { throw PublicWebError.refused("Give the public HTTPS address to read.") }
        address = try Self.normalize(url)
        find = value(["find", "pattern", "search", "contains", "grep"])
        savePath = find == nil ? value(["save_to", "saveTo", "save"]) : nil
    }
    public static func normalize(_ raw: String) throws -> PublicWebAddress {
        guard raw.utf8.count <= 8_192 else { throw PublicWebError.refused("The page address is too long.") }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = Set("<>\"'`()[]")
        while let first = text.first, wrappers.contains(first) { text.removeFirst() }
        while let last = text.last, wrappers.contains(last) {
            // A public IPv6 host's closing bracket belongs to the address, not copied markup.
            if last == "]", let components = URLComponents(string: text), components.host?.contains(":") == true,
               components.path.isEmpty, components.query == nil { break }
            text.removeLast()
        }
        while let last = text.last, ".,;:!?".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            let host = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first?.split(separator: "?", maxSplits: 1).first?.split(separator: "#", maxSplits: 1).first ?? ""
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard !text.contains(where: \.isWhitespace), labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
                  let suffix = labels.last, suffix.count >= 2, suffix.allSatisfy(\.isLetter) else {
                throw PublicWebError.refused("Give a public HTTPS address or a host such as example.com/page.")
            }
            text = "https://" + text
        }
        return try PublicWebAddress(text)
    }
    public static func validateContentHost(_ address: PublicWebAddress) throws {
        let host = address.host.hasPrefix("www.") ? String(address.host.dropFirst(4)) : address.host
        if ["engineering.linkedin.com", "developers.facebook.com", "about.instagram.com"].contains(host) { return }
        if ["linkedin.com", "facebook.com", "instagram.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            throw PublicWebError.refused("\(address.host) requires signing in to show its content. Answer from a search result or say the page needs an account rather than guessing its contents.")
        }
    }
}
