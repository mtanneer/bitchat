//
// RoomInviteQRCode.swift
// PlaneChatApp
//
// QR generation via CoreImage per SPEC.md ("QR | AVFoundation + CoreImage")
// and F12 (error correction level M — 15% recovery, balances density with
// scan reliability per shared/spec/room-invite.md). Encodes the string
// produced by RoomInviteCodec.encodeQRString — no protobuf involved.
//

import CoreImage.CIFilterBuiltins
import UIKit

enum RoomInviteQRCode {
    /// Renders the invite payload string as a QR code image.
    /// Error correction level M per F12 — the ~96-char worst-case payload
    /// fits Version 3's byte-mode capacity at M with headroom to spare.
    static func generate(from payloadString: String, scale: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payloadString.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = outputImage.transformed(by: transform)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
