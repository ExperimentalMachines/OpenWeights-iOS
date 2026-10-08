import Foundation
import zlib

enum WebGzip {
    /// Decode a fully framed gzip body. A bounded prefix need not reach the final checksum.
    static func decode(_ input: Data, maximumBytes: Int) throws -> (body: Data, complete: Bool) {
        guard let decoded = try inflate(input, maximumBytes: maximumBytes, wireComplete: true) else {
            throw PublicWebError.refused("The gzip page is damaged or incomplete.")
        }
        return decoded
    }
    /// Return only once enough decoded text exists to stop an unfinished wire transfer.
    static func prefix(_ input: Data, maximumBytes: Int) throws -> Data? {
        try inflate(input, maximumBytes: maximumBytes, wireComplete: false)?.body
    }
    private static func inflate(_ input: Data, maximumBytes: Int, wireComplete: Bool) throws -> (body: Data, complete: Bool)? {
        guard input.count <= 4_194_304 + 262_144 else { throw PublicWebError.refused("The compressed page exceeds its transfer limit.") }
        let limit = min(4_194_304, max(1, maximumBytes))
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PublicWebError.refused("The gzip decoder could not start.")
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var output = Data(); var members = 1
            while true {
                try Task.checkCancellation()
                let capacity = min(16_384, limit + 1 - output.count)
                var chunk = [UInt8](repeating: 0, count: capacity)
                let inputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = capacity - Int(stream.avail_out)
                if !wireComplete && status == Z_BUF_ERROR && stream.avail_in == 0 { return nil }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw PublicWebError.refused("The gzip page is damaged or incomplete.")
                }
                output.append(contentsOf: chunk.prefix(produced))
                if output.count > limit { return (Data(output.prefix(limit)), false) }
                if status == Z_STREAM_END {
                    if stream.avail_in == 0 { return wireComplete ? (output, true) : nil }
                    members += 1
                    guard members <= 32, inflateReset2(&stream, 31) == Z_OK else {
                        throw PublicWebError.refused("The gzip page has too many compressed members.")
                    }
                } else if produced == 0 && inputBefore == stream.avail_in {
                    if !wireComplete && stream.avail_in == 0 { return nil }
                    throw PublicWebError.refused("The gzip page is damaged or incomplete.")
                }
            }
        }
    }
}
