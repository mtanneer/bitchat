//
// L2CAPStreamFraming.swift
// bitchat
//
// PlaneChat: 4-byte big-endian length-prefix framing over a CBL2CAPChannel's
// streams — mirrors apps.android.planechat's FramedWriter/FramedReader
// (core/ble/FramedStream.kt) exactly, byte for byte. L2CAP CoC is a raw byte
// stream with no message boundaries (unlike GATT, which is message-oriented),
// so a length prefix is required on both platforms; Android already needed
// this since it never uses GATT for chat data at all, so iOS's L2CAP path
// (added for Android interop — see BLEService's PSM characteristic handling)
// must speak the same framing to interoperate.
//

import CoreBluetooth
import Foundation

/// Owns one CBL2CAPChannel's input+output streams: writes length-prefixed
/// frames out, reassembles length-prefixed frames in, and hands each
/// complete payload to `onFrame`. Runs its streams on a dedicated thread's
/// run loop (CBL2CAPChannel streams require an actual scheduled run loop to
/// deliver events — the BLE delegate queue is not itself a run loop).
final class L2CAPFramedChannel: NSObject, StreamDelegate {
    private static let maxFrameSize = 16 * 1024 * 1024 // matches FramedReader.MAX_FRAME_SIZE

    private let channel: CBL2CAPChannel
    private let onFrame: (Data) -> Void
    private let onClose: () -> Void

    private var readBuffer = Data()
    private var writeQueue: [Data] = []
    private var outputSpaceAvailable = false

    private var runLoop: RunLoop?

    init(channel: CBL2CAPChannel, onFrame: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.channel = channel
        self.onFrame = onFrame
        self.onClose = onClose
        super.init()

        let thread = Thread { [weak self] in
            self?.runOnDedicatedThread()
        }
        thread.name = "L2CAPFramedChannel"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private func runOnDedicatedThread() {
        let loop = RunLoop.current
        runLoop = loop

        channel.inputStream.delegate = self
        channel.outputStream.delegate = self
        channel.inputStream.schedule(in: loop, forMode: .default)
        channel.outputStream.schedule(in: loop, forMode: .default)
        channel.inputStream.open()
        channel.outputStream.open()

        // Keep the run loop alive for as long as this channel is in use —
        // CBL2CAPChannel streams deliver events only while their run loop runs.
        while runLoop != nil {
            loop.run(mode: .default, before: .distantFuture)
        }
    }

    /// Enqueues a payload to send, prefixed with its 4-byte big-endian length
    /// (matches FramedWriter.writeFrame exactly). Thread-safe: call from any
    /// queue, actual writes happen on this channel's dedicated thread.
    func send(_ payload: Data) {
        guard payload.count <= Self.maxFrameSize else { return }
        var lengthPrefixed = Data(capacity: 4 + payload.count)
        var bigEndianLength = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &bigEndianLength) { lengthPrefixed.append(contentsOf: $0) }
        lengthPrefixed.append(payload)

        if let runLoop {
            runLoop.perform { [weak self] in
                self?.writeQueue.append(lengthPrefixed)
                self?.flushWriteQueueIfPossible()
            }
        }
    }

    func close() {
        runLoop = nil
        channel.inputStream.close()
        channel.outputStream.close()
    }

    private func flushWriteQueueIfPossible() {
        guard outputSpaceAvailable, !writeQueue.isEmpty else { return }
        let next = writeQueue.removeFirst()
        next.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let written = channel.outputStream.write(base, maxLength: next.count)
            if written < 0 {
                onClose()
            }
        }
        outputSpaceAvailable = false
    }

    private func drainAvailableFrames() {
        while true {
            guard readBuffer.count >= 4 else { return }
            let lengthBytes = readBuffer.prefix(4)
            let length = Int(UInt32(bigEndian: lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard length >= 0, length <= Self.maxFrameSize else {
                // Corrupt/malicious length header — matches FramedReader's
                // own reject-outright behavior rather than attempting an
                // unbounded allocation.
                onClose()
                return
            }
            guard readBuffer.count >= 4 + length else { return }

            let payload = readBuffer.subdata(in: 4..<(4 + length))
            readBuffer.removeSubrange(0..<(4 + length))
            onFrame(payload)
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard aStream === channel.inputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = channel.inputStream.read(&buffer, maxLength: buffer.count)
            if bytesRead > 0 {
                readBuffer.append(contentsOf: buffer[0..<bytesRead])
                drainAvailableFrames()
            } else if bytesRead < 0 {
                onClose()
            }

        case .hasSpaceAvailable:
            guard aStream === channel.outputStream else { return }
            outputSpaceAvailable = true
            flushWriteQueueIfPossible()

        case .endEncountered, .errorOccurred:
            onClose()

        default:
            break
        }
    }
}
