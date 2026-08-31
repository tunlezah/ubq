import XCTest
@testable import Export
import UniFiModel
import UniFiBSON

final class ExportTests: XCTestCase {

    func testJSONExportContainsHeaderAndSection() {
        let node = makeWlanNode()
        let id = sampleIdentity()
        let request = ExportRequest(
            nodes: [node], format: .json, preset: .gpt,
            includeSecrets: false, identity: id
        )
        let out = Exporter.export(request)
        XCTAssertTrue(out.contains("\"header\""))
        XCTAssertTrue(out.contains("\"sections\""))
        XCTAssertTrue(out.contains("\"targetModel\" : \"gpt\""))
        // Redaction on by default.
        XCTAssertTrue(out.contains("<redacted>"))
        XCTAssertFalse(out.contains("supersecret"))
    }

    func testMarkdownWithClaudeUsesXMLTags() {
        let node = makeWlanNode()
        let request = ExportRequest(
            nodes: [node], format: .markdown, preset: .claude,
            includeSecrets: false
        )
        let out = Exporter.export(request)
        XCTAssertTrue(out.contains("<wlan"))
        XCTAssertTrue(out.contains("</wlan>"))
    }

    func testMarkdownWithGPTUsesHeadings() {
        let node = makeWlanNode()
        let request = ExportRequest(
            nodes: [node], format: .markdown, preset: .gpt,
            includeSecrets: false
        )
        let out = Exporter.export(request)
        XCTAssertTrue(out.contains("## Wlan:"))
    }

    func testIncludeSecretsPreservesValues() {
        let node = makeWlanNode()
        let request = ExportRequest(
            nodes: [node], format: .text, preset: .gpt,
            includeSecrets: true
        )
        let out = Exporter.export(request)
        XCTAssertTrue(out.contains("supersecret"))
        XCTAssertTrue(out.contains("INCLUDES secrets"))
    }

    func testSuggestedFilenameIncludesVersionAndSecretsFlag() {
        let id = sampleIdentity()
        let nameClean = Exporter.suggestedFilename(
            for: ExportRequest(
                nodes: [], format: .json, preset: .claude,
                includeSecrets: false, identity: id
            )
        )
        XCTAssertTrue(nameClean.contains("v9.5.21"))
        XCTAssertTrue(nameClean.hasSuffix(".json"))
        XCTAssertFalse(nameClean.contains("INCLUDES-SECRETS"))

        let nameSecret = Exporter.suggestedFilename(
            for: ExportRequest(
                nodes: [], format: .markdown, preset: .claude,
                includeSecrets: true, identity: id
            )
        )
        XCTAssertTrue(nameSecret.contains("INCLUDES-SECRETS"))
        XCTAssertTrue(nameSecret.hasSuffix(".md"))
    }

    // MARK: - New coverage (ROADMAP §6 / Tier-2 #11)

    func testCSVExportHasHeaderRowAndQuotesCommaCell() {
        var doc = BSONDocument()
        doc["_id"] = .string("w2")
        doc["name"] = .string("Guest, Home")
        doc["security"] = .string("wpapsk")
        let node = TreeNode.wlan(WlanNode(id: "w2", title: "Guest, Home", raw: doc))

        let request = ExportRequest(
            nodes: [node], format: .csv, preset: .gpt,
            includeSecrets: true
        )
        let out = Exporter.export(request)

        // Comment line naming the collection, then a header row that's the
        // union of field keys in first-seen (insertion) order.
        XCTAssertTrue(out.contains("# wlan"))
        XCTAssertTrue(out.contains("_id,name,security"))
        // The comma-bearing cell is RFC-4180 quoted.
        XCTAssertTrue(out.contains("\"Guest, Home\""))
    }

    func testBudgetOverrideChangesOverBudgetWarning() {
        let node = makeWlanNode()

        let defaultRequest = ExportRequest(
            nodes: [node], format: .text, preset: .gpt,
            includeSecrets: false
        )
        let defaultOut = Exporter.export(defaultRequest)
        XCTAssertFalse(defaultOut.contains("exceeding the suggested budget"))

        let overriddenRequest = ExportRequest(
            nodes: [node], format: .text, preset: .gpt,
            includeSecrets: false, budgetOverride: 10
        )
        let overriddenOut = Exporter.export(overriddenRequest)
        XCTAssertTrue(overriddenOut.contains("exceeding the suggested budget"))
        XCTAssertTrue(overriddenOut.contains("(~10)"))
    }

