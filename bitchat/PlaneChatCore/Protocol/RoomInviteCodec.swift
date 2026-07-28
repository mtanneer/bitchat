//
// RoomInviteCodec.swift
// PlaneChatCore
//
// QR payload byte layout per shared/spec/room-invite.md — a raw byte
// concatenation, NOT the RoomInvite protobuf message (protobuf's
// varint/tag overhead would blow the byte budget for no benefit at this
// fixed, known-shape payload):
//
//   room_id          16 bytes  raw UUID v4 bytes (not the 36-char string)
//   noise_static_key 32 bytes  Curve25519 public key, raw
//   room_name        <=20 bytes  UTF-8, NOT null-padded (length recovered
//                              as total_len - 52, since it's the only
//                              variable-length field before the trailer)
//   created_at        4 bytes  Unix seconds (not ms), big-endian uint32
//
// Worst case: 16 + 32 + 20 + 4 = 72 bytes -> base64url (no padding) ->
// exactly 96 chars worst case (72 is divisible by 3: 72*4/3 = 96, zero
// padding bytes — verified in room-invite.md).
//
// expires_at_ms is deliberately NOT encoded here — enforced creator-side
// only, per room-invite.md's "Expiry is NOT in the QR payload" section.
//

import Foundation

enum RoomInviteCodecError: Error {
    case roomNameTooLong
    case payloadTooShort
    case malformedUUID
    case malformedStaticKey
}

enum RoomInviteCodec {
    static let roomIdByteCount = 16
    static let staticKeyByteCount = 32
    static let maxRoomNameByteCount = 20
    static let createdAtByteCount = 4
    static let minPayloadByteCount = roomIdByteCount + staticKeyByteCount + createdAtByteCount // 52, room_name may be empty
    static let maxPayloadByteCount = roomIdByteCount + staticKeyByteCount + maxRoomNameByteCount + createdAtByteCount // 72
    /// 72 bytes base64url-encodes to exactly 96 chars with zero padding
    /// (72 is divisible by 3) — see room-invite.md's verified arithmetic.
    static let maxEncodedCharCount = 96

    /// Encodes the QR payload bytes (pre-base64url). `roomName` must be
    /// <=20 UTF-8 bytes (SPEC.md F12 / room-invite.md).
    static func encodeBytes(
        roomId: UUID,
        noiseStaticKey: Data,
        roomName: String,
        createdAt: Date
    ) throws -> Data {
        let roomNameBytes = Data(roomName.utf8)
        guard roomNameBytes.count <= maxRoomNameByteCount else {
            throw RoomInviteCodecError.roomNameTooLong
        }
        guard noiseStaticKey.count == staticKeyByteCount else {
            throw RoomInviteCodecError.malformedStaticKey
        }

        var payload = Data()
        payload.append(roomId.rawBytes)
        payload.append(noiseStaticKey)
        payload.append(roomNameBytes)

        var createdAtSeconds = UInt32(createdAt.timeIntervalSince1970).bigEndian
        withUnsafeBytes(of: &createdAtSeconds) { payload.append(contentsOf: $0) }

        return payload
    }

    /// Encodes to the final base64url (RFC 4648 §5, no padding) QR string.
    static func encodeQRString(
        roomId: UUID,
        noiseStaticKey: Data,
        roomName: String,
        createdAt: Date
    ) throws -> String {
        let bytes = try encodeBytes(roomId: roomId, noiseStaticKey: noiseStaticKey, roomName: roomName, createdAt: createdAt)
        return bytes.base64URLEncodedStringNoPadding()
    }

    /// Decodes raw QR payload bytes back into its constituent fields.
    /// `room_name`'s length is recovered as `total_len - 52` since it's the
    /// only variable-length field before the fixed 4-byte trailer.
    static func decodeBytes(_ payload: Data) throws -> (roomId: UUID, noiseStaticKey: Data, roomName: String, createdAt: Date) {
        guard payload.count >= minPayloadByteCount, payload.count <= maxPayloadByteCount else {
            throw RoomInviteCodecError.payloadTooShort
        }

        let bytes = [UInt8](payload)
        let roomIdBytes = Array(bytes[0..<roomIdByteCount])
        let staticKeyBytes = Array(bytes[roomIdByteCount..<(roomIdByteCount + staticKeyByteCount)])
        let roomNameEnd = bytes.count - createdAtByteCount
        let roomNameBytes = Array(bytes[(roomIdByteCount + staticKeyByteCount)..<roomNameEnd])
        let createdAtBytes = Array(bytes[roomNameEnd...])

        guard let roomId = UUID(rawBytes: roomIdBytes) else {
            throw RoomInviteCodecError.malformedUUID
        }
        guard let roomName = String(bytes: roomNameBytes, encoding: .utf8) else {
            throw RoomInviteCodecError.malformedStaticKey
        }

        let createdAtSeconds = createdAtBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtSeconds))

        return (roomId, Data(staticKeyBytes), roomName, createdAt)
    }

    /// Decodes a base64url (no padding) QR string produced by `encodeQRString`.
    static func decodeQRString(_ encoded: String) throws -> (roomId: UUID, noiseStaticKey: Data, roomName: String, createdAt: Date) {
        guard let data = Data(base64URLEncodedNoPadding: encoded) else {
            throw RoomInviteCodecError.payloadTooShort
        }
        return try decodeBytes(data)
    }
}

private extension UUID {
    var rawBytes: Data {
        withUnsafeBytes(of: self.uuid) { Data($0) }
    }

    init?(rawBytes: [UInt8]) {
        guard rawBytes.count == 16 else { return nil }
        let tuple = (
            rawBytes[0], rawBytes[1], rawBytes[2], rawBytes[3],
            rawBytes[4], rawBytes[5], rawBytes[6], rawBytes[7],
            rawBytes[8], rawBytes[9], rawBytes[10], rawBytes[11],
            rawBytes[12], rawBytes[13], rawBytes[14], rawBytes[15]
        )
        self = UUID(uuid: tuple)
    }
}

private extension Data {
    func base64URLEncodedStringNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncodedNoPadding string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        self = data
    }
}
