//
// ProtocolVectorTests.swift
// bitchatTests
//
// Loads shared/test-vectors/{encryption,gossip,room-invite}.json directly
// from the submodule (not copied duplicates — see CLAUDE.md "Test vectors
// are the interop contract") and runs them through the real Swift
// crypto/codec/dedup paths, asserting exact match against the cross-platform
// contract shared/reference/planechat_ref.py generated them from.
//

import CryptoKit
import Foundation
import Testing
import BitFoundation
@testable import PlaneChat

private enum SharedVectorFixtures {
    /// bitchatTests/ProtocolVectorTests.swift -> tmp/bitchat/bitchatTests -> tmp/bitchat -> tmp -> apps.ios.planechat
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // bitchatTests
        .deletingLastPathComponent() // tmp/bitchat
        .deletingLastPathComponent() // tmp
        .deletingLastPathComponent() // apps.ios.planechat

    static func load<T: Decodable>(_ relativePath: String, as type: T.Type) throws -> T {
        let url = repoRoot.appendingPathComponent("shared/test-vectors/\(relativePath)")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - room-invite.json

private struct RoomInviteVectorFile: Codable {
    let vectors: [RoomInviteVector]
}

private struct RoomInviteVector: Codable {
    let description: String
    let type: String
    let room_id: String
    let noise_static_key: String
    let room_name: String?
    let created_at_ms: Int64?
    let expected_encoded: String?
    let expected_passphrase: String?
}

struct RoomInviteVectorTests {
    private static func loadVectors() throws -> [RoomInviteVector] {
        try SharedVectorFixtures.load("room-invite.json", as: RoomInviteVectorFile.self).vectors
    }

    @Test
    func qrVectorsRoundTripByteExact() throws {
        let vectors = try Self.loadVectors().filter { $0.type == "qr" }
        #expect(!vectors.isEmpty)

        for vector in vectors {
            let roomId = try #require(UUID(uuidString: vector.room_id), Comment(rawValue: vector.description))
            let staticKey = try #require(Data(hexString: vector.noise_static_key), Comment(rawValue: vector.description))
            let roomName = try #require(vector.room_name, Comment(rawValue: vector.description))
            let createdAtMs = try #require(vector.created_at_ms, Comment(rawValue: vector.description))
            let expected = try #require(vector.expected_encoded, Comment(rawValue: vector.description))

            let encoded = try RoomInviteCodec.encodeQRString(
                roomId: roomId,
                noiseStaticKey: staticKey,
                roomName: roomName,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
            )
            #expect(encoded == expected, Comment(rawValue: vector.description))

            let decoded = try RoomInviteCodec.decodeQRString(expected)
            #expect(decoded.roomId == roomId, Comment(rawValue: vector.description))
            #expect(decoded.noiseStaticKey == staticKey, Comment(rawValue: vector.description))
            #expect(decoded.roomName == roomName, Comment(rawValue: vector.description))
        }
    }

    @Test
    func passphraseVectorsMatchExactly() throws {
        let vectors = try Self.loadVectors().filter { $0.type == "passphrase" }
        #expect(!vectors.isEmpty)

        for vector in vectors {
            let roomId = try #require(UUID(uuidString: vector.room_id), Comment(rawValue: vector.description))
            let staticKey = try #require(Data(hexString: vector.noise_static_key), Comment(rawValue: vector.description))
            let expected = try #require(vector.expected_passphrase, Comment(rawValue: vector.description))

            let derived = BIP39Passphrase.derive(roomId: roomId, noiseStaticKey: staticKey)
            #expect(derived == expected, Comment(rawValue: vector.description))
        }
    }
}

// MARK: - encryption.json

private struct EncryptionVectorFile: Codable {
    let protocol_name: String
    let vectors: [EncryptionVector]
}

private struct EncryptionVector: Codable {
    let description: String
    let initiator_static_private: String
    let initiator_static_public: String
    let responder_static_private: String
    let responder_static_public: String
    let initiator_ephemeral_private: String
    let responder_ephemeral_private: String
    let plaintext: String
    let ciphertext: String
}

/// Drives bitchat's own `NoiseHandshakeState` through a full XX handshake
/// with the vector's fixed keys, exactly matching
/// `shared/reference/planechat_ref.py`'s `establish_session` (3 empty-payload
/// handshake messages, then a single transport `encrypt(plaintext)` on the
/// initiator's send cipher — see planechat_ref.py's docstring). This proves
/// the SAME Noise implementation PlaneChat's mesh code already uses
/// (`Noise/NoiseProtocol.swift`, reused as-is per protocol-audit.md) produces
/// byte-identical transport ciphertext to the Python reference.
struct EncryptionVectorTests {
    private static func loadVectors() throws -> [EncryptionVector] {
        try SharedVectorFixtures.load("encryption.json", as: EncryptionVectorFile.self).vectors
    }

    @Test
    func vectorsMatchRealNoiseImplementation() throws {
        let file = try SharedVectorFixtures.load("encryption.json", as: EncryptionVectorFile.self)
        #expect(file.protocol_name == "Noise_XX_25519_ChaChaPoly_SHA256")

        for vector in try Self.loadVectors() {
            try runVector(vector)
        }
    }

    private func runVector(_ vector: EncryptionVector) throws {
        let comment = Comment(rawValue: vector.description)
        let keychain = MockKeychain()

        let initiatorStatic = try key(vector.initiator_static_private, comment)
        let responderStatic = try key(vector.responder_static_private, comment)
        let initiatorEphemeral = try key(vector.initiator_ephemeral_private, comment)
        let responderEphemeral = try key(vector.responder_ephemeral_private, comment)

        let initiatorHandshake = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: initiatorStatic,
            predeterminedEphemeralKey: initiatorEphemeral
        )
        let responderHandshake = NoiseHandshakeState(
            role: .responder,
            pattern: .XX,
            keychain: keychain,
            localStaticKey: responderStatic,
            predeterminedEphemeralKey: responderEphemeral
        )

        // XX: -> e, <- e ee s es, -> s se — matches planechat_ref.py's
        // establish_session exactly (empty payloads on every handshake message).
        let msg1 = try initiatorHandshake.writeMessage()
        _ = try responderHandshake.readMessage(msg1)

        let msg2 = try responderHandshake.writeMessage()
        _ = try initiatorHandshake.readMessage(msg2)

        let msg3 = try initiatorHandshake.writeMessage()
        _ = try responderHandshake.readMessage(msg3)

        // useExtractedNonce: false — the standard Noise transport-message
        // shape (ciphertext+tag, no embedded nonce prefix), matching the
        // Python noiseprotocol library's session.encrypt output. bitchat's
        // own production NoiseSession uses `true` (nonce-prefixed, its own
        // replay-window scheme) — a deliberate divergence from plain Noise
        // transport framing, not something these cross-platform vectors use.
        let (initiatorSend, _, _) = try initiatorHandshake.getTransportCiphers(useExtractedNonce: false)

        let plaintext = try #require(Data(hexString: vector.plaintext), comment)
        let expectedCiphertext = try #require(Data(hexString: vector.ciphertext), comment)

        let ciphertext = try initiatorSend.encrypt(plaintext: plaintext)
        #expect(ciphertext == expectedCiphertext, comment)
    }

    private func key(_ hex: String, _ comment: Comment) throws -> Curve25519.KeyAgreement.PrivateKey {
        let raw = try #require(Data(hexString: hex), comment)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }
}

// MARK: - gossip.json

private struct GossipVectorFile: Codable {
    let vectors: [GossipVector]
}

private struct GossipVector: Codable {
    let description: String
    let nodes: [String]
    let topology: [[String]]
    let origin_node: String
    let room_id: String
    let sender_id: String
    let message_id: String
    let payload_hex: String
    let sequence_num: Int32
    let timestamp_ms: Int64
    let ttl: Int32
    let expected_received_by: [String]
}

/// In-process mesh-node stand-in mirroring `planechat_ref.py`'s `GossipNode`
/// exactly (dedup -> TTL decrement/drop -> relay-to-all-but-sender), but
/// backed by bitchat's REAL `MessageDeduplicator` instead of reimplementing
/// dedup — per shared/spec/protocol.md, dedup is "reuse bitchat's
/// MessageDeduplicator as-is, do not reimplement". No BLE/GATT involved, same
/// as the Python reference: peers are wired directly, standing in for a BLE
/// connection.
private final class GossipSimNode {
    let nodeID: String
    private(set) var peers: [GossipSimNode] = []
    private(set) var received: [Planechat_MessageEnvelope] = []
    private let dedup = MessageDeduplicator()

    init(nodeID: String) {
        self.nodeID = nodeID
    }

    func connect(_ other: GossipSimNode) {
        if !peers.contains(where: { $0 === other }) { peers.append(other) }
        if !other.peers.contains(where: { $0 === self }) { other.peers.append(self) }
    }

    func broadcast(_ envelope: Planechat_MessageEnvelope) {
        _ = dedup.isDuplicate(envelope.messageID)
        for peer in peers {
            peer.receive(envelope, from: self)
        }
    }

    private func receive(_ envelope: Planechat_MessageEnvelope, from sender: GossipSimNode) {
        guard !dedup.isDuplicate(envelope.messageID) else { return }
        received.append(envelope)

        var relayed = envelope
        relayed.ttl -= 1
        guard relayed.ttl > 0 else { return }

        for peer in peers where peer !== sender {
            peer.receive(relayed, from: self)
        }
    }
}

struct GossipVectorTests {
    private static func loadVectors() throws -> [GossipVector] {
        try SharedVectorFixtures.load("gossip.json", as: GossipVectorFile.self).vectors
    }

    @Test
    func vectorsMatchExpectedRelayFanout() throws {
        for vector in try Self.loadVectors() {
            let comment = Comment(rawValue: vector.description)

            var nodesByID: [String: GossipSimNode] = [:]
            for name in vector.nodes {
                nodesByID[name] = GossipSimNode(nodeID: name)
            }
            for edge in vector.topology {
                let a = try #require(nodesByID[edge[0]], comment)
                let b = try #require(nodesByID[edge[1]], comment)
                a.connect(b)
            }

            var envelope = Planechat_MessageEnvelope()
            envelope.protocolVersion = 1
            envelope.messageID = vector.message_id
            envelope.roomID = vector.room_id
            envelope.senderID = vector.sender_id
            envelope.timestampMs = vector.timestamp_ms
            envelope.sequenceNum = vector.sequence_num
            envelope.ttl = vector.ttl
            envelope.payload = try #require(Data(hexString: vector.payload_hex), comment)
            envelope.chunkIndex = 0
            envelope.totalChunks = 1

            let origin = try #require(nodesByID[vector.origin_node], comment)
            origin.broadcast(envelope)

            let actualReceivedBy = Set(nodesByID.filter { _, node in
                node.received.contains { $0.messageID == envelope.messageID }
            }.keys)
            let expectedReceivedBy = Set(vector.expected_received_by)

            #expect(actualReceivedBy == expectedReceivedBy, comment)
        }
    }
}
