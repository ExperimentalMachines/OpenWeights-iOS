import Foundation

public enum HubIdentityFailure: Error, Equatable, Sendable {
    case rejected
    case unavailable
}

public enum HubIdentity {
    public static func credential(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ModelError.unsupported("Enter a nonempty Hugging Face token without spaces or control characters.")
        }
        return token
    }
    public static func account(_ response: HubAPIResponse) throws -> String {
        if response.status == 401 || response.status == 403 { throw HubIdentityFailure.rejected }
        guard (200..<300).contains(response.status) else { throw HubIdentityFailure.unavailable }
        struct Identity: Decodable { let name: String }
        guard let identity = try? JSONDecoder().decode(Identity.self, from: response.data),
              !identity.name.isEmpty, identity.name.utf8.count <= 128,
              identity.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw HubIdentityFailure.unavailable
        }
        return identity.name
    }
}
