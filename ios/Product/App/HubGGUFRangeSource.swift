import Foundation
import OpenWeightsCore

actor HubGGUFRangeSource: GGUFByteSource {
    private let url: URL
    private let useStoredCredential: Bool
    private let deadline: Date
    private(set) var totalBytes: Int64?
    init(model: LocalModel, useStoredCredential: Bool = true) throws {
        guard let repository = model.repository, let revision = model.revision, model.files.count == 1,
              let file = model.files.first,
              file.url == (try GGUFRangePolicy.pinnedURL(repository: repository, revision: revision, path: file.path)),
              file.bytes == nil || file.bytes! > 0 else {
            throw ModelError.unsupported("Header inspection requires a single pinned Hub file.")
        }
        url = file.url!; totalBytes = file.bytes; self.useStoredCredential = useStoredCredential
        deadline = Date().addingTimeInterval(60)
    }
    func read(offset: Int64, length: Int) async throws -> Data {
        try Task.checkCancellation()
        let end = try GGUFRangePolicy.rangeEnd(offset: offset, length: length)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ModelError.unsupported("GGUF header inspection exceeded its one-minute limit.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(30, remaining))
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if useStoredCredential, let token = try CredentialVault.token(), !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = remaining
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request, delegate: HubGGUFRedirectGuard())
        guard let response = response as? HTTPURLResponse,
              response.url.map(GGUFRangePolicy.allowedRedirect) == true else {
            throw ModelError.unsupported("The Hub returned an invalid header response.")
        }
        let framing = try GGUFRangePolicy.validate(status: response.statusCode,
            contentRange: response.value(forHTTPHeaderField: "Content-Range"),
            contentLength: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
            encoding: response.value(forHTTPHeaderField: "Content-Encoding"), offset: offset, length: length, expectedTotal: totalBytes)
        var data = Data(); data.reserveCapacity(framing.bytes)
        for try await byte in stream {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0, data.count < framing.bytes else {
                throw ModelError.unsupported("The GGUF header response exceeded its time or byte limit.")
            }
            data.append(byte)
        }
        guard data.count == framing.bytes else { throw ModelError.unsupported("The GGUF header range was truncated.") }
        totalBytes = framing.total
        return data
    }
}

final class HubGGUFRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let count = redirects; lock.unlock()
        guard count <= 5, let url = request.url, GGUFRangePolicy.allowedRedirect(url) else { completionHandler(nil); return }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        if url.host?.lowercased() != "huggingface.co" { next.setValue(nil, forHTTPHeaderField: "Authorization") }
        next.setValue(task.originalRequest?.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(next)
    }
}
