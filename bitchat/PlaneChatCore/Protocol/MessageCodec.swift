//
// MessageCodec.swift
// PlaneChatCore
//
// Encodes/decodes shared/spec/message.proto's MessageEnvelope per the
// packet lifecycle in shared/spec/protocol.md:
//
//   ChatMessage -> LZ4-compress (if >= threshold) -> Noise-encrypt -> wrap
//
// This is compress-BEFORE-encrypt, the opposite of bitchat's own pipeline
// (bitchat compresses the already-assembled, already-encrypted packet at
// final wire-framing time — see build-log/protocol-audit.md). Track 2 does
// not reuse bitchat's BinaryProtocol.swift compression call sites for this
// reason; this is new PlaneChat-specific framing on top of the same
// generated protobuf types.
//

import Foundation

/// Abstracts Noise encrypt/decrypt so this codec can be exercised against
/// fixed-ephemeral-key test vectors (see PlaneChatTests/ProtocolVectorTests)
/// without depending on a live BLE-connected NoiseSession.
protocol MessageCipher {
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
}

enum MessageCodecError: Error {
    case decompressionFailed
    case emptyEnvelope
    case malformedPreamble
}

/// Inner framing carried inside `MessageEnvelope.payload` before
/// Noise-encryption, mirroring bitchat's own compressed/uncompressed
/// preamble in `BinaryProtocol.swift` (flag byte + optional original-size
/// prefix) so a receiver can tell compressed bytes from plain bytes without
/// a separate wire field. Distinct from bitchat's version only in using
/// LZ4 instead of zlib and running before encryption instead of after.
private enum CompressionPreamble {
    static let isCompressedFlag: UInt8 = 0x01
    static let isPlainFlag: UInt8 = 0x00

    static func wrap(_ plaintext: Data) -> Data {
        if let compressed = LZ4CompressionUtil.compress(plaintext) {
            var framed = Data([isCompressedFlag])
            var originalSize = UInt32(plaintext.count).bigEndian
            withUnsafeBytes(of: &originalSize) { framed.append(contentsOf: $0) }
            framed.append(compressed)
            return framed
        }
        var framed = Data([isPlainFlag])
        framed.append(plaintext)
        return framed
    }

    static func unwrap(_ framed: Data) throws -> Data {
        guard let flag = framed.first else { throw MessageCodecError.malformedPreamble }
        let body = framed.dropFirst()

        if flag == isPlainFlag {
            return Data(body)
        }
        guard flag == isCompressedFlag, body.count > 4 else {
            throw MessageCodecError.malformedPreamble
        }
        let sizeBytes = body.prefix(4)
        let originalSize = Int(UInt32(bigEndian: sizeBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        let compressed = body.dropFirst(4)
        guard let decompressed = LZ4CompressionUtil.decompress(Data(compressed), originalSize: originalSize),
              decompressed.count == originalSize else {
            throw MessageCodecError.decompressionFailed
        }
        return decompressed
    }
}

enum MessageCodec {
    /// Compresses (if over threshold) then Noise-encrypts a ChatMessage,
    /// wrapping the result in a MessageEnvelope with the given routing
    /// metadata. `sequenceNum` should come from `RoomSession.allocateSequenceNum()`.
    static func encode(
        chatMessage: Planechat_ChatMessage,
        roomId: UUID,
        senderId: String,
        sequenceNum: Int32,
        ttl: Int32 = 7,
        cipher: MessageCipher
    ) throws -> Planechat_MessageEnvelope {
        let plaintext = try chatMessage.serializedData()
        let payloadToEncrypt = CompressionPreamble.wrap(plaintext)
        let ciphertext = try cipher.encrypt(payloadToEncrypt)

        var envelope = Planechat_MessageEnvelope()
        envelope.protocolVersion = 1
        envelope.messageID = UUID().uuidString
        envelope.roomID = roomId.uuidString
        envelope.senderID = senderId
        envelope.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        envelope.sequenceNum = sequenceNum
        envelope.ttl = ttl
        envelope.payload = ciphertext
        envelope.chunkIndex = 0
        envelope.totalChunks = 1
        return envelope
    }

    /// Reverses `encode`: Noise-decrypt, then unwrap the compression
    /// preamble (flag byte tells us compressed-vs-plain, no guessing).
    static func decode(
        envelope: Planechat_MessageEnvelope,
        cipher: MessageCipher
    ) throws -> Planechat_ChatMessage {
        guard !envelope.payload.isEmpty else { throw MessageCodecError.emptyEnvelope }

        let decrypted = try cipher.decrypt(envelope.payload)
        let plaintext = try CompressionPreamble.unwrap(decrypted)
        return try Planechat_ChatMessage(serializedBytes: plaintext)
    }
}
