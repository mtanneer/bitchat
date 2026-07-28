//
// RoomMembership.swift
// PlaneChatCore
//
// Two-phase admission (SPEC.md F8 / shared/spec/protocol.md "Two-phase
// admission"): phase 1 (room_id-scoped BLE service UUID) is transport-level
// and lives in BLEService's advertising/scanning setup. This file is phase
// 2 — cryptographic admission — and runs entirely after bitchat's existing
// Noise XX handshake has already completed unconditionally for every peer,
// member or not, so a non-member's mere presence never leaks room activity
// via handshake-abort timing.
//

import CryptoKit
import Foundation

/// The set of Noise static public keys (as raw 32-byte Curve25519 keys)
/// accepted into a room, populated from accepted invites at room creation
/// or join time.
struct RoomMemberList {
    private(set) var staticPublicKeys: Set<Data>

    init(staticPublicKeys: Set<Data> = []) {
        self.staticPublicKeys = staticPublicKeys
    }

    mutating func add(_ key: Curve25519.KeyAgreement.PublicKey) {
        staticPublicKeys.insert(key.rawRepresentation)
    }

    func contains(_ key: Curve25519.KeyAgreement.PublicKey) -> Bool {
        staticPublicKeys.contains(key.rawRepresentation)
    }
}

/// Gates application-layer traffic on room membership, after bitchat's
/// existing `NoiseEncryptionService` completes a handshake.
///
/// Wire this up via `NoiseEncryptionService.addOnPeerAuthenticatedHandler` —
/// that handler already fires unconditionally once per completed handshake
/// (see `NoiseEncryptionService.handleSessionEstablished`), which is exactly
/// bitchat's existing "phase 1 always completes" behavior this design
/// requires; no changes to bitchat's Noise code are needed.
final class RoomMembership {
    private let members: RoomMemberList
    /// Called with the remote peer's static public key when the peer is a
    /// room member and MessageEnvelope traffic may now be sent to it.
    var onMemberAdmitted: ((_ remoteStaticKey: Curve25519.KeyAgreement.PublicKey) -> Void)?
    /// Called when a completed-handshake peer is NOT a room member — the
    /// caller must disconnect immediately and must not have sent (and must
    /// not send) any MessageEnvelope application data to this peer.
    var onNonMemberRejected: ((_ remoteStaticKey: Curve25519.KeyAgreement.PublicKey) -> Void)?

    init(members: RoomMemberList) {
        self.members = members
    }

    /// Call from a `NoiseEncryptionService.addOnPeerAuthenticatedHandler`
    /// callback (or equivalent), after `split()`/session-established, with
    /// the now-known remote static public key.
    func evaluate(remoteStaticKey: Curve25519.KeyAgreement.PublicKey) {
        if members.contains(remoteStaticKey) {
            onMemberAdmitted?(remoteStaticKey)
        } else {
            onNonMemberRejected?(remoteStaticKey)
        }
    }
}
