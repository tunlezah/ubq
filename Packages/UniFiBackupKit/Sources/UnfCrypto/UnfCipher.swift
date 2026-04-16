import Foundation
import CommonCrypto
import Diagnostics

/// AES-128-CBC, NoPadding.
///
/// Key and IV are the canonical UniFi constants used by the controller since at
/// least v5.10 and unchanged through v9.5.21. Full sourcing in `/FORMAT.md` and
/// `/RESEARCH.md`.
public enum UnfCipher {
    public static let key: [UInt8] = Array("bcyangkmluohmars".utf8)
    public static let iv:  [UInt8] = Array("ubntenterpriseap".utf8)

    /// Decrypts a `.unf` ciphertext blob into a raw ZIP-bytes buffer.
    ///
    /// - Throws: `FatalBackupError.truncatedAtBlockBoundary` when the ciphertext
    ///           is not a multiple of 16 bytes; `FatalBackupError.decryptFailed`
    ///           on OS-level failure; `FatalBackupError.notZip` if the plaintext
    ///           does not start with `PK\x03\x04`.
    public static func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count > 0, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw FatalBackupError.truncatedAtBlockBoundary(actual: ciphertext.count)
        }

        var out = Data(count: ciphertext.count)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { inBuf -> CCCryptorStatus in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    /* options: no padding */ 0,
                    key, key.count,
                    iv,
                    inBuf.baseAddress, ciphertext.count,
                    outBuf.baseAddress, out.count,
                    &moved
                )
            }
        }

        guard status == kCCSuccess else {
            throw FatalBackupError.decryptFailed(status: Int32(status))
        }
        out.count = moved

        guard out.count >= 4,
              out[0] == 0x50, out[1] == 0x4B, out[2] == 0x03, out[3] == 0x04 else {
            throw FatalBackupError.notZip
        }

        return out
    }

    /// Symmetric encrypt — useful for round-trip tests only.
    ///
    /// - Parameter plaintext: A ZIP blob whose length must be a multiple of 16.
    public static func encrypt(_ plaintext: Data) throws -> Data {
        guard plaintext.count % kCCBlockSizeAES128 == 0 else {
            throw FatalBackupError.truncatedAtBlockBoundary(actual: plaintext.count)
        }
        var out = Data(count: plaintext.count)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            plaintext.withUnsafeBytes { inBuf -> CCCryptorStatus in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    0,
                    key, key.count,
                    iv,
                    inBuf.baseAddress, plaintext.count,
                    outBuf.baseAddress, out.count,
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
