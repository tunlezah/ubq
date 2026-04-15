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
            format: 8,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .full,
            origin: .selfHostedLinux
        )
    }
}
