import XCTest
@testable import OpenWeightsCore

final class GGUFRangePolicyTests: XCTestCase {
    func testPinnedRevisionAndSafePath() throws {
        let revision = String(repeating: "a", count: 40)
        let url = try GGUFRangePolicy.pinnedURL(repository: "org/model", revision: revision, path: "folder/model #1.gguf")
        XCTAssertEqual(url.path, "/org/model/resolve/\(revision)/folder/model #1.gguf")
        XCTAssertNil(url.query); XCTAssertNil(url.fragment)
        for path in ["../escape.gguf", "/absolute.gguf", "a//b.gguf", "a/./b.gguf", "a\\b.gguf", "a:b.gguf", "a\0b.gguf"] {
            XCTAssertThrowsError(try GGUFRangePolicy.pinnedURL(repository: "org/model", revision: revision, path: path))
        }
        for repository in ["../org", "org/model/extra", "org@host/model"] {
            XCTAssertThrowsError(try GGUFRangePolicy.pinnedURL(repository: repository, revision: revision, path: "m.gguf"))
        }
        for invalid in ["main", String(repeating: "g", count: 40), revision + "a"] {
            XCTAssertThrowsError(try GGUFRangePolicy.pinnedURL(repository: "org/model", revision: invalid, path: "m.gguf"))
        }
    }
    func testOnlyHTTPSHubOwnedRedirectHosts() {
        for address in ["https://huggingface.co/file", "https://us.aws.cdn.hf.co/file?signature=private", "https://cas-bridge.xethub.hf.co/file", "https://cdn-lfs-us-1.hf.co/file"] {
            XCTAssertTrue(GGUFRangePolicy.allowedRedirect(URL(string: address)!))
        }
        for address in ["http://huggingface.co/file", "https://huggingface.co.evil.example/file", "https://evil-hf.co/file", "https://x.hf.space/file", "https://user:secret@huggingface.co/file", "https://hf.co:444/file", "https://example.com/file"] {
            XCTAssertFalse(GGUFRangePolicy.allowedRedirect(URL(string: address)!))
        }
    }
    func testRangesAndFinalShortResponse() throws {
        let result = try GGUFRangePolicy.validate(status: 206, contentRange: "bytes 128-255/1000", contentLength: 128, encoding: nil, offset: 128, length: 128, expectedTotal: 1000)
        XCTAssertEqual(result.bytes, 128); XCTAssertEqual(result.total, 1000)
        let final = try GGUFRangePolicy.validate(status: 206, contentRange: "bytes 900-999/1000", contentLength: nil, encoding: "identity", offset: 900, length: 128, expectedTotal: nil)
        XCTAssertEqual(final.bytes, 100); XCTAssertEqual(final.total, 1000)
        let whole = try GGUFRangePolicy.validate(status: 200, contentRange: nil, contentLength: 80, encoding: nil, offset: 0, length: 128, expectedTotal: 80)
        XCTAssertEqual(whole.bytes, 80)
    }
    func testRefusesIgnoredCompressedChangedTruncatedAndOversizedFraming() {
        for range in ["bytes 1-128/1000", "bytes 0-128/1000", "bytes 0-126/1000", "bytes 0-127/*", "bytes 0-127/100", "bytes 0-127/9223372036854775808", "garbage"] {
            XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 206, contentRange: range, contentLength: nil, encoding: nil, offset: 0, length: 128, expectedTotal: nil))
        }
        for status in [200, 301, 302, 401, 403, 404, 416, 500] {
            XCTAssertThrowsError(try GGUFRangePolicy.validate(status: status, contentRange: nil, contentLength: 1_000_000, encoding: nil, offset: 0, length: 128, expectedTotal: nil))
        }
        XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 200, contentRange: nil, contentLength: nil, encoding: nil, offset: 0, length: 128, expectedTotal: nil))
        XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 200, contentRange: nil, contentLength: 128, encoding: nil, offset: 128, length: 128, expectedTotal: nil))
        XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 206, contentRange: "bytes 0-127/1000", contentLength: 127, encoding: nil, offset: 0, length: 128, expectedTotal: 1000))
        XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 206, contentRange: "bytes 0-127/1000", contentLength: 128, encoding: "gzip", offset: 0, length: 128, expectedTotal: 1000))
        XCTAssertThrowsError(try GGUFRangePolicy.validate(status: 206, contentRange: "bytes 0-127/1000", contentLength: 128, encoding: nil, offset: 0, length: 128, expectedTotal: 1001))
    }
    func testRejectsInvalidAndOverflowingRequestRanges() {
        for pair in [(Int64(-1), 128), (Int64(0), 0), (Int64(0), 1_048_577), (Int64.max, 1), (Int64.max - 10, 128)] {
            XCTAssertThrowsError(try GGUFRangePolicy.rangeEnd(offset: pair.0, length: pair.1))
        }
    }
}
