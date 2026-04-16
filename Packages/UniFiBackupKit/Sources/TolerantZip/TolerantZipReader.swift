import Foundation
import Compression
import Diagnostics

/// Streaming ZIP reader tolerant of malformed EOCD and data-descriptor records.
///
/// UniFi `.unf` inner ZIPs frequently ship with:
///   * a truncated or missing End Of Central Directory (EOCD)
///   * streaming data descriptors (general-purpose flag bit 3 set), where local
///     headers carry zero CRC/size and real values follow the compressed bytes
///
/// Standard Foundation / Compression-framework ZIP readers fail on these.
/// This reader deliberately ignores the central directory and scans forward
/// through local-file-header signatures instead. It handles STORED (method 0)
/// and DEFLATE (method 8), the only methods produced by the controller.
public struct TolerantZipReader {
    public struct Entry: Sendable {
        public let name: String
        public let data: Data
    }

    public let entries: [String: Entry]
    public let diagnostics: [Diagnostic]

    public init(_ data: Data) throws {
        var entries: [String: Entry] = [:]
        var diags: [Diagnostic] = []
        let base = data
        var cursor = 0

        while cursor + 30 <= base.count {
            // Local file header signature: 0x04034b50 ('P','K',3,4)
            let sig =
                UInt32(base[cursor])
                | (UInt32(base[cursor + 1]) << 8)
                | (UInt32(base[cursor + 2]) << 16)
                | (UInt32(base[cursor + 3]) << 24)
            if sig != 0x04034b50 {
                // Done — we either hit a central-directory signature (0x02014b50),
                // EOCD (0x06054b50), or noise at end of file.
                break
            }

            // Parse local header.
            let gpFlag = UInt16(base[cursor + 6]) | (UInt16(base[cursor + 7]) << 8)
            let method = UInt16(base[cursor + 8]) | (UInt16(base[cursor + 9]) << 8)
            var compSize: Int = Int(
                UInt32(base[cursor + 18])
                | (UInt32(base[cursor + 19]) << 8)
                | (UInt32(base[cursor + 20]) << 16)
                | (UInt32(base[cursor + 21]) << 24)
            )
            var uncompSize: Int = Int(
                UInt32(base[cursor + 22])
                | (UInt32(base[cursor + 23]) << 8)
                | (UInt32(base[cursor + 24]) << 16)
                | (UInt32(base[cursor + 25]) << 24)
            )
            let nameLen = Int(UInt16(base[cursor + 26]) | (UInt16(base[cursor + 27]) << 8))
            let extraLen = Int(UInt16(base[cursor + 28]) | (UInt16(base[cursor + 29]) << 8))
            let nameStart = cursor + 30
            let extraStart = nameStart + nameLen
            let dataStart = extraStart + extraLen
            guard dataStart <= base.count else {
                diags.append(
                    Diagnostic(
                        severity: .warning,
                        code: .zipEntryUnreadable,
                        message: "Local header truncated at offset \(cursor); stopping scan.",
                        offset: cursor
                    )
                )
                break
            }

            // Filename — UTF-8 if GP flag bit 11 set, else CP-437 (approx ASCII).
            let nameData = base.subdata(in: nameStart..<extraStart)
            let name: String
            if (gpFlag & 0x0800) != 0 {
                name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            } else {
                name = String(data: nameData, encoding: .isoLatin1) ?? String(decoding: nameData, as: UTF8.self)
            }

            let usesDataDescriptor = (gpFlag & 0x0008) != 0
            var payloadEnd: Int = dataStart + compSize

            if usesDataDescriptor && compSize == 0 {
                // CRC and sizes follow the compressed data. We must scan forward
                // to find the data descriptor (optional signature 0x08074b50)
                // *or* the next local file header / central directory entry.
                guard let found = Self.findEndOfDeflatedPayload(
                    in: base,
                    from: dataStart
                ) else {
                    diags.append(
                        Diagnostic(
                            severity: .warning,
                            code: .zipEntryUnreadable,
                            message: "Could not locate data descriptor for \(name); stopping scan.",
                            offset: cursor
                        )
                    )
                    break
                }
                payloadEnd = found.payloadEnd
                compSize = payloadEnd - dataStart
                // If the descriptor carried a valid uncomp size, pick it up.
                if let declaredUncomp = found.declaredUncompressedSize {
                    uncompSize = declaredUncomp
                }
            }

            guard payloadEnd <= base.count else {
                diags.append(
                    Diagnostic(
                        severity: .warning,
                        code: .zipEntryUnreadable,
                        message: "Declared compressed length overruns file for \(name).",
                        offset: cursor
                    )
                )
                break
            }

            let payload = base.subdata(in: dataStart..<payloadEnd)

            do {
                let decoded: Data
                switch method {
                case 0:
                    decoded = payload
                case 8:
                    decoded = try Self.inflateRaw(payload, estimatedSize: uncompSize)
                default:
                    diags.append(
                        Diagnostic(
                            severity: .warning,
                            code: .zipEntryUnreadable,
                            message: "Unsupported ZIP compression method \(method) for \(name).",
                            offset: cursor
                        )
                    )
                    cursor = payloadEnd + (usesDataDescriptor ? 16 : 0)
                    continue
                }

                if !name.hasSuffix("/") {
                    // Skip directory entries.
                    entries[name] = Entry(name: name, data: decoded)
                }
            } catch {
                diags.append(
                    Diagnostic(
                        severity: .warning,
                        code: .zipEntryUnreadable,
                        message: "Failed to inflate entry '\(name)': \(error).",
                        offset: cursor
                    )
                )
            }

            // Advance past the payload and (if present) the 12/16-byte data descriptor.
            cursor = payloadEnd
            if usesDataDescriptor {
                // Optional descriptor signature + CRC32(4) + compSize(4) + uncompSize(4)
                if cursor + 4 <= base.count,
                   base[cursor] == 0x50,
                   base[cursor + 1] == 0x4b,
                   base[cursor + 2] == 0x07,
                   base[cursor + 3] == 0x08 {
                    cursor += 16
                } else {
                    cursor += 12
                }
            }
        }

        if entries.isEmpty {
            throw FatalBackupError.zipUnreadable(
                detail: "No readable entries found."
            )
        }

        if !diags.isEmpty {
            diags.insert(
                Diagnostic(
                    severity: .info,
                    code: .zipRecoveryMode,
                    message: "ZIP read in recovery mode (\(diags.count) warnings). Contents were recovered via local-header scan.",
                    offset: nil
                ),
                at: 0
            )
        }

        self.entries = entries
        self.diagnostics = diags
    }

