//
// CreateRoomView.swift
// PlaneChatApp
//
// Pre-flight room creation (SPEC.md "Create Room" screen / F12). Generates a
// fresh roomId + Noise static keypair locally (shared/spec/room-invite.md:
// "Room creator generates a Noise static keypair and a roomId locally"),
// derives the invite QR + passphrase fallback, and on confirmation activates
// the room via RoomStore so BitchatApp swaps to the mesh/ContentView.
//

import CryptoKit
import SwiftUI

struct CreateRoomView: View {
    @EnvironmentObject private var roomStore: RoomStore
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @State private var roomName: String = ""
    @State private var pendingRoomId = UUID()
    @State private var pendingStaticKey = Curve25519.KeyAgreement.PrivateKey()
    @State private var createdAt = Date()

    private var trimmedName: String {
        roomName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SPEC.md/RoomInviteCodec: room_name is capped at 20 UTF-8 bytes.
    private var isNameValid: Bool {
        let count = Data(trimmedName.utf8).count
        return count > 0 && count <= RoomInviteCodec.maxRoomNameByteCount
    }

    private var invitePayload: String? {
        guard isNameValid else { return nil }
        return try? RoomInviteCodec.encodeQRString(
            roomId: pendingRoomId,
            noiseStaticKey: pendingStaticKey.publicKey.rawRepresentation,
            roomName: trimmedName,
            createdAt: createdAt
        )
    }

    private var passphrase: String? {
        guard isNameValid else { return nil }
        return BIP39Passphrase.derive(roomId: pendingRoomId, noiseStaticKey: pendingStaticKey.publicKey.rawRepresentation)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ThemedRootBackground().ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: "Room name")
                                .bitchatFont(size: 13, weight: .semibold)
                                .foregroundColor(palette.secondary)
                            TextField("e.g. Row 22 crew", text: $roomName)
                                .bitchatFont(size: 17)
                                .padding(12)
                                .themedInputBackground()
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                        if let invitePayload, let qrImage = RoomInviteQRCode.generate(from: invitePayload) {
                            VStack(spacing: 12) {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 220, height: 220)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                if let passphrase {
                                    VStack(spacing: 4) {
                                        Text(verbatim: "Passphrase fallback")
                                            .bitchatFont(size: 12)
                                            .foregroundColor(palette.secondary)
                                        Text(verbatim: passphrase)
                                            .bitchatFont(size: 15, weight: .medium)
                                            .foregroundColor(palette.primary)
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                        } else {
                            Text(verbatim: "Enter a room name (up to 20 characters) to generate an invite.")
                                .bitchatFont(size: 14)
                                .foregroundColor(palette.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .padding(.top, 40)
                        }

                        Spacer(minLength: 24)

                        Button {
                            roomStore.setActiveSession(
                                ActiveRoomSession(roomId: pendingRoomId, staticKey: pendingStaticKey, roomName: trimmedName)
                            )
                        } label: {
                            Text(verbatim: "Start Room")
                                .bitchatFont(size: 17, weight: .semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .foregroundColor(.white)
                        .background(
                            (isNameValid ? palette.accent : palette.secondary.opacity(0.4)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .disabled(!isNameValid)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Create Room")
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
        }
    }
}

#Preview {
    CreateRoomView()
        .environmentObject(RoomStore())
}
