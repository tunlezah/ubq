import XCTest
@testable import UniFiModel

final class RestoreAdvisorTests: XCTestCase {

    private func identity(version: String?, kind: Identity.Kind = .full) -> Identity {
        Identity(version: version, format: nil, timestamp: nil, kind: kind, origin: .unknown)
    }

    func testForwardOnlyMinimumMatchesBackupVersion() {
        let advice = RestoreAdvisor.advise(identity: identity(version: "10.1.5"), siteCount: 1)
        XCTAssertEqual(advice.backupVersion, "10.1.5")
        XCTAssertEqual(advice.minimumRestoreVersion, "10.1.5")
        XCTAssertTrue(advice.messages.contains { $0.contains("10.1.5") })
        XCTAssertTrue(advice.messages.contains { $0.lowercased().contains("forward-only") })
        XCTAssertTrue(advice.warnings.isEmpty)
    }

    func testMultiSiteProducesWarning() {
        let advice = RestoreAdvisor.advise(identity: identity(version: "9.5.21"), siteCount: 3)
        XCTAssertEqual(advice.warnings.count, 1)
        XCTAssertTrue(advice.warnings[0].contains("3"))
        XCTAssertTrue(advice.warnings[0].lowercased().contains("default site"))
    }

    func testSingleSiteHasNoWarning() {
        let advice = RestoreAdvisor.advise(identity: identity(version: "9.5.21"), siteCount: 1)
        XCTAssertTrue(advice.warnings.isEmpty)
    }

    func testUnknownVersionHandledGracefully() {
        let advice = RestoreAdvisor.advise(identity: identity(version: nil), siteCount: 1)
        XCTAssertNil(advice.backupVersion)
        XCTAssertNil(advice.minimumRestoreVersion)
        XCTAssertFalse(advice.messages.isEmpty)
        XCTAssertTrue(advice.messages.contains { $0.lowercased().contains("unknown") })
    }

    func testBlankVersionTreatedAsUnknown() {
        let advice = RestoreAdvisor.advise(identity: identity(version: "   "), siteCount: 1)
        XCTAssertNil(advice.backupVersion)
        XCTAssertNil(advice.minimumRestoreVersion)
    }

    func testSiteExportMessage() {
        let advice = RestoreAdvisor.advise(
            identity: identity(version: "8.0.24", kind: .siteExport), siteCount: 1
        )
        XCTAssertTrue(advice.messages.contains { $0.lowercased().contains("site export") })
    }

    func testMultiSiteWithUnknownVersionStillWarns() {
        let advice = RestoreAdvisor.advise(identity: identity(version: nil), siteCount: 2)
        XCTAssertEqual(advice.warnings.count, 1)
        XCTAssertNil(advice.backupVersion)
    }
}
