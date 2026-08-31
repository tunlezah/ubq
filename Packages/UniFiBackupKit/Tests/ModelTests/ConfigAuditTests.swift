import XCTest
@testable import UniFiModel
import UniFiBSON

final class ConfigAuditTests: XCTestCase {

    // MARK: - Fixtures

    private func identity(kind: Identity.Kind = .full, version: String? = "9.5.21") -> Identity {
        Identity(version: version, format: nil, timestamp: nil, kind: kind, origin: .unknown)
    }

    private func wlan(
        id: String, name: String, security: String, wpaMode: String? = "wpa2",
        passphrase: String? = nil, isGuest: Bool = false, l2iso: Bool? = nil,
        enabled: Bool = true
    ) -> Wlan {
        var pairs: [(String, BSONValue)] = [
            ("_id", .string(id)),
            ("name", .string(name)),
            ("security", .string(security)),
            ("enabled", .bool(enabled)),
            ("is_guest", .bool(isGuest)),
        ]
        if let wpaMode { pairs.append(("wpa_mode", .string(wpaMode))) }
        if let passphrase { pairs.append(("x_passphrase", .string(passphrase))) }
        if let l2iso { pairs.append(("l2_isolation", .bool(l2iso))) }
        return Wlan(
            id: id, siteId: "s1", name: name, security: security, wpaMode: wpaMode,
            vlan: nil, enabled: enabled, isGuest: isGuest, wlangroupId: nil,
            usergroupId: nil, passphrase: passphrase, rawDocument: BSONDocument(pairs: pairs)
        )
    }

    private func portForward(
        id: String, name: String, dstPort: String, proto: String = "tcp",
        src: String = "any", enabled: Bool = true
    ) -> PortForward {
        let doc = BSONDocument(pairs: [
            ("_id", .string(id)),
            ("name", .string(name)),
            ("dst_port", .string(dstPort)),
            ("proto", .string(proto)),
            ("src", .string(src)),
            ("enabled", .bool(enabled)),
        ])
        return PortForward(
            id: id, siteId: "s1", name: name, fwd: nil, src: src, proto: proto,
            dstPort: dstPort, fwdPort: nil, enabled: enabled, rawDocument: doc
        )
    }

    private func site(id: String, name: String) -> Site {
        Site(
            id: id, name: name, desc: nil, attrHiddenId: nil, attrNoDelete: nil,
            rawDocument: BSONDocument(pairs: [("_id", .string(id)), ("name", .string(name))])
        )
    }

    // MARK: - WLAN

