import XCTest
@testable import UnfCrypto
import Diagnostics

final class UnfCryptoTests: XCTestCase {

    func testRoundTripEncryptDecrypt() throws {
        // Construct a fake "ZIP" plaintext whose first 4 bytes are PK\x03\x04.
        var plain = Data([0x50, 0x4b, 0x03, 0x04])
        plain.append(Data(repeating: 0xA5, count: 60))   // 64 bytes total
        // Pad up to multiple of 16 (already satisfied at 64).
        let cipher = try UnfCipher.encrypt(plain)
        XCTAssertEqual(cipher.count, plain.count)

        let decrypted = try UnfCipher.decrypt(cipher)
        XCTAssertEqual(decrypted, plain)
    }

    func testDecryptRejectsNonBlockAlignedInput() {
        let nonAligned = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(try UnfCipher.decrypt(nonAligned)) { err in
            guard case FatalBackupError.truncatedAtBlockBoundary(let n) = err else {
                return XCTFail("expected truncatedAtBlockBoundary, got \(err)")
            }
            XCTAssertEqual(n, 5)
        }
    }

    func testDecryptRejectsRandomDataWithoutZipMagic() {
        // Produce 32 bytes of ciphertext that is block-aligned but the result
        // will not start with PK\x03\x04.
        let randomLookingPlain = Data((0..<32).map { UInt8($0) })
        let cipher = try! UnfCipher.encrypt(randomLookingPlain)
        XCTAssertThrowsError(try UnfCipher.decrypt(cipher)) { err in
            guard case FatalBackupError.notZip = err else {
                return XCTFail("expected notZip, got \(err)")
            }
        }
    }

    func testKeyAndIVAreTheKnownUnifiConstants() {
        XCTAssertEqual(
            Data(UnfCipher.key),
            Data("bcyangkmluohmars".utf8),
            "Key constant must match UniFi's published value — do not mutate without ADR."
        )
        XCTAssertEqual(
            Data(UnfCipher.iv),
            Data("ubntenterpriseap".utf8),
            "IV constant must match UniFi's published value — do not mutate without ADR."
        )
    }
}
