import XCTest
@testable import UniFiModel
import UniFiBSON

final class BackupDiffTests: XCTestCase {

    // MARK: - Fixtures

    private func identity(_ v: String) -> Identity {
        Identity(version: v, format: nil, timestamp: nil, kind: .full, origin: .unknown)
    }

    private func device(
        id: String, mac: String, name: String, version: String,
        extra: [(String, BSONValue)] = []
    ) -> Device {
        let doc = BSONDocument(pairs: [
            ("_id", .string(id)),
            ("mac", .string(mac)),
            ("name", .string(name)),
            ("version", .string(version)),
        ] + extra)
        return Device(
            id: id, siteId: "s1", mac: mac, name: name, model: nil, type: nil,
            version: version, adopted: true, serial: nil, rawDocument: doc
        )
    }

    private func wlan(id: String, name: String, passphrase: String) -> Wlan {
        let doc = BSONDocument(pairs: [
            ("_id", .string(id)),
            ("name", .string(name)),
            ("security", .string("wpapsk")),
            ("x_passphrase", .string(passphrase)),
        ])
        return Wlan(
            id: id, siteId: "s1", name: name, security: "wpapsk", wpaMode: "wpa2",
            vlan: nil, enabled: true, isGuest: false, wlangroupId: nil,
            usergroupId: nil, passphrase: passphrase, rawDocument: doc
        )
    }

    // MARK: - Tests

