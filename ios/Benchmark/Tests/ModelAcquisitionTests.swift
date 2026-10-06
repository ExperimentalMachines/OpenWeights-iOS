import CryptoKit
import XCTest
@testable import OpenWeightsBench

final class ModelAcquisitionTests: XCTestCase {
    private let pinned = URL(string: "https://huggingface.co/fixture/resolve/pinned/model.gguf")!
    private let payload = Data("verified model fixture".utf8)

    private func fixture() throws -> (URL, ArtifactFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return (root, ArtifactFile(file: "model.gguf", sha256: hash, bytes: Int64(payload.count), url: pinned))
    }

    private func response(_ root: URL, status: Int = 200, corrupt: Bool = false) throws -> (URL, URLResponse) {
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try (corrupt ? Data("corrupt".utf8) : payload).write(to: temporary)
        let cdn = URL(string: "https://cdn.huggingface.co/model?Signature=must-not-be-recorded")!
        return (temporary, HTTPURLResponse(url: cdn, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func testTimeoutRetriesPinnedURLAndVerifiesFreshDownload() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, delays: [UInt64] = [], events: [AcquisitionEvent] = []
        let destination = root.appendingPathComponent(file.file)
        try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: destination,
            cancellation: Cancellation(), progress: { _ in }, download: { request in
                calls += 1
                XCTAssertEqual(request.url, self.pinned)
                XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                XCTAssertEqual(request.timeoutInterval, 1800)
                if calls == 1 {
                    throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                        userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://cdn.huggingface.co/model?Signature=secret")!])
                }
                return try self.response(root)
            }, pause: { delays.append($0) }, observe: { events.append($0) })
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(delays, [1_000_000_000])
        XCTAssertEqual(events.map(\.outcome), ["started", "transport-failed", "started", "download-verified"])
        XCTAssertEqual(events.map(\.attempt), [1, 1, 2, 2])
        XCTAssertEqual(events[1].responseHost, "cdn.huggingface.co")
        XCTAssertEqual(events.last?.receivedFileBytes, file.bytes)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Signature"))
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [file.file])
    }

    func testPersistentTransportFailureStopsAfterThreeAttempts() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0, delays: [UInt64] = [], events: [AcquisitionEvent] = []
        do {
            try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: root.appendingPathComponent(file.file),
                cancellation: Cancellation(), progress: { _ in }, download: { _ in
                    calls += 1
                    throw URLError(.cannotConnectToHost)
                }, pause: { delays.append($0) }, observe: { events.append($0) })
            XCTFail("Persistent failure must be thrown")
        } catch { XCTAssertEqual((error as NSError).code, NSURLErrorCannotConnectToHost) }
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(delays, [1_000_000_000, 2_000_000_000])
        XCTAssertEqual(events.filter { $0.outcome == "transport-failed" }.count, 3)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testTLSFailureIsNotRetried() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var calls = 0
        do {
            try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: root.appendingPathComponent(file.file),
                cancellation: Cancellation(), progress: { _ in }, download: { _ in
                    calls += 1
                    throw URLError(.serverCertificateUntrusted)
                }, pause: { _ in XCTFail("TLS must not retry") })
            XCTFail("TLS failure must be thrown")
        } catch { XCTAssertEqual((error as NSError).code, NSURLErrorServerCertificateUntrusted) }
        XCTAssertEqual(calls, 1)
    }

    func testHTTPAndIntegrityFailuresDoNotRetryOrCommit() async throws {
        for (status, corrupt, outcome) in [(403, false, "http-rejected"), (200, true, "integrity-rejected")] {
            let (root, file) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var calls = 0, events: [AcquisitionEvent] = []
            do {
                try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: root.appendingPathComponent(file.file),
                    cancellation: Cancellation(), progress: { _ in }, download: { _ in
                        calls += 1
                        return try self.response(root, status: status, corrupt: corrupt)
                    }, pause: { _ in XCTFail("HTTP/integrity must not retry") }, observe: { events.append($0) })
                XCTFail("Invalid response must be thrown")
            } catch { XCTAssertTrue(error is BenchmarkFailure) }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(events.last?.outcome, outcome)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testCancellationDuringBackoffStopsBeforeRetry() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cancellation = Cancellation()
        var calls = 0
        do {
            try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: root.appendingPathComponent(file.file),
                cancellation: cancellation, progress: { _ in }, download: { _ in
                    calls += 1
                    throw URLError(.timedOut)
                }, pause: { _ in
                    cancellation.cancel()
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                })
            XCTFail("Cancellation must be thrown")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCancellationDuringTransferStopsBeforeCommit() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cancellation = Cancellation()
        var events: [AcquisitionEvent] = []
        do {
            try await ModelStore.downloadVerified(file, artifactID: "fixture", destination: root.appendingPathComponent(file.file),
                cancellation: cancellation, progress: { _ in }, download: { _ in
                    cancellation.cancel()
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return try self.response(root)
                }, observe: { events.append($0) })
            XCTFail("Cancellation must be thrown")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events.last?.outcome, "cancelled")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
