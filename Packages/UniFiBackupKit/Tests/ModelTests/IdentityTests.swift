import XCTest
@testable import UniFiModel
import Diagnostics

final class IdentityTests: XCTestCase {

    func testVersionSanitisesBOMAndCRLF() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("9.5.21\r\n".utf8)
        let sink = DiagnosticSink()
        let v = Identity.parseVersion(bytes, diagnostics: sink)
        XCTAssertEqual(v, "9.5.21")
    }

    func testTimestampEpochMs() {
        let data = Data("1700000000000".utf8)
        let sink = DiagnosticSink()
        let d = Identity.parseTimestamp(data, diagnostics: sink)
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testTimestampISO() {
        let data = Data("2025-12-14T14:32:00Z".utf8)
        let sink = DiagnosticSink()
        let d = Identity.parseTimestamp(data, diagnostics: sink)
        XCTAssertNotNil(d)
    }

    func testTimestampNonsenseEmitsDiagnostic() {
        let data = Data("definitely not a date".utf8)
        let sink = DiagnosticSink()
        let d = Identity.parseTimestamp(data, diagnostics: sink)
        XCTAssertNil(d)
        let diags = sink.snapshot()
        XCTAssertEqual(diags.first?.code, .timestampUnparseable)
    }

    func testSiteExportDetectedWhenAdminMissing() {
        let sink = DiagnosticSink()
        let id = Identity.detectKind(
            entries: ["version": Data("9.5.21".utf8), "db.gz": Data()],
            collectionNames: ["site", "wlanconf", "device"],
            diagnostics: sink
        )
        XCTAssertEqual(id, .siteExport)
        XCTAssertTrue(sink.snapshot().contains { $0.code == .siteExportDetected })
    }

    func testFullBackupWithAdminAndStats() {
        let sink = DiagnosticSink()
        let id = Identity.detectKind(
            entries: [
                "version": Data("9.5.21".utf8),
                "db.gz": Data(),
                "db_stat.gz": Data(),
            ],
            collectionNames: ["site", "admin", "account", "device"],
            diagnostics: sink
        )
        XCTAssertEqual(id, .full)
    }

    func testOriginInferenceLinuxPath() {
        let props = Data("unifi.install.dir=/usr/lib/unifi\n".utf8)
        XCTAssertEqual(Identity.parseOrigin(props), .selfHostedLinux)
    }

    func testOriginInferenceCloudKey() {
        let props = Data("unifi.install.dir=/data/unifi\n".utf8)
        XCTAssertEqual(Identity.parseOrigin(props), .cloudKey)
    }
}
