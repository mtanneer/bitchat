//
// LZ4CompressionUtil.swift
// PlaneChatCore
//
// shared/spec/protocol.md requires LZ4 (bitchat's own CompressionUtil.swift
// uses zlib — see build-log/protocol-audit.md). Same Apple `Compression`
// framework API shape as bitchat's util, just COMPRESSION_LZ4 instead of
// COMPRESSION_ZLIB, and no entropy-heuristic skip: PlaneChat always
// compresses plaintext ChatMessage bytes before Noise-encrypting them (see
// MessageCodec.swift), so the compressor never sees high-entropy
// ciphertext the way bitchat's post-encryption compression step does.
//

import struct Foundation.Data
private import Compression

enum LZ4CompressionUtil {
    /// Matches shared/spec/protocol.md's 100-byte compression threshold
    /// (confirmed identical to bitchat's own Constants.compressionThresholdBytes).
    static let compressionThreshold = 100

    static func compress(_ data: Data) -> Data? {
        guard data.count >= compressionThreshold else { return nil }

        let maxCompressedSize = data.count + (data.count / 255) + 16
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxCompressedSize)
        defer { destinationBuffer.deallocate() }

        let compressedSize = data.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, maxCompressedSize,
                sourcePtr, data.count,
                nil, COMPRESSION_LZ4
            )
        }

        guard compressedSize > 0 && compressedSize < data.count else { return nil }

        return Data(bytes: destinationBuffer, count: compressedSize)
    }

    static func decompress(_ compressedData: Data, originalSize: Int) -> Data? {
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = compressedData.withUnsafeBytes { sourceBuffer -> Int in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, originalSize,
                sourcePtr, compressedData.count,
                nil, COMPRESSION_LZ4
            )
        }

        guard decompressedSize > 0 else { return nil }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
}
