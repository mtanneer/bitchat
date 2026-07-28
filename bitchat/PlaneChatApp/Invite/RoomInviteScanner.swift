//
// RoomInviteScanner.swift
// PlaneChatApp
//
// QR scanning via AVFoundation per SPEC.md's Join Room flow. Decodes
// scanned strings with RoomInviteCodec.decodeQRString — no protobuf
// involved (see RoomInviteCodec.swift for the raw byte layout rationale).
//

import AVFoundation
import SwiftUI

protocol RoomInviteScannerDelegate: AnyObject {
    func roomInviteScanner(_ scanner: RoomInviteScanner, didScan payloadString: String)
    func roomInviteScannerDidFail(_ scanner: RoomInviteScanner, error: Error)
}

/// Thin AVFoundation wrapper: owns a capture session that watches for QR
/// codes and reports the raw scanned string to its delegate. Callers decode
/// the string with `RoomInviteCodec.decodeQRString`.
final class RoomInviteScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    enum ScannerError: Error {
        case cameraUnavailable
        case captureSessionSetupFailed
    }

    weak var delegate: RoomInviteScannerDelegate?
    let captureSession = AVCaptureSession()

    private var hasReportedThisSession = false

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw ScannerError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        guard captureSession.canAddInput(input) else {
            throw ScannerError.captureSessionSetupFailed
        }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            throw ScannerError.captureSessionSetupFailed
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        hasReportedThisSession = false
        captureSession.startRunning()
    }

    func stop() {
        captureSession.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasReportedThisSession else { return }
        guard let qrObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              qrObject.type == .qr,
              let payloadString = qrObject.stringValue else { return }

        hasReportedThisSession = true
        delegate?.roomInviteScanner(self, didScan: payloadString)
    }
}

/// SwiftUI wrapper exposing the live camera preview for the scan sheet.
struct RoomInviteScannerView: UIViewRepresentable {
    let scanner: RoomInviteScanner

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = scanner.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
