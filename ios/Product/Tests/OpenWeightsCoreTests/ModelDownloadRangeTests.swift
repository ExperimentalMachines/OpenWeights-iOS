import XCTest
@testable import OpenWeightsCore

final class ModelDownloadRangeTests: XCTestCase {
    func testKnownBackgroundFileUsesRemainingRangeAndForegroundKeepsCheckpoint() throws {
        let bytes: Int64 = 1107613952, chunk: Int64 = 33554432
        XCTAssertEqual(try ModelDownloadRange.header(offset: 0, total: bytes, chunkBytes: chunk, background: true), "bytes=0-1107613951")
        XCTAssertEqual(try ModelDownloadRange.header(offset: chunk, total: bytes, chunkBytes: chunk, background: true), "bytes=33554432-1107613951")
        XCTAssertEqual(try ModelDownloadRange.header(offset: chunk, total: bytes, chunkBytes: chunk, background: false), "bytes=33554432-67108863")
        XCTAssertEqual(try ModelDownloadRange.header(offset: 1107296256, total: bytes, chunkBytes: chunk, background: false), "bytes=1107296256-1107613951")
    }
    func testUnknownSizesRemainBoundedAndInvalidCheckpointsRefuse() throws {
        XCTAssertEqual(try ModelDownloadRange.header(offset: 33554432, total: nil, chunkBytes: 33554432, background: true), "bytes=33554432-67108863")
        for (offset, total, chunk) in [(Int64(-1), Int64(10), Int64(4)), (0, 0, 4), (10, 10, 4), (11, 10, 4), (0, 10, 0)] {
            XCTAssertThrowsError(try ModelDownloadRange.header(offset: offset, total: total, chunkBytes: chunk, background: true))
        }
    }
    func testRangeArithmeticDoesNotOverflowNearInt64Limit() throws {
        XCTAssertEqual(try ModelDownloadRange.header(offset: Int64.max - 10, total: Int64.max, chunkBytes: 32, background: false), "bytes=9223372036854775797-9223372036854775806")
        XCTAssertEqual(try ModelDownloadRange.header(offset: Int64.max - 1, total: nil, chunkBytes: Int64.max, background: true), "bytes=9223372036854775806-9223372036854775806")
        XCTAssertThrowsError(try ModelDownloadRange.header(offset: Int64.max, total: nil, chunkBytes: 1, background: true))
    }
}
