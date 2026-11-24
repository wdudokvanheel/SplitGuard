import Darwin
import Foundation

enum SecretBytes {
    /// Compares equal-length buffers without branching on their contents. Lengths are public.
    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard !lhs.isEmpty else { return true }
        return lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                timingsafe_bcmp(left.baseAddress!, right.baseAddress!, left.count) == 0
            }
        }
    }

    static func isZero(_ bytes: Data) -> Bool {
        equal(bytes, Data(count: bytes.count))
    }

    static func zero(_ bytes: inout Data) {
        bytes.withUnsafeMutableBytes { zero($0) }
    }

    /// Wipes only the supplied storage. See Crypto.md for Swift and CryptoKit copy limits.
    static func zero(_ bytes: UnsafeMutableRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        _ = memset_s(bytes.baseAddress!, bytes.count, 0, bytes.count)
    }
}

enum WireGuardCryptoError: Error, Equatable {
    case invalidKeyLength
    case invalidNonceLength
    case invalidDigestLength
    case messageTooLarge
    case invalidSharedSecret
}