    func testOpenWlanIsHigh() throws {
        var m = ModelMapper.MappedModel()
        m.wlans = [wlan(id: "w1", name: "OpenNet", security: "open")]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "wlan-open-w1" })
        XCTAssertEqual(f.severity, .high)
        XCTAssertEqual(f.category, "WLAN Security")
        XCTAssertEqual(f.recordId, "w1")
        XCTAssertGreaterThanOrEqual(audit.summaryBySeverity[.high] ?? 0, 1)
    }

    func testWepWlanIsHigh() throws {
        var m = ModelMapper.MappedModel()
        m.wlans = [wlan(id: "w1", name: "OldNet", security: "wep")]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "wlan-wep-w1" })
        XCTAssertEqual(f.severity, .high)
    }

    func testShortPskIsMedium() throws {
        var m = ModelMapper.MappedModel()
        m.wlans = [wlan(id: "w1", name: "Net", security: "wpapsk", passphrase: "short")]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "wlan-shortpsk-w1" })
        XCTAssertEqual(f.severity, .medium)
    }

    func testGuestWithoutIsolationIsLow() throws {
        var m = ModelMapper.MappedModel()
        m.wlans = [wlan(id: "w1", name: "Guest", security: "wpapsk", passphrase: "aVeryLongPassphrase123", isGuest: true, l2iso: false)]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "wlan-guest-noiso-w1" })
        XCTAssertEqual(f.severity, .low)
    }

    // MARK: - Port forwarding

    func testPortForwardExposing8443IsHigh() throws {
        var m = ModelMapper.MappedModel()
        m.portForwards = [portForward(id: "p1", name: "expose-ui", dstPort: "8443")]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.category == "Port Forwarding" })
        XCTAssertEqual(f.severity, .high)
        XCTAssertEqual(f.recordId, "p1")
        XCTAssertTrue(f.detail.contains("8443"))
    }

    func testNormalPortForwardIsNotFlagged() {
        var m = ModelMapper.MappedModel()
        m.portForwards = [portForward(id: "p1", name: "web", dstPort: "80")]
        let audit = ConfigAudit.run(model: m, identity: identity())
        XCTAssertNil(audit.findings.first { $0.category == "Port Forwarding" })
    }

    func testDisabledPortForwardIsNotFlagged() {
        var m = ModelMapper.MappedModel()
        m.portForwards = [portForward(id: "p1", name: "expose", dstPort: "22", enabled: false)]
        let audit = ConfigAudit.run(model: m, identity: identity())
        XCTAssertNil(audit.findings.first { $0.category == "Port Forwarding" })
    }

    // MARK: - Firewall

    func testAnyAcceptFirewallIsMedium() throws {
        var m = ModelMapper.MappedModel()
        let doc = BSONDocument(pairs: [
            ("_id", .string("f1")),
            ("name", .string("allow all")),
            ("action", .string("accept")),
            ("enabled", .bool(true)),
            ("protocol", .string("all")),
        ])
        m.firewallRules = [FirewallRule(
            id: "f1", siteId: "s1", name: "allow all", ruleset: "WAN_IN",
            ruleIndex: 2000, action: "accept", proto: "all", enabled: true, rawDocument: doc
        )]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "fw-anyaccept-f1" })
        XCTAssertEqual(f.severity, .medium)
        XCTAssertEqual(f.category, "Firewall")
    }

    func testConstrainedAcceptIsNotFlagged() {
        var m = ModelMapper.MappedModel()
        let doc = BSONDocument(pairs: [
            ("_id", .string("f1")),
            ("name", .string("allow lan")),
            ("action", .string("accept")),
            ("enabled", .bool(true)),
            ("protocol", .string("all")),
            ("src_networkconf_id", .string("net1")),
        ])
        m.firewallRules = [FirewallRule(
            id: "f1", siteId: "s1", name: "allow lan", ruleset: "LAN_IN",
            ruleIndex: 2000, action: "accept", proto: "all", enabled: true, rawDocument: doc
        )]
        let audit = ConfigAudit.run(model: m, identity: identity())
        XCTAssertNil(audit.findings.first { $0.id == "fw-anyaccept-f1" })
    }

    // MARK: - Admin & access

    func testAdminWithoutTwoFactorIsLow() throws {
        var m = ModelMapper.MappedModel()
        m.admins = [Admin(
            id: "a1", name: "root", email: "r@example.com", lastSiteName: nil,
            timeCreated: nil, rawDocument: BSONDocument(pairs: [("_id", .string("a1")), ("name", .string("root"))])
        )]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "admin-no-2fa" })
        XCTAssertEqual(f.severity, .low)
        XCTAssertEqual(f.category, "Admin & Access")
    }

    func testAdminWithVerificationCollectionIsClean() {
        var m = ModelMapper.MappedModel()
        m.admins = [Admin(
            id: "a1", name: "root", email: nil, lastSiteName: nil, timeCreated: nil,
            rawDocument: BSONDocument(pairs: [("_id", .string("a1"))])
        )]
        m.opaqueCollections = [OpaqueCollection(name: "verification", records: [
            OpaqueRecord(id: "v1", rawDocument: BSONDocument(pairs: [
                ("_id", .string("v1")), ("admin_id", .string("a1")),
            ]))
        ])]
        let audit = ConfigAudit.run(model: m, identity: identity())
        XCTAssertNil(audit.findings.first { $0.id == "admin-no-2fa" })
    }

    // MARK: - Restore safety

    func testMultiSiteFullBackupHasRestoreSafetyFinding() throws {
        var m = ModelMapper.MappedModel()
        m.sites = [site(id: "default", name: "Default"), site(id: "s2", name: "Branch")]
        let audit = ConfigAudit.run(model: m, identity: identity(kind: .full))
        let f = try XCTUnwrap(audit.findings.first { $0.id == "restore-multisite" })
        XCTAssertEqual(f.severity, .medium)
        XCTAssertEqual(f.category, "Restore Safety")
        XCTAssertTrue(f.detail.contains("2"))
    }

    func testSingleSiteFullBackupHasNoMultiSiteFinding() {
        var m = ModelMapper.MappedModel()
        m.sites = [site(id: "default", name: "Default")]
        let audit = ConfigAudit.run(model: m, identity: identity(kind: .full))
        XCTAssertNil(audit.findings.first { $0.id == "restore-multisite" })
    }

    func testLegacyFirewallRulesReminder() throws {
        var m = ModelMapper.MappedModel()
        let doc = BSONDocument(pairs: [
            ("_id", .string("f1")), ("name", .string("r")), ("action", .string("drop")),
            ("enabled", .bool(true)), ("protocol", .string("tcp")), ("src_address", .string("1.2.3.4")),
        ])
        m.firewallRules = [FirewallRule(
            id: "f1", siteId: "s1", name: "r", ruleset: "WAN_IN", ruleIndex: 2000,
            action: "drop", proto: "tcp", enabled: true, rawDocument: doc
        )]
        let audit = ConfigAudit.run(model: m, identity: identity())
        let f = try XCTUnwrap(audit.findings.first { $0.id == "restore-legacy-fw" })
        XCTAssertEqual(f.severity, .info)
    }

    // MARK: - Clean model

    func testCleanModelHasNoHighOrCriticalFindings() {
        var m = ModelMapper.MappedModel()
        m.sites = [site(id: "default", name: "Default")]
        m.wlans = [wlan(
            id: "w1", name: "Secure", security: "wpapsk", wpaMode: "wpa2",
            passphrase: "aVeryLongPassphrase123"
        )]
        let audit = ConfigAudit.run(model: m, identity: identity(kind: .full))
        XCTAssertEqual(audit.summaryBySeverity[.high] ?? 0, 0)
        XCTAssertEqual(audit.summaryBySeverity[.critical] ?? 0, 0)
        XCTAssertTrue(audit.findings.isEmpty)
    }

    // MARK: - Severity + helpers

    func testSeverityIsComparable() {
        XCTAssertTrue(ConfigAudit.Severity.low < ConfigAudit.Severity.high)
        XCTAssertTrue(ConfigAudit.Severity.critical > ConfigAudit.Severity.info)
        XCTAssertEqual(
            [ConfigAudit.Severity.high, .info, .medium].sorted(),
            [.info, .medium, .high]
        )
    }

    func testPortsInParsesListsAndRanges() {
        XCTAssertTrue(ConfigAudit.portsIn("8443").contains(8443))
        XCTAssertTrue(ConfigAudit.portsIn("8000-9000").contains(8443))
        XCTAssertTrue(ConfigAudit.portsIn("80, 22").contains(22))
        XCTAssertFalse(ConfigAudit.portsIn("80,443").contains(22))
        XCTAssertTrue(ConfigAudit.portsIn(nil).isEmpty)
    }

    func testMajorVersionParsing() {
        XCTAssertEqual(ConfigAudit.majorVersion("6.6.55"), 6)
        XCTAssertEqual(ConfigAudit.majorVersion("10.1.5"), 10)
        XCTAssertNil(ConfigAudit.majorVersion(nil))
        XCTAssertNil(ConfigAudit.majorVersion("   "))
    }

    func testMarkdownReportRenders() {
        var m = ModelMapper.MappedModel()
        m.wlans = [wlan(id: "w1", name: "OpenNet", security: "open")]
        let md = ConfigAudit.run(model: m, identity: identity()).markdownReport()
        XCTAssertTrue(md.contains("# Config Audit"))
        XCTAssertTrue(md.contains("WLAN Security"))
    }
}
