import Foundation
import Compression
import Diagnostics

/// Decompresses a gzip stream using Apple's `Compression` framework.
///
/// `compression_stream` speaks raw DEFLATE via `COMPRESSION_ZLIB`; we strip the
/// gzip header and trailer ourselves.
public enum Gunzip {
    /// RFC 1952 gzip magic.
    public static let magic: [UInt8] = [0x1f, 0x8b]

    public enum Error: Swift.Error, Sendable, Hashable {
        case notGzip
        case unsupportedCompressionMethod(UInt8)
        case truncatedHeader
        case decompressionFailed
        case truncatedStream
    }

    public static func decompress(_ gz: Data) throws -> Data {
        guard gz.count >= 18, gz[0] == 0x1f, gz[1] == 0x8b else {
            throw Error.notGzip
        }
        guard gz[2] == 0x08 else {
            throw Error.unsupportedCompressionMethod(gz[2])
        }
        let flg = gz[3]
        var cursor = 10 // fixed header size

        // FEXTRA
        if (flg & 0x04) != 0 {
            guard cursor + 2 <= gz.count else { throw Error.truncatedHeader }
            let xlen = Int(gz[cursor]) | (Int(gz[cursor + 1]) << 8)
            cursor += 2 + xlen
            guard cursor <= gz.count else { throw Error.truncatedHeader }
        }
        // FNAME — NUL terminated
        if (flg & 0x08) != 0 {
            while cursor < gz.count, gz[cursor] != 0 { cursor += 1 }
            guard cursor < gz.count else { throw Error.truncatedHeader }
            cursor += 1
        }
        // FCOMMENT
        if (flg & 0x10) != 0 {
            while cursor < gz.count, gz[cursor] != 0 { cursor += 1 }
            guard cursor < gz.count else { throw Error.truncatedHeader }
            cursor += 1
        }
        // FHCRC
        if (flg & 0x02) != 0 {
            cursor += 2
            guard cursor <= gz.count else { throw Error.truncatedHeader }
        }

        // Trailer is last 8 bytes: CRC32 (4) + ISIZE (4).
        guard gz.count - cursor >= 8 else { throw Error.truncatedStream }
        let trailerStart = gz.count - 8
        let compressedStart = cursor
        let compressedEnd = trailerStart
        guard compressedEnd >= compressedStart else { throw Error.truncatedStream }

        let deflate = gz.subdata(in: compressedStart..<compressedEnd)

        // ISIZE is "uncompressed size mod 2^32" — only a hint; don't trust it
        // for very large inputs, but it's a fine initial capacity.
        let isize =
            UInt32(gz[trailerStart + 4])
            | (UInt32(gz[trailerStart + 5]) << 8)
            | (UInt32(gz[trailerStart + 6]) << 16)
            | (UInt32(gz[trailerStart + 7]) << 24)

        return try inflate(deflate: deflate, estimatedSize: Int(isize))
    }

    /// Raw DEFLATE inflation via `compression_stream` / `COMPRESSION_ZLIB`.
    ///
    /// We intentionally avoid the one-shot `compression_decode_buffer` API
    /// because it requires a pre-sized destination. Streaming handles unknown
    /// output sizes and avoids over-allocation on very small inputs.
    private static func inflate(deflate: Data, estimatedSize: Int) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0),
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )

        var status = compression_stream_init(
            &stream,
            COMPRESSION_STREAM_DECODE,
            COMPRESSION_ZLIB
        )
        guard status != COMPRESSION_STATUS_ERROR else { throw Error.decompressionFailed }
        defer { compression_stream_destroy(&stream) }

        let bufSize = max(64 * 1024, estimatedSize > 0 ? min(estimatedSize, 4 * 1024 * 1024) : 64 * 1024)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }

        var output = Data()
        output.reserveCapacity(max(bufSize, estimatedSize))

        try deflate.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Void in
            guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw Error.decompressionFailed
            }
            stream.src_ptr = srcBase
            stream.src_size = src.count

            repeat {
                stream.dst_ptr = dst
                stream.dst_size = bufSize

                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = bufSize - stream.dst_size
                    if produced > 0 {
                        output.append(dst, count: produced)
                    }
                case COMPRESSION_STATUS_ERROR:
                    throw Error.decompressionFailed
                default:
                    throw Error.decompressionFailed
                }
            } while status == COMPRESSION_STATUS_OK
        }

        return output
    }
}