    // MARK: - Private helpers

    /// When a local header sets the "data descriptor" flag with zero sizes, we
    /// must scan forward to find the end of the deflated payload. Strategy:
    /// look for the data-descriptor signature (0x08074b50) followed by a
    /// plausible CRC+sizes that's immediately followed by either another local
    /// file header, the central directory, or EOF. Fall back to searching for
    /// the next local file header signature and assuming an implicit
    /// descriptor preceded it.
    private static func findEndOfDeflatedPayload(
        in data: Data,
        from start: Int
    ) -> (payloadEnd: Int, declaredUncompressedSize: Int?)? {
        // Walk forward. This is O(n) per entry but zipped UniFi payloads are at
        // most a few hundred MB decompressed; perfectly acceptable for a
        // correctness-over-speed recovery path.
        var i = start
        while i + 4 <= data.count {
            let s0 = data[i]
            let s1 = data[i + 1]
            let s2 = data[i + 2]
            let s3 = data[i + 3]
            // Data descriptor signature? PK\x07\x08
            if s0 == 0x50, s1 == 0x4b, s2 == 0x07, s3 == 0x08 {
                // payloadEnd is at `i`; descriptor is (sig)+CRC+CS+UCS = 16
                guard i + 16 <= data.count else { return (i, nil) }
                let ucs =
                    UInt32(data[i + 12])
                    | (UInt32(data[i + 13]) << 8)
                    | (UInt32(data[i + 14]) << 16)
                    | (UInt32(data[i + 15]) << 24)
                return (i, Int(ucs))
            }
            // Next local file header? PK\x03\x04 — then the preceding 12 bytes
            // are the descriptor without signature.
            if s0 == 0x50, s1 == 0x4b, s2 == 0x03, s3 == 0x04 {
                let descriptorStart = i - 12
                if descriptorStart >= start {
                    let ucs =
                        UInt32(data[descriptorStart + 8])
                        | (UInt32(data[descriptorStart + 9]) << 8)
                        | (UInt32(data[descriptorStart + 10]) << 16)
                        | (UInt32(data[descriptorStart + 11]) << 24)
                    return (descriptorStart, Int(ucs))
                }
                return (i, nil)
            }
            // Central directory? PK\x01\x02
            if s0 == 0x50, s1 == 0x4b, s2 == 0x01, s3 == 0x02 {
                let descriptorStart = i - 12
                if descriptorStart >= start {
                    let ucs =
                        UInt32(data[descriptorStart + 8])
                        | (UInt32(data[descriptorStart + 9]) << 8)
                        | (UInt32(data[descriptorStart + 10]) << 16)
                        | (UInt32(data[descriptorStart + 11]) << 24)
                    return (descriptorStart, Int(ucs))
                }
                return (i, nil)
            }
            i += 1
        }
        return (data.count, nil)
    }

    /// Raw DEFLATE inflation (no zlib wrapper, no gzip wrapper).
    static func inflateRaw(_ src: Data, estimatedSize: Int) throws -> Data {
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
        guard status != COMPRESSION_STATUS_ERROR else {
            throw FatalBackupError.zipUnreadable(detail: "compression_stream_init failed")
        }
        defer { compression_stream_destroy(&stream) }

        let bufSize = max(64 * 1024, min(estimatedSize, 4 * 1024 * 1024))
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }

        var output = Data()
        output.reserveCapacity(max(bufSize, estimatedSize))

        try src.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Void in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw FatalBackupError.zipUnreadable(detail: "empty src")
            }
            stream.src_ptr = base
            stream.src_size = buf.count

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
                    throw FatalBackupError.zipUnreadable(detail: "DEFLATE failed")
                default:
                    throw FatalBackupError.zipUnreadable(detail: "unknown compression status")
                }
            } while status == COMPRESSION_STATUS_OK
        }
        return output
    }
}
