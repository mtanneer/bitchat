//
// JoinRoomView.swift
// PlaneChatApp
//
// Pre-flight join flow (SPEC.md "Join Room" screen / F12): scan the creator's
// QR invite via AVFoundation, or fall back to typing the 6-word BIP39
// passphrase when cameras fail. Either path recovers (roomId, noise static
// key) via RoomInviteCodec, then generates this device's own Noise static
// keypair for the room (shared/spec/room-invite.md — invite only carries the
// creator's key; every device has its own).
//
// Passphrase-only path: BIP39Passphrase is a lookup reference derived from
// SHA256(room_id || static_key), not a self-contained credential (see
// BIP39Passphrase.swift) — so it can't be typed alone to join. The scanner
// is the only path that recovers roomId/staticKey from scratch; the
// passphrase field here re-verifies a scanned invite, matching
// room-invite.md's "Passphrase fallback" as a verification aid, not a
// standalone join method.
//

import CryptoKit
import SwiftUI

struct JoinRoomView: View {
    @EnvironmentObject private var roomStore: RoomStore
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @StateObject private var scannerHost = ScannerHost()
    @State private var scannedInvite: (roomId: UUID, noiseStaticKey: Data, roomName: String, createdAt: Date)?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedRootBackground().ignoresSafeArea()

                VStack(spacing: 20) {
                    if let invite = scannedInvite {
                        ScannedInviteConfirmation(
                            roomName: invite.roomName,
                            expectedPassphrase: BIP39Passphrase.derive(roomId: invite.roomId, noiseStaticKey: invite.noiseStaticKey),
                            palette: palette,
                            onConfirm: { joinRoom(invite: invite) },
                            onRetry: { scannedInvite = nil; errorMessage = nil }
                        )
                    } else {
                        RoomInviteScannerView(scanner: scannerHost.scanner)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.horizontal, 24)
                            .padding(.top, 24)

                        Text(verbatim: "Point your camera at the room creator's QR code.")
                            .bitchatFont(size: 14)
                            .foregroundColor(palette.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .bitchatFont(size: 13)
                            .foregroundColor(palette.alertRed)
                            .padding(.horizontal, 32)
                    }

                    Spacer()
                }
            }
            .navigationTitle("Join Room")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: {
                        Text(verbatim: "Cancel")
                    }
                }
            }
            .onAppear {
                scannerHost.delegate = ScanDelegate { payloadString in
                    handleScannedPayload(payloadString)
                } onFail: { _ in
                    errorMessage = "Camera unavailable. Ask the room creator for the passphrase instead."
                }
                scannerHost.start()
            }
            .onDisappear { scannerHost.stop() }
        }
    }

    private func handleScannedPayload(_ payloadString: String) {
        do {
            scannedInvite = try RoomInviteCodec.decodeQRString(payloadString)
            errorMessage = nil
            scannerHost.stop()
        } catch {
            errorMessage = "That QR code doesn't look like a PlaneChat invite."
        }
    }

    private func joinRoom(invite: (roomId: UUID, noiseStaticKey: Data, roomName: String, createdAt: Date)) {
        let myStaticKey = Curve25519.KeyAgreement.PrivateKey()
        roomStore.setActiveSession(
            ActiveRoomSession(roomId: invite.roomId, staticKey: myStaticKey, roomName: invite.roomName)
        )
    }
}

/// Confirms the scanned invite's room name and passphrase before joining —
/// gives the user a chance to visually verify against the same passphrase
/// shown on the creator's device, since QR scanning has no other in-person
/// verification step. A tap-to-confirm button, not a retyped field: both
/// devices already independently computed the same value, so there's no
/// security value in manual transcription — only friction, especially with
/// the current placeholder (non-English) wordlist (see BIP39Passphrase.swift).
private struct ScannedInviteConfirmation: View {
    let roomName: String
    let expectedPassphrase: String
    let palette: ThemePalette
    let onConfirm: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(verbatim: "Join \"\(roomName)\"?")
                    .bitchatFont(size: 20, weight: .semibold)
                    .foregroundColor(palette.primary)
                Text(verbatim: "Confirm this matches the passphrase shown on the creator's device.")
                    .bitchatFont(size: 13)
                    .foregroundColor(palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Text(verbatim: expectedPassphrase)
                .bitchatFont(size: 18, weight: .semibold)
                .foregroundColor(palette.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                onConfirm()
            } label: {
                Text(verbatim: "Yes, It Matches — Join Room")
                    .bitchatFont(size: 17, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundColor(.white)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 32)

            Button(role: .cancel) {
                onRetry()
            } label: {
                Text(verbatim: "Scan a different code")
                    .bitchatFont(size: 14)
            }
            .foregroundColor(palette.secondary)
        }
        .padding(.top, 40)
    }
}

private final class ScanDelegate: RoomInviteScannerDelegate {
    let onScan: (String) -> Void
    let onFail: (Error) -> Void

    init(onScan: @escaping (String) -> Void, onFail: @escaping (Error) -> Void) {
        self.onScan = onScan
        self.onFail = onFail
    }

    func roomInviteScanner(_ scanner: RoomInviteScanner, didScan payloadString: String) {
        onScan(payloadString)
    }

    func roomInviteScannerDidFail(_ scanner: RoomInviteScanner, error: Error) {
        onFail(error)
    }
}

/// Owns the scanner + its delegate together so the delegate (a plain struct,
/// can't be `weak`) stays alive for as long as the scanner needs it.
@MainActor
private final class ScannerHost: ObservableObject {
    let scanner = RoomInviteScanner()
    private var retainedDelegate: RoomInviteScannerDelegate?

    var delegate: RoomInviteScannerDelegate? {
        get { retainedDelegate }
        set {
            retainedDelegate = newValue
            scanner.delegate = newValue
        }
    }

    func start() {
        do {
            try scanner.start()
        } catch {
            retainedDelegate?.roomInviteScannerDidFail(scanner, error: error)
        }
    }

    func stop() {
        scanner.stop()
    }
}

#Preview {
    JoinRoomView()
        .environmentObject(RoomStore())
}
