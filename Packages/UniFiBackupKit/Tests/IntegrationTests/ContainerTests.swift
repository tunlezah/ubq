import XCTest
@testable import UniFiBackupKit
import UnfCrypto

/// Container-shape detection tests: `.supp` support bundles (AES-128 → ZIP with
/// no configuration DB) and the AES-256 UniFi OS console `.unifi` shape (key
/// verified and enabled; a wrong-content file fails cleanly at the gzip check).
///
/// (Does not touch the other files in this target — see SyntheticFixture /
/// EndToEndTests.)
final class ContainerTests: XCTestCase {

    // MARK: - .supp support bundle

    func testSupportBundleIsDetectedAndBrowsable() throws {
        // A `.supp` decrypts (AES-128, same key/IV as `.unf`) to a ZIP that has
        // no db.gz / .bson but does carry support_info.json + system.properties
        // + a devices/ tree.
        let zip = buildStoredZip(entries: [
            ("version", Data("9.0.0\n".utf8)),
            ("system.properties", Data("unifi.version=9.0.0\n".utf8)),
            ("support_info.json", Data("{\"model\":\"UDMPRO\"}".utf8)),
            ("devices/aabbccddeeff/info.json", Data("{}".utf8)),
            ("logs/server.log", Data("boot ok\n".utf8)),
        ])
        let cipher = try UnfCipher.encrypt(pad16(zip))

        let backup = try Backup.load(ciphertext: cipher)

        XCTAssertTrue(backup.isSupportBundle)
        XCTAssertFalse(backup.isUnifiOSConsoleBackup)
        // No Network configuration database → empty model / tree.
        XCTAssertTrue(backup.model.sites.isEmpty)
        XCTAssertTrue(backup.tree.isEmpty)
        // Raw entries are exposed for browsing.
        XCTAssertNotNil(backup.rawEntries["support_info.json"])
        XCTAssertNotNil(backup.rawEntries["system.properties"])
        XCTAssertTrue(backup.entryNames.contains("support_info.json"))
        XCTAssertTrue(backup.entryNames.contains("devices/aabbccddeeff/info.json"))
        // The informational diagnostic is emitted.
        XCTAssertTrue(
            backup.diagnostics.contains { $0.message.contains("support bundle") },
            "expected the .supp detection diagnostic"
        )
    }

    func testSupportBundleViaSystemPropertiesPlusDevices() throws {
        // No support_info.json, but system.properties + a devices/ tree still
        // classifies as a support bundle.
        let zip = buildStoredZip(entries: [
            ("system.properties", Data("unifi.version=9.0.0\n".utf8)),
            ("devices/one/state.json", Data("{}".utf8)),
        ])
        let cipher = try UnfCipher.encrypt(pad16(zip))
        let backup = try Backup.load(ciphertext: cipher)
        XCTAssertTrue(backup.isSupportBundle)
        XCTAssertTrue(backup.model.sites.isEmpty)
    }

    // MARK: - AES-256 UniFi OS console container

    func testUnifiOSConsolePathEnabledRejectsNonGzip() {
        // The AES-256 console path is enabled (key verified). 64 block-aligned
        // bytes with a `.unifi` extension are attempted as the console shape:
        // they decrypt to non-gzip garbage, so the loader fails cleanly — NOT
        // with "pending verification", and never with silent garbage data.
        let blob = Data((0..<64).map { UInt8($0) })
        let url = URL(fileURLWithPath: "/private/tmp/example.unifi")
        XCTAssertThrowsError(try Backup.load(sourceURL: url, rawFileData: blob)) { err in
            guard case FatalBackupError.notAUniFiNetworkBackup(let detail) = err else {
                return XCTFail("expected notAUniFiNetworkBackup, got \(err)")
            }
            XCTAssertFalse(
                detail.lowercased().contains("pending verification"),
                "the console key is verified now, so it must not report pending: \(detail)"
            )
        }
    }

    func testCorruptUnfExtensionIsNotLabelledConsoleShape() {
        // The same bytes with a `.unf` extension must surface the AES-128/ZIP
        // failure, not the AES-256 console message.
        let blob = Data((0..<64).map { UInt8($0) })
        let url = URL(fileURLWithPath: "/private/tmp/example.unf")
        XCTAssertThrowsError(try Backup.load(sourceURL: url, rawFileData: blob)) { err in
            let desc = String(describing: err)
            XCTAssertFalse(desc.contains("AES-256"), "a .unf must not be labelled a console backup: \(desc)")
        }
    }

    // MARK: - Local builders (self-contained; SyntheticFixture helpers are private)

    private func pad16(_ data: Data) -> Data {
        var out = data
        let padLen = (16 - (out.count % 16)) % 16
        if padLen > 0 { out.append(Data(repeating: 0x00, count: padLen)) }
        return out
    }

    /// Minimal stored-method ZIP with a valid central directory + EOCD.
    private func buildStoredZip(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        struct Rec { let name: String; let crc: UInt32; let size: Int; let offset: Int }
        var records: [Rec] = []

        for (name, data) in entries {
            let offset = out.count
            let crc = crc32(data)
            let nameBytes = Data(name.utf8)
            out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            appendU16(&out, 20)
            appendU16(&out, 0x0800)   // UTF-8 names
            appendU16(&out, 0)        // stored
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, crc)
            appendU32(&out, UInt32(data.count))
            appendU32(&out, UInt32(data.count))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)
            out.append(nameBytes)
            out.append(data)
            records.append(Rec(name: name, crc: crc, size: data.count, offset: offset))
        }

        let cdOffset = out.count
        for r in records {
            let nameBytes = Data(r.name.utf8)
            out.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            appendU16(&out, 20)
            appendU16(&out, 20)
            appendU16(&out, 0x0800)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, r.crc)
            appendU32(&out, UInt32(r.size))
            appendU32(&out, UInt32(r.size))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU32(&out, 0)
            appendU32(&out, UInt32(r.offset))
            out.append(nameBytes)
        }
        let cdSize = out.count - cdOffset

        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(records.count))
        appendU16(&out, UInt16(records.count))
        appendU32(&out, UInt32(cdSize))
        appendU32(&out, UInt32(cdOffset))
        appendU16(&out, 0)
        return out
    }

    private func appendU16(_ d: inout Data, _ v: UInt16) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }

    private func appendU32(_ d: inout Data, _ v: UInt32) {
        var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