    func testIdenticalModelsAreEmpty() {
        var m = ModelMapper.MappedModel()
        m.devices = [
            device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55"),
            device(id: "d2", mac: "bb:bb", name: "AP2", version: "6.6.55"),
        ]
        let diff = BackupDiff.compute(
            left: m, leftIdentity: identity("9.5.21"),
            right: m, rightIdentity: identity("9.5.21")
        )
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.totalChanges, 0)
        XCTAssertTrue(diff.collectionDeltas.isEmpty)
    }

    func testDeviceAdded() throws {
        var left = ModelMapper.MappedModel()
        left.devices = [device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55")]
        var right = ModelMapper.MappedModel()
        right.devices = [
            device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55"),
            device(id: "d2", mac: "bb:bb", name: "AP2", version: "6.6.55"),
        ]

        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9")
        )
        XCTAssertFalse(diff.isEmpty)
        XCTAssertEqual(diff.totalChanges, 1)

        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "device" })
        XCTAssertEqual(dc.added, 1)
        XCTAssertEqual(dc.removed, 0)
        XCTAssertEqual(dc.modified, 0)

        let added = try XCTUnwrap(dc.deltas.first { $0.kind == .added })
        XCTAssertEqual(added.recordId, "d2")
        XCTAssertEqual(added.title, "AP2")
        XCTAssertEqual(added.id, "device:d2")
        XCTAssertTrue(added.fieldChanges.isEmpty)
    }

    func testDeviceRemoved() throws {
        var left = ModelMapper.MappedModel()
        left.devices = [
            device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55"),
            device(id: "d2", mac: "bb:bb", name: "AP2", version: "6.6.55"),
        ]
        var right = ModelMapper.MappedModel()
        right.devices = [device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55")]

        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9")
        )
        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "device" })
        XCTAssertEqual(dc.removed, 1)
        XCTAssertEqual(dc.added, 0)
        let removed = try XCTUnwrap(dc.deltas.first { $0.kind == .removed })
        XCTAssertEqual(removed.recordId, "d2")
        XCTAssertEqual(removed.kind, .removed)
    }

    func testWlanPassphraseChangeMasked() throws {
        var left = ModelMapper.MappedModel()
        left.wlans = [wlan(id: "w1", name: "Home", passphrase: "oldpass12345")]
        var right = ModelMapper.MappedModel()
        right.wlans = [wlan(id: "w1", name: "Home", passphrase: "newpass67890")]

        let secret: @Sendable (String) -> Bool = { $0 == "x_passphrase" }
        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9"),
            isSecretField: secret
        )
        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "wlanconf" })
        XCTAssertEqual(dc.modified, 1)

        let mod = try XCTUnwrap(dc.deltas.first { $0.kind == .modified })
        XCTAssertEqual(mod.recordId, "w1")
        XCTAssertEqual(mod.title, "Home")
        XCTAssertEqual(mod.fieldChanges.count, 1)

        let fc = try XCTUnwrap(mod.fieldChanges.first { $0.path == "x_passphrase" })
        XCTAssertEqual(fc.before, "<redacted>")
        XCTAssertEqual(fc.after, "<redacted>")
    }

    func testWlanPassphraseChangeUnmaskedByDefault() throws {
        var left = ModelMapper.MappedModel()
        left.wlans = [wlan(id: "w1", name: "Home", passphrase: "oldpass12345")]
        var right = ModelMapper.MappedModel()
        right.wlans = [wlan(id: "w1", name: "Home", passphrase: "newpass67890")]

        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9")
        )
        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "wlanconf" })
        let mod = try XCTUnwrap(dc.deltas.first { $0.kind == .modified })
        let fc = try XCTUnwrap(mod.fieldChanges.first { $0.path == "x_passphrase" })
        XCTAssertEqual(fc.before, "oldpass12345")
        XCTAssertEqual(fc.after, "newpass67890")
    }

    func testNestedArrayFieldProducesDottedPath() throws {
        func doc(_ poe: String) -> BSONDocument {
            BSONDocument(pairs: [
                ("_id", .string("sw1")),
                ("name", .string("Switch")),
                ("port_overrides", .array([
                    .document(BSONDocument(pairs: [
                        ("port_idx", .int32(1)),
                        ("poe_mode", .string(poe)),
                    ]))
                ])),
            ])
        }
        var left = ModelMapper.MappedModel()
        left.devices = [Device(
            id: "sw1", siteId: nil, mac: nil, name: "Switch", model: nil, type: nil,
            version: nil, adopted: nil, serial: nil, rawDocument: doc("auto")
        )]
        var right = ModelMapper.MappedModel()
        right.devices = [Device(
            id: "sw1", siteId: nil, mac: nil, name: "Switch", model: nil, type: nil,
            version: nil, adopted: nil, serial: nil, rawDocument: doc("off")
        )]

        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9")
        )
        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "device" })
        let mod = try XCTUnwrap(dc.deltas.first { $0.kind == .modified })
        XCTAssertEqual(mod.fieldChanges.count, 1)
        let fc = try XCTUnwrap(mod.fieldChanges.first)
        XCTAssertEqual(fc.path, "port_overrides[0].poe_mode")
        XCTAssertEqual(fc.before, "auto")
        XCTAssertEqual(fc.after, "off")
    }

    func testOpaqueCollectionsAreDiffed() throws {
        func opaque(_ value: String) -> OpaqueCollection {
            OpaqueCollection(name: "customthing", records: [
                OpaqueRecord(id: "o1", rawDocument: BSONDocument(pairs: [
                    ("_id", .string("o1")),
                    ("name", .string("Widget")),
                    ("state", .string(value)),
                ]))
            ])
        }
        var left = ModelMapper.MappedModel()
        left.opaqueCollections = [opaque("on")]
        var right = ModelMapper.MappedModel()
        right.opaqueCollections = [opaque("off")]

        let diff = BackupDiff.compute(
            left: left, leftIdentity: identity("9"),
            right: right, rightIdentity: identity("9")
        )
        let dc = try XCTUnwrap(diff.collectionDeltas.first { $0.collection == "customthing" })
        XCTAssertEqual(dc.modified, 1)
        let mod = try XCTUnwrap(dc.deltas.first)
        XCTAssertEqual(mod.fieldChanges.first?.path, "state")
    }

    func testMarkdownReportRenders() {
        var left = ModelMapper.MappedModel()
        left.wlans = [wlan(id: "w1", name: "Home", passphrase: "oldpass12345")]
        var right = ModelMapper.MappedModel()
        right.wlans = [wlan(id: "w1", name: "Home", passphrase: "newpass67890")]
        right.devices = [device(id: "d1", mac: "aa:aa", name: "AP1", version: "6.6.55")]

        let md = BackupDiff.compute(
            left: left, leftIdentity: identity("9.0"),
            right: right, rightIdentity: identity("9.1")
        ).markdownReport()

        XCTAssertTrue(md.contains("# Backup Diff"))
        XCTAssertTrue(md.contains("wlanconf"))
        XCTAssertTrue(md.contains("device"))
        XCTAssertTrue(md.contains("AP1"))
    }

    func testEmptyDiffMarkdown() {
        let m = ModelMapper.MappedModel()
        let md = BackupDiff.compute(
            left: m, leftIdentity: identity("9"),
            right: m, rightIdentity: identity("9")
        ).markdownReport()
        XCTAssertTrue(md.contains("No configuration differences"))
    }
}
