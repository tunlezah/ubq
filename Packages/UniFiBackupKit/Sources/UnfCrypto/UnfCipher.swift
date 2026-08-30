import Foundation
import CommonCrypto
import Diagnostics

/// AES-CBC, NoPadding decryption for UniFi backup containers.
///
/// * `.unf` (and `.supp`) use **AES-128-CBC** with the canonical UniFi
///   constants used by the controller since at least v5.10 and unchanged
///   through v10.x. Full sourcing in `/FORMAT.md` and `/RESEARCH.md`.
/// * UniFi OS **console** `.unifi` files use **AES-256-CBC** with a 32-byte
///   static key and the IV prepended to the ciphertext — see `unifiOSKey256`.
///
/// CryptoKit does not expose raw CBC, so we call `CommonCrypto` directly. A
/// single generic `decryptCBC(_:key:iv:)` backs every key size.
public enum UnfCipher {
    public static let key: [UInt8] = Array("bcyangkmluohmars".utf8)
    public static let iv:  [UInt8] = Array("ubntenterpriseap".utf8)

    /// AES-256 key for the UniFi OS **console** `.unifi` container (AES-256-CBC,
    /// NoPadding, IV prepended as the first 16 bytes). Published in
    /// EvilBit-Labs/unifi_extract's `DECRYPTION.md` as a 32-byte static key that
    /// begins `e3 83 b7 c5 …` and ends `… 5d ce 98 5f` (see `/ROADMAP.md` §3.3).
    ///
    /// TODO(key): the full 32 bytes could not be transcribed with certainty from
    /// the source at implementation time, so this is a **PLACEHOLDER** (all
    /// zeroes). It is deliberately never used to decrypt while
    /// `unifiOSKey256Verified` is `false`, because a wrong key silently produces
    /// garbage — worse than an unimplemented path. Before enabling the AES-256
    /// console path: paste the verified 32 bytes here, confirm they decrypt a
    /// real console-generated file to a `1f 8b` gzip stream, then flip
    /// `unifiOSKey256Verified` to `true`.
    public static let unifiOSKey256: [UInt8] = Array(repeating: 0, count: 32)

    /// Guards the AES-256 console path. Stays `false` until `unifiOSKey256`
    /// holds the verified 32-byte key (see the TODO above). While `false`, the
    /// loader reports "decryption key pending verification" instead of
    /// decrypting with bogus bytes.
    public static let unifiOSKey256Verified = false

    /// Decrypts a `.unf` ciphertext blob into a raw ZIP-bytes buffer (AES-128).
    ///
    /// - Throws: `FatalBackupError.truncatedAtBlockBoundary` when the ciphertext
    ///           is not a multiple of 16 bytes; `FatalBackupError.decryptFailed`
    ///           on OS-level failure; `FatalBackupError.notZip` if the plaintext
    ///           does not start with `PK\x03\x04`.
    public static func decrypt(_ ciphertext: Data) throws -> Data {
        let out = try decryptCBC(ciphertext, key: key, iv: iv)
        guard out.count >= 4,
              out[0] == 0x50, out[1] == 0x4B, out[2] == 0x03, out[3] == 0x04 else {
            throw FatalBackupError.notZip
        }
        return out
    }

    /// Decrypts the UniFi OS **console** `.unifi` AES-256-CBC container.
    ///
    /// The IV is prepended as the first 16 bytes of the file; the ciphertext
    /// body follows. Returns the raw plaintext (expected to be a `gzip` stream).
    /// The caller is responsible for validating the gzip magic.
    ///
    /// - Parameter ivPrepended: The console format always prepends the IV; this
    ///   is required to be `true` because there is no separate IV parameter.
    public static func decryptAES256CBC(
        _ ciphertext: Data,
        key: [UInt8],
        ivPrepended: Bool
    ) throws -> Data {
        let src = ciphertext.startIndex == 0 ? ciphertext : Data(ciphertext)
        guard ivPrepended else {
            throw FatalBackupError.io(
                "decryptAES256CBC requires ivPrepended for the UniFi OS console format"
            )
        }
        guard src.count >= 32, src.count % kCCBlockSizeAES128 == 0 else {
            throw FatalBackupError.truncatedAtBlockBoundary(actual: src.count)
        }
        // `src` is normalised zero-based, so absolute indices are safe.
        let extractedIV = Array(src[0..<16])
        let body = Data(src[16..<src.count])
        return try decryptCBC(body, key: key, iv: extractedIV)
    }

    /// Generic AES-CBC, NoPadding decryption shared by AES-128 and AES-256.
    /// Key size is inferred from `key.count` (16 → AES-128, 32 → AES-256); the
    /// block size (and hence the IV length) is always 16 bytes.
    static func decryptCBC(_ ciphertext: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        guard ciphertext.count > 0, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw FatalBackupError.truncatedAtBlockBoundary(actual: ciphertext.count)
        }
        // Normalise to a zero-based buffer so `withUnsafeBytes` sees the whole
        // ciphertext even when a `Data` slice was handed in.
        let src = ciphertext.startIndex == 0 ? ciphertext : Data(ciphertext)

        // Capture sizes locally so the inner closure doesn't alias a mutating
        // access on `out` (Swift exclusivity: withUnsafeMutableBytes on `out`
        // conflicts with reading `out.count` inside its closure body).
        let ciphertextLen = src.count
        let outLen = src.count
        var out = Data(count: outLen)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            src.withUnsafeBytes { inBuf -> CCCryptorStatus in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    /* options: no padding */ 0,
                    key, key.count,
                    iv,
                    inBuf.baseAddress, ciphertextLen,
                    outBuf.baseAddress, outLen,
                    &moved
                )
            }
        }

        guard status == kCCSuccess else {
            throw FatalBackupError.decryptFailed(status: Int32(status))
        }
        out.count = moved
        return out
    }

    /// Symmetric AES-128 encrypt — useful for round-trip tests only.
    ///
    /// - Parameter plaintext: A ZIP blob whose length must be a multiple of 16.
    public static func encrypt(_ plaintext: Data) throws -> Data {
        try encryptCBC(plaintext, key: key, iv: iv)
    }

    /// Generic AES-CBC, NoPadding encryption shared by AES-128 and AES-256.
    /// Used only for round-trip tests (the format itself is decrypt-only here).
    static func encryptCBC(_ plaintext: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        guard plaintext.count % kCCBlockSizeAES128 == 0 else {
            throw FatalBackupError.truncatedAtBlockBoundary(actual: plaintext.count)
        }
        let src = plaintext.startIndex == 0 ? plaintext : Data(plaintext)
        let plaintextLen = src.count
        let outLen = src.count
        var out = Data(count: outLen)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            src.withUnsafeBytes { inBuf -> CCCryptorStatus in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    0,
                    key, key.count,
                    iv,
                    inBuf.baseAddress, plaintextLen,
                    outBuf.baseAddress, outLen,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else {
            throw FatalBackupError.decryptFailed(status: Int32(status))
        }
        out.count = moved
        return out
    }
}
