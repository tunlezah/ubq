import XCTest
@testable import UniFiBackupKit

final class EndToEndTests: XCTestCase {

    func testOpenSyntheticBackupEndToEnd() throws {
        let ciphertext = try SyntheticFixture.makeMinimalBackup(
            siteName: "default",
            siteDesc: "Default Site",
            wlanSSID: "FixtureNet",
            wlanPSK: "supersecret123",
            includeStatsDB: true
        )
        let backup = try Backup.load(ciphertext: ciphertext, loadStatistics: true)

        // Identity
        XCTAssertEqual(backup.identity.version, "9.5.21")
        XCTAssertEqual(backup.identity.format, "8")
        XCTAssertEqual(backup.identity.kind, .full)

        // Model
        XCTAssertEqual(backup.model.sites.count, 1)
        XCTAssertEqual(backup.model.sites.first?.name, "default")
        XCTAssertEqual(backup.model.devices.count, 1)
        XCTAssertEqual(backup.model.wlans.count, 1)
        XCTAssertEqual(backup.model.wlans.first?.name, "FixtureNet")
        XCTAssertEqual(backup.model.wlans.first?.passphrase, "supersecret123")
        XCTAssertEqual(backup.model.admins.count, 1)
        XCTAssertEqual(backup.model.accounts.count, 1)

        // Opaque fallback for unknown_future
        XCTAssertTrue(backup.model.opaqueCollections.contains { $0.name == "unknown_future" })

        // Secret inventory picks up passphrase + shadow + password
        XCTAssertFalse(backup.secretInventory.isEmpty)
        XCTAssertTrue(backup.secretInventory.keys.contains { $0.contains("x_passphrase") })
        XCTAssertTrue(backup.secretInventory.keys.contains { $0.contains("x_shadow") })

        // Stats loaded
        XCTAssertTrue(backup.statsLoaded)
        XCTAssertTrue(backup.model.opaqueCollections.contains { $0.name == "stat_life" })

        // Tree populated
        XCTAssertFalse(backup.tree.isEmpty)
    }

    func testRedactedMarkdownExportOfFixture() throws {
        let ciphertext = try SyntheticFixture.makeMinimalBackup(
            wlanPSK: "supersecret123"
        )
        let backup = try Backup.load(ciphertext: ciphertext)

        // Select the single WLAN for export.
        let wlanNodes: [TreeNode] = TreeBuilder.flatten(backup.tree).filter { node in
            if case .wlan = node { return true } else { return false }
        }
        XCTAssertFalse(wlanNodes.isEmpty)

        let request = ExportRequest(
            nodes: wlanNodes,
            format: .markdown,
            preset: .claude,
            includeSecrets: false,
            identity: backup.identity
        )
        let output = Exporter.export(request)
        XCTAssertFalse(output.contains("supersecret123"))
        XCTAssertTrue(output.contains("<redacted>"))
        XCTAssertTrue(output.contains("UniFi Backup Export"))
    }

    func testPerCollectionBSONFormat() throws {
        let ciphertext = try SyntheticFixture.makePerCollectionBackup(
            wlanSSID: "BsonFormatNet",
            wlanPSK: "secret123"
        )
        let backup = try Backup.load(ciphertext: ciphertext)

        XCTAssertEqual(backup.identity.version, "9.5.21")
        XCTAssertEqual(backup.identity.format, "bson")

        XCTAssertEqual(backup.model.sites.count, 1)
        XCTAssertEqual(backup.model.sites.first?.name, "default")
        XCTAssertEqual(backup.model.devices.count, 1)
        XCTAssertEqual(backup.model.wlans.count, 1)
        XCTAssertEqual(backup.model.wlans.first?.name, "BsonFormatNet")
        XCTAssertEqual(backup.model.admins.count, 1)
        XCTAssertEqual(backup.model.accounts.count, 1)

        XCTAssertFalse(backup.tree.isEmpty)
    }

    func testRejectsGarbageData() {
        let cipher = Data((0..<128).map { _ in UInt8.random(in: 0...255) })
        XCTAssertThrowsError(try Backup.load(ciphertext: cipher))
    }
}
