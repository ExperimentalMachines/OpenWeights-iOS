import CryptoKit
import Foundation

struct AcquisitionEvent: Codable, Sendable {
    let artifactID: String
    let file: String
    let attempt: Int
    let outcome: String
    let sourceHost: String?
    let responseHost: String?
    let statusCode: Int?
    let receivedFileBytes: Int64?
    let elapsedMs: Double
    let errorDomain: String?
    let errorCode: Int?
}

enum ModelStore {
    typealias Download = (URLRequest) async throws -> (URL, URLResponse)
    typealias Observe = (AcquisitionEvent) throws -> Void

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ url: URL, file: ArtifactFile) throws {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard bytes.map(Int64.init) == file.bytes, try hash(url) == file.sha256 else {
            throw BenchmarkFailure.message("Artifact size or checksum mismatch: \(file.file)")
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet].contains(value.code)
    }

    static func downloadVerified(_ file: ArtifactFile, artifactID: String, destination: URL,
                                 cancellation: Cancellation, progress: @escaping @Sendable (String) -> Void,
                                 download: @escaping Download = { try await URLSession.shared.download(for: $0) },
                                 pause: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
                                 observe: Observe = { _ in }) async throws {
        guard let url = file.url else { throw BenchmarkFailure.message("Mixed local and remote artifact files") }
        // Re-resolve the pinned Hub address on each attempt. Never reuse an expiring CDN redirect.
        for attempt in 1...3 {
            try cancellation.check()
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 1800
            progress("Downloading \(artifactID): \(file.file), attempt \(attempt)/3")
            let began = DispatchTime.now().uptimeNanoseconds
            func event(_ outcome: String, response: HTTPURLResponse? = nil, bytes: Int64? = nil,
                       error: Error? = nil) throws {
                let value = error.map { $0 as NSError }
                let failedURL = value?.userInfo[NSURLErrorFailingURLErrorKey] as? URL
                // Retain diagnostic hosts and codes, never signed query strings or localized errors.
                try observe(AcquisitionEvent(artifactID: artifactID, file: file.file, attempt: attempt,
                    outcome: outcome, sourceHost: url.host, responseHost: response?.url?.host ?? failedURL?.host,
                    statusCode: response?.statusCode, receivedFileBytes: bytes,
                    elapsedMs: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000,
                    errorDomain: value?.domain, errorCode: value?.code))
            }
            try event("started")
            let transfer = Task { try await download(request) }
            cancellation.install { transfer.cancel() }
            let result: (URL, URLResponse)
            do {
                result = try await withTaskCancellationHandler(operation: { try await transfer.value },
                                                              onCancel: { transfer.cancel() })
            } catch {
                cancellation.install(nil)
                let cancelled = cancellation.isCancelled || Task.isCancelled || error is CancellationError
                    || (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
                try event(cancelled ? "cancelled" : "transport-failed", error: error)
                if cancelled { throw CancellationError() }
                guard attempt < 3, isRetryable(error) else { throw error }
                progress("Retrying \(artifactID): \(file.file) after transport failure")
                let delay = Task { try await pause(UInt64(attempt) * 1_000_000_000) }
                cancellation.install { delay.cancel() }
                defer { cancellation.install(nil) }
                try await withTaskCancellationHandler(operation: { try await delay.value }, onCancel: { delay.cancel() })
                continue
            }
            cancellation.install(nil)
            let (temporary, response) = result
            defer { try? FileManager.default.removeItem(at: temporary) }
            try cancellation.check()
            try Task.checkCancellation()
            let http = response as? HTTPURLResponse
            let bytes = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            guard http?.statusCode == 200 else {
                try event("http-rejected", response: http, bytes: bytes)
                throw BenchmarkFailure.message("Download HTTP status \(http?.statusCode ?? -1) for \(file.file)")
            }
            do { try verify(temporary, file: file) } catch {
                try event("integrity-rejected", response: http, bytes: bytes, error: error)
                throw error
            }
            try cancellation.check()
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            try event("download-verified", response: http, bytes: bytes)
            return
        }
    }

    static func prepare(_ artifact: Artifact, cancellation: Cancellation,
                        progress: @escaping @Sendable (String) -> Void,
                        allowDownload: Bool = true,
                        observe: Observe = { _ in }) async throws -> URL {
        let bundled = artifact.files.allSatisfy { $0.url == nil }
        let root = bundled
            ? Bundle.main.resourceURL!.appendingPathComponent("Models/\(artifact.id)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Models/\(artifact.id)/\(artifact.revision)")
        if !bundled {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = root; try excluded.setResourceValues(values)
        }
        for file in artifact.files {
            try cancellation.check()
            let destination = root.appendingPathComponent(file.file)
            let began = DispatchTime.now().uptimeNanoseconds
            if bundled || (FileManager.default.fileExists(atPath: destination.path) && (try? verify(destination, file: file)) != nil) {
                if bundled { try verify(destination, file: file) }
                try cancellation.check()
                try observe(AcquisitionEvent(artifactID: artifact.id, file: file.file, attempt: 0,
                    outcome: bundled ? "bundle-verified" : "cache-verified", sourceHost: file.url?.host,
                    responseHost: nil, statusCode: nil, receivedFileBytes: file.bytes,
                    elapsedMs: Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000,
                    errorDomain: nil, errorCode: nil))
            } else {
                guard allowDownload else {
                    throw BenchmarkFailure.message("Verified model cache missing: \(file.file). Run publication acquisition before measurement.")
                }
                try await downloadVerified(file, artifactID: artifact.id, destination: destination,
                                           cancellation: cancellation, progress: progress, observe: observe)
            }
        }
        return root
    }
}
