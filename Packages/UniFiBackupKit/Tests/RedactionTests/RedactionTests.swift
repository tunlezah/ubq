import XCTest
@testable import Redaction
import UniFiBSON

final class RedactionTests: XCTestCase {

    func testTopLevelSecretsRedacted() {
        var d = BSONDocument()
        d["name"] = .string("home")
        d["x_passphrase"] = .string("supersecret")
        d["x_shadow"] = .string("$6$fakehash")
        d["enabled"] = .bool(true)

        let out = SecretVault.redact(d)
        XCTAssertEqual(out["name"], .string("home"))
        XCTAssertEqual(out["x_passphrase"], .string("<redacted>"))
        XCTAssertEqual(out["x_shadow"], .string("<redacted>"))
        XCTAssertEqual(out["enabled"], .bool(true))
    }

    func testNestedSecretsRedacted() {
        var inner = BSONDocument()
        inner["x_password"] = .string("radius-secret")
        inner["vlan"] = .int32(100)

        var d = BSONDocument()
        d["name"] = .string("alice")
        d["nested"] = .document(inner)

        let out = SecretVault.redact(d)
        let nested = out["nested"]?.documentValue
        XCTAssertEqual(nested?["x_password"], .string("<redacted>"))
        XCTAssertEqual(nested?["vlan"], .int32(100))
    }

    func testSecretsInArrayOfDocumentsRedacted() {
        var a = BSONDocument()
        a["shared_secret"] = .string("aaa")
        var b = BSONDocument()
        b["shared_secret"] = .string("bbb")

        var d = BSONDocument()
        d["auth_servers"] = .array([.document(a), .document(b)])

        let out = SecretVault.redact(d)
        let arr = out["auth_servers"]?.arrayValue ?? []
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0].documentValue?["shared_secret"], .string("<redacted>"))
        XCTAssertEqual(arr[1].documentValue?["shared_secret"], .string("<redacted>"))
    }

    func testFindSecretsReturnsPaths() {
        var inner = BSONDocument()
        inner["x_password"] = .string("hidden")
        var d = BSONDocument()
        d["x_shadow"] = .string("hash")
        d["nested"] = .document(inner)

        let paths = SecretVault.findSecrets(in: d).sorted()
        XCTAssertEqual(paths, ["nested.x_password", "x_shadow"])
    }

    func testUnknownXPrefixedFieldRedactedBenignPreserved() {
        var d = BSONDocument()
        d["x_secret_blob"] = .string("topsecret")   // unregistered but x_-prefixed
        d["x_vlan"] = .int32(42)                     // benign x_ allowlist
        d["name"] = .string("keep")                  // ordinary field
        d["vlan"] = .int32(10)                       // ordinary field

        let out = SecretVault.redact(d)
        XCTAssertEqual(out["x_secret_blob"], .string("<redacted>"))
        XCTAssertEqual(out["x_vlan"], .int32(42))
        XCTAssertEqual(out["name"], .string("keep"))
        XCTAssertEqual(out["vlan"], .int32(10))
    }

    func testIsSecretPredicate() {
        XCTAssertTrue(SecretVault.isSecret(fieldName: "password"))         // registry
        XCTAssertTrue(SecretVault.isSecret(fieldName: "x_ipsec_pre_shared_key")) // new registry entry
        XCTAssertTrue(SecretVault.isSecret(fieldName: "x_anything_new"))   // x_ default-deny
        XCTAssertFalse(SecretVault.isSecret(fieldName: "x_vlan"))          // benign allowlist
        XCTAssertFalse(SecretVault.isSecret(fieldName: "name"))            // ordinary
    }

    func testFindSecretsPicksUpUnknownXField() {
        var d = BSONDocument()
        d["x_totally_new"] = .string("value")
        d["x_vlan"] = .int32(7)
        let paths = SecretVault.findSecrets(in: d)
        XCTAssertEqual(paths, ["x_totally_new"])
    }
}