    func testExportSlicesSplitsWhenTinyBudgetOverrideForcesIt() {
        let node1 = makeWlanNode()
        var doc2 = BSONDocument()
        doc2["_id"] = .string("w3")
        doc2["name"] = .string("Second Network")
        let node2 = TreeNode.wlan(WlanNode(id: "w3", title: "Second Network", raw: doc2))

        // A single, unsplit export is one document.
        let wholeRequest = ExportRequest(
            nodes: [node1, node2], format: .markdown, preset: .gpt,
            includeSecrets: false
        )
        XCTAssertEqual(Exporter.exportSlices(wholeRequest).count, 1)

        // A budget too small for even one section per document forces a
        // slice per top-level section.
        let tinyRequest = ExportRequest(
            nodes: [node1, node2], format: .markdown, preset: .gpt,
            includeSecrets: false, budgetOverride: 200
        )
        let slices = Exporter.exportSlices(tinyRequest)
        XCTAssertGreaterThan(slices.count, 1)
        XCTAssertTrue(slices[0].contains("part 1 of \(slices.count)"))
        guard let lastSlice = slices.last else {
            XCTFail("expected at least one slice")
            return
        }
        XCTAssertTrue(lastSlice.contains("part \(slices.count) of \(slices.count)"))
    }

    func testNestedSiteWithChildDeviceForClaude() {
        var deviceDoc = BSONDocument()
        deviceDoc["_id"] = .string("d1")
        deviceDoc["name"] = .string("AP1")
        let deviceNode = TreeNode.device(DeviceNode(id: "d1", title: "AP1", raw: deviceDoc))

        let devicesCategory = TreeNode.siteChildCategory(
            SiteChildCategory(siteId: "s1", kind: .devices, children: [deviceNode])
        )

        var siteDoc = BSONDocument()
        siteDoc["_id"] = .string("s1")
        siteDoc["name"] = .string("default")
        let siteNode = TreeNode.site(
            SiteNode(id: "s1", title: "Default Site", raw: siteDoc, children: [devicesCategory])
        )

        let request = ExportRequest(
            nodes: [siteNode], format: .markdown, preset: .claude,
            includeSecrets: false
        )
        let out = Exporter.export(request)

        guard let openRange = out.range(of: "<site"),
              let closeRange = out.range(of: "</site>") else {
            XCTFail("expected a <site>...</site> block")
            return
        }
        let siteBlock = out[openRange.lowerBound..<closeRange.upperBound]
        XCTAssertTrue(siteBlock.contains("<device"))
        XCTAssertTrue(siteBlock.contains("</device>"))
    }

    func testRecordSelectedWithoutParentStaysTopLevel() {
        // A device selected on its own (no enclosing .site in the selection)
        // still exports flat, same as a lone WLAN does.
        var deviceDoc = BSONDocument()
        deviceDoc["_id"] = .string("d2")
        deviceDoc["name"] = .string("AP2")
        let deviceNode = TreeNode.device(DeviceNode(id: "d2", title: "AP2", raw: deviceDoc))

        let request = ExportRequest(
            nodes: [deviceNode], format: .markdown, preset: .claude,
            includeSecrets: false
        )
        let out = Exporter.export(request)
        XCTAssertTrue(out.contains("<device"))
        XCTAssertTrue(out.contains("</device>"))
        XCTAssertFalse(out.contains("<site"))
    }

    // MARK: - Fixtures

    private func makeWlanNode() -> TreeNode {
        var doc = BSONDocument()
        doc["_id"] = .string("w1")
        doc["name"] = .string("Home Network")
        doc["x_passphrase"] = .string("supersecret")
        doc["security"] = .string("wpapsk")
        doc["enabled"] = .bool(true)
        return .wlan(WlanNode(id: "w1", title: "Home Network", raw: doc))
    }

    private func sampleIdentity() -> Identity {
        Identity(
            version: "9.5.21",
            format: "8",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .full,
            origin: .selfHostedLinux
        )
    }
}
