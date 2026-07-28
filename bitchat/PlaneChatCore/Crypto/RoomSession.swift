//
// RoomSession.swift
// PlaneChatCore
//
// Room-scoped state that has no bitchat precedent (shared/spec/protocol.md
// "Ordering" and "Clock handling"): per-sender sequence_num and a local
// reference epoch. Both are local bookkeeping only — sequence_num is the
// only one of the two that also appears on the wire (MessageEnvelope field
// 6); reference epoch is never a wire field, see shared/spec/protocol.md.
//

import BitFoundation
import CryptoKit
import Foundation

/// One device's view of a single room session: its own identity within the
/// room, the room's BLE scoping id, and the counters/clocks needed to build
/// outgoing `MessageEnvelope`s.
final class RoomSession {
    let roomId: UUID
    let staticKey: Curve25519.KeyAgreement.PrivateKey
    /// SHA256 fingerprint of `staticKey.publicKey` — matches
    /// `MessageEnvelope.sender_id` exactly (message.proto field 4).
    let senderId: String
    /// Wall-clock time this device created or joined this room session.
    /// Local UI bookkeeping only ("time since I joined") — never sent on
    /// the wire, per shared/spec/protocol.md's Clock Handling section.
    let referenceEpochMs: Int64

    /// Monotonic per-sender counter: starts at 0, increments by exactly 1
    /// per message, never resets or wraps within this session. No bitchat
    /// precedent — pure PlaneChat addition (shared/spec/protocol.md
    /// "Ordering").
    private var nextSequenceNum: Int32 = 0
    private let lock = NSLock()

    init(roomId: UUID, staticKey: Curve25519.KeyAgreement.PrivateKey, now: Date = Date()) {
        self.roomId = roomId
        self.staticKey = staticKey
        self.senderId = staticKey.publicKey.rawRepresentation.sha256Fingerprint()
        self.referenceEpochMs = Int64(now.timeIntervalSince1970 * 1000)
    }

    /// Returns the next sequence number for an outgoing message and
    /// advances the counter. Thread-safe.
    func allocateSequenceNum() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextSequenceNum
        nextSequenceNum += 1
        return value
    }
}
