import Foundation
import OpenWeightsCore
import Security

struct KeychainHubCredentialStore: HubCredentialStorage {
    let service: String
    init(service: String = "org.experimentalmachines.openweights.huggingface") { self.service = service }
    func token() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token", kSecAttrSynchronizable as String: false, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ModelError.unsupported("Keychain could not read the Hugging Face credential.") }
        guard let value = String(data: data, encoding: .utf8) else { throw ModelError.unsupported("Keychain returned an unreadable credential.") }
        return try HubIdentity.credential(value)
    }
    func save(_ rawToken: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token", kSecAttrSynchronizable as String: false]
        if rawToken.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelError.unsupported("Keychain could not remove the credential.") }
            return
        }
        let token = try HubIdentity.credential(rawToken)
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw ModelError.unsupported("Keychain could not save the credential.") }
        } else if status != errSecSuccess { throw ModelError.unsupported("Keychain could not update the credential.") }
    }
}

enum CredentialVault {
    static func token() throws -> String? { try KeychainHubCredentialStore().token() }
    static func save(_ token: String) throws { try KeychainHubCredentialStore().save(token) }
}

struct HubDetails: Decodable, Sendable {
    struct File: Decodable, Identifiable, Sendable {
        struct LFS: Decodable, Sendable { var sha256: String?; var size: Int64? }
        var rfilename: String; var size: Int64?; var lfs: LFS?; var blobId: String?
        var id: String { rfilename }
    }
    var id: String; var sha: String; var siblings: [File]
    var library_name: String? = nil
    var tags: [String]? = nil
}
enum HubClient {
    static func details(_ id: String, revision: String = "main", transport: any HubDiscoveryTransport = HubAPITransport()) async throws -> HubDetails {
        guard HubDiscoveryClient.validRepositoryID(id) else { throw ModelError.unsupported("The model repository address is invalid.") }
        guard revision == "main" || GGUFRangePolicy.hex(revision, count: 40) else { throw ModelError.unsupported("Repository files require main or a pinned 40-character revision.") }
        let url = URL(string: "https://huggingface.co")!.appendingPathComponent("api/models").appendingPathComponent(id).appendingPathComponent("revision").appendingPathComponent(revision)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        let result = try await request(components.url!, as: HubDetails.self, transport: transport)
        guard result.id == id, result.sha.count == 40, result.sha.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ModelError.unsupported("The Hub did not return the requested repository and pinned revision.") }
        guard revision == "main" || result.sha.lowercased() == revision.lowercased() else { throw ModelError.unsupported("The returned repository revision does not match the requested pin.") }
        return result
    }
    static func gguf(_ details: HubDetails, file: HubDetails.File, projector: HubDetails.File? = nil) throws -> LocalModel {
        guard details.siblings.filter({ $0.rfilename == file.rfilename }).count == 1,
              let canonical = details.siblings.first(where: { $0.rfilename == file.rfilename }) else {
            throw ModelError.unsupported("Select a unique file from the pinned repository listing.")
        }
        if let reason = GGUFFileName.exclusion(canonical.rfilename) { throw ModelError.unsupported(reason) }
        let size = canonical.lfs?.size ?? canonical.size
        guard size == nil || size! > 0 else { throw ModelError.unsupported("The Hub file size is invalid.") }
        let hash = canonical.lfs?.sha256
        guard hash == nil || GGUFRangePolicy.hex(hash!, count: 64) else { throw ModelError.unsupported("The Hub file checksum is invalid.") }
        let url = try GGUFRangePolicy.pinnedURL(repository: details.id, revision: details.sha, path: canonical.rfilename)
        var files = [ModelFile(path: canonical.rfilename, bytes: size, sha256: hash?.lowercased(), url: url)]
        if let projector {
            guard details.siblings.filter({ $0.rfilename == projector.rfilename }).count == 1,
                  let chosen = details.siblings.first(where: { $0.rfilename == projector.rfilename }),
                  (chosen.rfilename as NSString).lastPathComponent.lowercased().hasPrefix("mmproj"), chosen.rfilename.lowercased().hasSuffix(".gguf"),
                  let bytes = chosen.lfs?.size ?? chosen.size, bytes > 0,
                  let sha = chosen.lfs?.sha256, GGUFRangePolicy.hex(sha, count: 64) else { throw ModelError.unsupported("Select a unique projector with a published size and SHA-256 from this pinned repository.") }
            files.append(ModelFile(path: chosen.rfilename, bytes: bytes, sha256: sha.lowercased(),
                url: try GGUFRangePolicy.pinnedURL(repository: details.id, revision: details.sha, path: chosen.rfilename)))
        }
        return LocalModel(name: file.rfilename + (projector == nil ? "" : " + projector"), backend: .llamaMetal, entryFile: file.rfilename,
            files: files, repository: details.id, revision: details.sha)
    }
    static func compiled(_ details: HubDetails, file: HubDetails.File, useStoredCredential: Bool = true,
                         readMetadata: (@Sendable (LocalModel) async throws -> Data)? = nil) async throws -> LocalModel {
        guard details.siblings.filter({ $0.rfilename == file.rfilename }).count == 1 else {
            throw ModelError.unsupported("Select a unique compiled file from the pinned repository listing.")
        }
        let path = try CompiledHubArtifact.configPath(for: file.rfilename)
        let files = details.siblings.map { sibling in
            ModelFile(path: sibling.rfilename, bytes: sibling.lfs?.size ?? sibling.size,
                sha256: sibling.lfs?.sha256?.lowercased(),
                gitBlobSHA1: sibling.lfs == nil ? sibling.blobId?.lowercased() : nil)
        }
        let configs = files.filter { $0.path == path }
        guard configs.count == 1, var config = configs.first, let size = config.bytes, (1...1_048_576).contains(size),
              config.sha256 != nil || config.gitBlobSHA1 != nil,
              config.sha256.map({ GGUFRangePolicy.hex($0, count: 64) }) ?? true,
              config.gitBlobSHA1.map({ GGUFRangePolicy.hex($0, count: 40) }) ?? true else {
            throw ModelError.unsupported("The compiled export needs a config.json of at most 1 MiB with a published checksum beside its .pte file.")
        }
        config.url = try GGUFRangePolicy.pinnedURL(repository: details.id, revision: details.sha, path: path)
        let request = LocalModel(name: path, backend: .xnnpack, entryFile: path, files: [config], repository: details.id, revision: details.sha)
        let data: Data
        if let readMetadata { data = try await readMetadata(request) }
        else { data = try await HubGGUFRangeSource(model: request, useStoredCredential: useStoredCredential).read(offset: 0, length: Int(size)) }
        try Task.checkCancellation()
        return try CompiledHubArtifact.select(repository: details.id, revision: details.sha, entry: file.rfilename, files: files, configData: data)
    }
    private static func request<T: Decodable>(_ url: URL, as type: T.Type, transport: any HubDiscoveryTransport) async throws -> T {
        let response = try await transport.get(url)
        guard (200..<300).contains(response.status) else {
            throw ModelError.unsupported("Hugging Face could not load this request. Check connectivity and access permissions, then retry.")
        }
        return try JSONDecoder().decode(type, from: response.data)
    }
    static func pinnedCatalogue() throws -> [LocalModel] {
        struct Manifest: Decodable {
            struct Artifact: Decodable {
                struct File: Decodable { var file: String; var bytes: Int64; var sha256: String; var url: URL }
                var id: String; var repo: String; var revision: String; var files: [File]
            }
            var artifacts: [Artifact]
        }
        guard let url = Bundle.main.url(forResource: "model-catalogue", withExtension: "json") else { throw ModelError.unsupported("The bundled model catalogue is missing.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        return manifest.artifacts.map { artifact in
            let backend: ModelBackend = artifact.id == "gguf" ? .llamaMetal : artifact.id == "mlx" ? .mlx : .xnnpack
            let entry = artifact.files.first { $0.file.hasSuffix(".gguf") || $0.file.hasSuffix(".pte") }?.file ?? "config.json"
            return LocalModel(name: "Qwen3 0.6B · " + backend.label, backend: backend, entryFile: entry,
                files: artifact.files.map { ModelFile(path: $0.file, bytes: $0.bytes, sha256: $0.sha256, url: $0.url) },
                repository: artifact.repo, revision: artifact.revision, family: "qwen3")
        }
    }
}

struct HubAPITransport: HubDiscoveryTransport {
    var useStoredCredential = true
    var credential: String? = nil
    func get(_ url: URL) async throws -> HubAPIResponse {
        guard Self.allowed(url) else { throw ModelError.unsupported("Only Hugging Face API requests are allowed for discovery.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let token = try credential ?? (useStoredCredential ? CredentialVault.token() : nil)
        if let token { request.setValue("Bearer " + (try HubIdentity.credential(token)), forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: HubAPIRedirectGuard())
        guard let response = response as? HTTPURLResponse else { throw ModelError.unsupported("The Hub returned an invalid response.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { throw ModelError.unsupported("The Hub API response exceeds its 2 MiB limit.") }
            data.append(byte)
        }
        return HubAPIResponse(status: response.statusCode, data: data, link: response.value(forHTTPHeaderField: "Link"))
    }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "huggingface.co" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.path.hasPrefix("/api/")
    }
}
private final class HubAPIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(HubAPITransport.allowed) == true ? request : nil)
    }
}
