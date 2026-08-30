import Foundation
import Diagnostics

/// Minimal, read-only tar reader for the payload found inside UniFi OS
/// **console** `.unifi` containers (AES-256 → gzip → tar).
///
/// Handles the two shapes UniFi's console emits:
///   * **ustar** headers (POSIX), including the `prefix` field for long paths;
///   * **GNU long name** (`L` typeflag) records, where the file name is stored
///     in a preceding entry's data rather than the 100-byte `name` field.
///
/// It is deliberately tolerant: on a truncated archive, a header whose checksum
/// does not validate, or an entry whose data overruns the buffer, it emits a
/// diagnostic and stops rather than crashing. It never force-unwraps and every
/// read is bounds-checked. Directory entries, pax extended headers (`x`/`g`)
/// and long-link records (`K`) are skipped; only regular files are returned.
public struct TarReader {
    public struct Entry: Sendable {
        public let name: String
        public let data: Data
        public init(name: String, data: Data) { self.name = name; self.data = data }
    }

    /// Files in archive order.
    public let entries: [Entry]
    /// The same files keyed by name (last one wins on a duplicate path).
    public let map: [String: Data]
    public let diagnostics: [Diagnostic]

    private static let blockSize = 512

    public init(_ input: Data) {
        // Bug 7 hardening: rebind to a zero-based buffer so absolute indexing is
        // correct even when a `Data` slice (nonzero `startIndex`) is passed.
        let base = input.startIndex == 0 ? input : Data(input)

        var entries: [Entry] = []
        var map: [String: Data] = [:]
        var diags: [Diagnostic] = []

        var cursor = 0
        var pendingLongName: String? = nil

        while cursor + Self.blockSize <= base.count {
            // A zero-filled block marks the end of the archive.
            if Self.isZeroBlock(base, at: cursor) {
                break
            }

            guard Self.checksumValid(base, at: cursor) else {
                diags.append(
                    Diagnostic(
                        severity: .warning,
                        code: .zipEntryUnreadable,
                        message: "tar header checksum mismatch at offset \(cursor); stopping.",
                        offset: cursor
                    )
                )
                break
            }

            let size = Self.parseOctal(base, cursor + 124, 12)
            let typeflag = base[cursor + 156]
            let dataStart = cursor + Self.blockSize
            let dataEnd = dataStart + size

            guard size >= 0, dataEnd <= base.count else {
                diags.append(
                    Diagnostic(
                        severity: .warning,
                        code: .zipEntryUnreadable,
                        message: "tar entry at offset \(cursor) declares size \(size) that overruns the archive; stopping.",
                        offset: cursor
                    )
                )
                break
            }

            // Advance past this header + its (block-padded) data.
            let nextCursor = dataStart + Self.roundUpToBlock(size)

            switch typeflag {
            case 0x4C: // 'L' — GNU long name; data holds the name for the NEXT header.
                let nameData = base.subdata(in: dataStart..<dataEnd)
                pendingLongName = Self.decodeCString(nameData)
            case 0x78, 0x67, 0x4B: // 'x','g' pax extended headers, 'K' long link — skip.
                pendingLongName = nil
            case 0x35: // '5' — directory; nothing to surface.
                pendingLongName = nil
            case 0x30, 0x00: // '0' or NUL — regular file.
                let name = pendingLongName ?? Self.readName(base, at: cursor)
                pendingLongName = nil
                if !name.isEmpty, !name.hasSuffix("/") {
                    let fileData = base.subdata(in: dataStart..<dataEnd)
                    entries.append(Entry(name: name, data: fileData))
                    map[name] = fileData
                }
            default:
                // Unknown/other type (symlink, char/block dev, fifo…): skip data.
                pendingLongName = nil
            }

            // Defensive: a header that fails to advance would loop forever.
            guard nextCursor > cursor else { break }
            cursor = nextCursor
        }

        self.entries = entries
        self.map = map
        self.diagnostics = diags
    }

    // MARK: - Header helpers (all indices absolute into the zero-based buffer)

    private static func isZeroBlock(_ data: Data, at start: Int) -> Bool {
        for i in start..<(start + blockSize) where data[i] != 0 { return false }
        return true
    }

    /// Validates the 8-byte header checksum (offset 148). Accepts both the
    /// unsigned and signed interpretations to tolerate historical GNU tars.
    private static func checksumValid(_ data: Data, at start: Int) -> Bool {
        let stored = parseOctal(data, start + 148, 8)
        var unsigned = 0
        var signed = 0
        for i in start..<(start + blockSize) {
            // The checksum field itself is treated as spaces during the sum.
            let byte: UInt8 = (i >= start + 148 && i < start + 156) ? 0x20 : data[i]
            unsigned += Int(byte)
            signed += Int(Int8(bitPattern: byte))
        }
        return unsigned == stored || signed == stored
    }

    /// Reads the entry name from the ustar `name` (100) + `prefix` (155) fields.
    private static func readName(_ data: Data, at headerStart: Int) -> String {
        let name = cString(data, headerStart, 100)
        let prefix = cString(data, headerStart + 345, 155)
        if !prefix.isEmpty {
            return prefix + "/" + name
        }
        return name
    }

    /// Parses an octal ASCII field (leading spaces/NUL skipped, digits until the
    /// first non-octal byte). Returns 0 on an empty/garbage field.
    private static func parseOctal(_ data: Data, _ start: Int, _ len: Int) -> Int {
        var value = 0
        var i = start
        let end = start + len
        while i < end, data[i] == 0x20 || data[i] == 0 { i += 1 }
        while i < end, data[i] >= 0x30, data[i] <= 0x37 {
            value = value * 8 + Int(data[i] - 0x30)
            i += 1
        }
        return value
    }

    /// Decodes a fixed-width NUL-terminated field into a String.
    private static func cString(_ data: Data, _ start: Int, _ maxLen: Int) -> String {
        var endIndex = start
        let hardEnd = start + maxLen
        while endIndex < hardEnd, data[endIndex] != 0 { endIndex += 1 }
        let slice = data.subdata(in: start..<endIndex)
        return String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
    }

    /// Decodes a NUL-terminated blob (GNU long name) into a String.
    private static func decodeCString(_ data: Data) -> String {
        var slice = data
        if let nul = data.firstIndex(of: 0) {
            slice = data.subdata(in: data.startIndex..<nul)
        }
        return String(data: slice, encoding: .utf8)
            ?? String(data: slice, encoding: .isoLatin1)
            ?? ""
    }

    private static func roundUpToBlock(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        return ((n + blockSize - 1) / blockSize) * blockSize
    }
}
