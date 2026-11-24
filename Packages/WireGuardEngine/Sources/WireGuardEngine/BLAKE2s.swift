// SPDX-License-Identifier: MIT

import Foundation

/// Sequential BLAKE2s as specified in RFC 7693.
enum BLAKE2s {
    static let digestLength = 32
    static let blockLength = 64
    static let macLength = 16

    static func hash(_ parts: Data...) -> Data {
        digest(parts, key: Data(), outputLength: digestLength)
    }

    static func hash(_ parts: Data..., key: Data = Data(), outputLength: Int) throws -> Data {
        guard (1...digestLength).contains(outputLength) else {
            throw WireGuardCryptoError.invalidDigestLength
        }
        guard key.count <= digestLength else { throw WireGuardCryptoError.invalidKeyLength }
        return digest(parts, key: key, outputLength: outputLength)
    }

    /// The keyed 16-byte BLAKE2s configuration used by the WireGuard cookies and MACs.
    static func mac128(_ parts: Data..., key: Data) throws -> Data {
        guard (1...digestLength).contains(key.count) else {
            throw WireGuardCryptoError.invalidKeyLength
        }
        return digest(parts, key: key, outputLength: macLength)
    }

    // Unkeyed 256-bit hash with an already assembled list of parts, used by HMAC.
    static func hash(parts: [Data]) -> Data {
        digest(parts, key: Data(), outputLength: digestLength)
    }

    private static let iv: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let schedule = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    private static func digest(_ parts: [Data], key: Data, outputLength: Int) -> Data {
        var hash = iv
        hash[0] ^= 0x01010000 | (UInt32(key.count) << 8) | UInt32(outputLength)
        defer { hash.withUnsafeMutableBytes { SecretBytes.zero($0) } }

        withUnsafeTemporaryAllocation(byteCount: blockLength, alignment: 4) { block in
            block.initializeMemory(as: UInt8.self, repeating: 0)
            defer { SecretBytes.zero(block) }
            key.withUnsafeBytes { keyBytes in block.copyMemory(from: keyBytes) }

            var used = key.isEmpty ? 0 : blockLength
            var count: UInt64 = 0
            for part in parts {
                part.withUnsafeBytes { input in
                    var offset = 0
                    while offset < input.count {
                        // Keep a full block pending until another byte proves it is non-final.
                        if used == blockLength {
                            count &+= UInt64(blockLength)
                            compress(&hash, block: UnsafeRawBufferPointer(block), count: count, final: false)
                            used = 0
                        }
                        let size = min(blockLength - used, input.count - offset)
                        let destination = UnsafeMutableRawBufferPointer(rebasing: block[used..<(used + size)])
                        destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: input[offset..<(offset + size)]))
                        used += size
                        offset += size
                    }
                }
            }
            UnsafeMutableRawBufferPointer(rebasing: block[used...]).initializeMemory(as: UInt8.self, repeating: 0)
            count &+= UInt64(used)
            compress(&hash, block: UnsafeRawBufferPointer(block), count: count, final: true)
        }

        var result = Data(capacity: outputLength)
        for index in 0..<((outputLength + 3) / 4) {
            withUnsafeBytes(of: hash[index].littleEndian) {
                result.append(contentsOf: $0.prefix(outputLength - result.count))
            }
        }
        return result
    }

    private static func compress(_ hash: inout [UInt32], block: UnsafeRawBufferPointer, count: UInt64, final: Bool) {
        var words = (0..<16).map {
            UInt32(littleEndian: block.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))
        }
        var state = hash + iv
        defer {
            words.withUnsafeMutableBytes { SecretBytes.zero($0) }
            state.withUnsafeMutableBytes { SecretBytes.zero($0) }
        }
        state[12] ^= UInt32(truncatingIfNeeded: count)
        state[13] ^= UInt32(count >> 32)
        if final { state[14] = ~state[14] }

        for order in schedule {
            mix(&state, 0, 4, 8, 12, words[order[0]], words[order[1]])
            mix(&state, 1, 5, 9, 13, words[order[2]], words[order[3]])
            mix(&state, 2, 6, 10, 14, words[order[4]], words[order[5]])
            mix(&state, 3, 7, 11, 15, words[order[6]], words[order[7]])
            mix(&state, 0, 5, 10, 15, words[order[8]], words[order[9]])
            mix(&state, 1, 6, 11, 12, words[order[10]], words[order[11]])
            mix(&state, 2, 7, 8, 13, words[order[12]], words[order[13]])
            mix(&state, 3, 4, 9, 14, words[order[14]], words[order[15]])
        }

        for index in hash.indices {
            hash[index] ^= state[index] ^ state[index + 8]
        }
    }

    private static func mix(_ v: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotateRight(v[d] ^ v[a], by: 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 12)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotateRight(v[d] ^ v[a], by: 8)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], by: 7)
    }

    private static func rotateRight(_ word: UInt32, by count: Int) -> UInt32 {
        (word >> count) | (word << (32 - count))
    }
}
