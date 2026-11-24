// SPDX-License-Identifier: MIT

enum WireGuardCryptoError: Error, Equatable, Sendable {
    case invalidKeyLength
    case invalidNonceLength
    case invalidDigestLength
    case messageTooLarge
    case invalidSharedSecret
}
