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

    // MARK: - Generic CBC helper (AES-128 and AES-256)

    func testDecryptCBCRoundTripAES256() throws {
        let key = (0..<32).map { UInt8($0) }           // 32-byte AES-256 key
        let iv = [UInt8](repeating: 0x11, count: 16)
        let plain = Data(repeating: 0xAB, count: 48)   // multiple of 16
        let cipher = try UnfCipher.encryptCBC(plain, key: key, iv: iv)
        XCTAssertEqual(cipher.count, plain.count)
        let out = try UnfCipher.decryptCBC(cipher, key: key, iv: iv)
        XCTAssertEqual(out, plain)
    }

    func testDecryptCBCRoundTripAES128() throws {
        let iv = [UInt8](repeating: 0x22, count: 16)
        let plain = Data((0..<32).map { UInt8($0) })
        let cipher = try UnfCipher.encryptCBC(plain, key: UnfCipher.key, iv: iv)
        let out = try UnfCipher.decryptCBC(cipher, key: UnfCipher.key, iv: iv)
        XCTAssertEqual(out, plain)
    }

    func testDecryptCBCHandlesSlicedInput() throws {
        let key = (0..<32).map { UInt8($0) }
        let iv = [UInt8](repeating: 0x33, count: 16)
        let plain = Data(repeating: 0x5A, count: 32)
        let cipher = try UnfCipher.encryptCBC(plain, key: key, iv: iv)

        // Prepend junk then slice it off so startIndex != 0.
        var withJunk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        withJunk.append(cipher)
        let sliced = withJunk[5...]
        XCTAssertNotEqual(sliced.startIndex, 0)

        let out = try UnfCipher.decryptCBC(sliced, key: key, iv: iv)
        XCTAssertEqual(out, plain)
    }

    // MARK: - AES-256 UniFi OS console container

    func testDecryptAES256CBCWithPrependedIV() throws {
        let key = (0..<32).map { UInt8($0) }
        let iv = [UInt8](repeating: 0x44, count: 16)

        var payload = Data("UniFi OS console backup payload!".utf8)
        let pad = (16 - payload.count % 16) % 16
        payload.append(Data(repeating: 0x00, count: pad))   // block-align

        let body = try UnfCipher.encryptCBC(payload, key: key, iv: iv)
        var blob = Data(iv)                                  // IV prepended
        blob.append(body)

        let out = try UnfCipher.decryptAES256CBC(blob, key: key, ivPrepended: true)
        XCTAssertEqual(out, payload)
    }

    func testDecryptAES256CBCRejectsNonPrependedMode() {
        let key = (0..<32).map { UInt8($0) }
        let blob = Data(repeating: 0, count: 48)
        XCTAssertThrowsError(try UnfCipher.decryptAES256CBC(blob, key: key, ivPrepended: false))
    }

    func testAES256ConsoleKeyIsVerifiedAndMatchesKnownValue() {
        // The AES-256 console key is verified and enabled. Lock the exact 32
        // bytes (confirmed across four independent implementations — see
        // UnfCipher.unifiOSKey256Hex); do not mutate without an ADR.
        XCTAssertTrue(
            UnfCipher.unifiOSKey256Verified,
            "The AES-256 console path should be enabled now the key is verified."
        )
        XCTAssertEqual(UnfCipher.unifiOSKey256.count, 32, "decodeHex must yield 32 bytes")
        XCTAssertEqual(
            Data(UnfCipher.unifiOSKey256),
            Data([
                0xe3, 0x83, 0xb7, 0xc5, 0x36, 0x98, 0xb3, 0x6d,
                0x4b, 0xae, 0xa4, 0xed, 0x22, 0x18, 0x1e, 0xf7,
                0x36, 0x76, 0xbf, 0xd5, 0xd5, 0xb9, 0x00, 0x05,
                0xd9, 0x84, 0x5f, 0xfd, 0x5d, 0xce, 0x98, 0x5f,
            ]),
            "AES-256 console key must match the verified UniFi OS value."
        )
    }

    func testDecodeHexRoundTrips() {
        XCTAssertEqual(UnfCipher.decodeHex("00ff10"), [0x00, 0xff, 0x10])
        XCTAssertEqual(UnfCipher.decodeHex("zz"), [])   // invalid → empty
        XCTAssertEqual(UnfCipher.decodeHex("abc"), [])  // odd length → empty
    }
}
