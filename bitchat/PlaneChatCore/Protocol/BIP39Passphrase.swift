//
// BIP39Passphrase.swift
// PlaneChatCore
//
// 6-word passphrase fallback per shared/spec/room-invite.md "Passphrase
// fallback": a lookup reference (NOT a self-contained credential) derived
// from the first 66 bits of SHA256(room_id || noise_static_key), 11 bits
// per word, mapped through the BIP39 wordlist. Matches
// shared/reference/planechat_ref.py's encode_invite_passphrase() exactly.
//
// Wordlist note: shared/reference/planechat_ref.py does not ship the real
// BIP39 English wordlist (no shared/reference/bip39-english.txt exists in
// the submodule at the pinned commit) — its own fallback, and the one
// shared/test-vectors/room-invite.json's expected_passphrase value was
// generated against, is a placeholder list of the form "word0000".."word2047".
// This matches that placeholder exactly so the shared test vector passes.
// Swapping in the real BIP39 English wordlist is a follow-up once the
// canonical wordlist file is added to the shared submodule — do not
// silently diverge from the reference implementation in the meantime.
//

import CryptoKit
import Foundation

enum BIP39Passphrase {
    static let wordlistSize = 2048

    static let placeholderWordlist: [String] = (0..<wordlistSize).map { String(format: "word%04d", $0) }

    /// Derives the 6-word passphrase for a room invite. `roomId`'s raw
    /// 16-byte UUID form is hashed together with the raw 32-byte static
    /// key, matching planechat_ref.py's `uuid.UUID(room_id).bytes` +
    /// `noise_static_key` concatenation exactly.
    static func derive(roomId: UUID, noiseStaticKey: Data) -> String {
        var input = Data(withUnsafeBytes(of: roomId.uuid) { Data($0) })
        input.append(noiseStaticKey)
        let digest = Data(SHA256.hash(data: input))

        let bits = digest.flatMap { byte -> [Bool] in
            (0..<8).map { bitIndex in (byte >> (7 - bitIndex)) & 1 == 1 }
        }.prefix(66)

        var words: [String] = []
        words.reserveCapacity(6)
        for wordIndex in 0..<6 {
            let chunkStart = wordIndex * 11
            let chunk = bits[chunkStart..<(chunkStart + 11)]
            let index = chunk.reduce(0) { ($0 << 1) | ($1 ? 1 : 0) }
            words.append(placeholderWordlist[index])
        }
        return words.joined(separator: " ")
    }

    /// Re-derives the passphrase and compares — used to verify a joiner's
    /// entered passphrase against a candidate (roomId, staticKey) pair.
    static func matches(roomId: UUID, noiseStaticKey: Data, passphrase: String) -> Bool {
        derive(roomId: roomId, noiseStaticKey: noiseStaticKey) == passphrase
    }
}
