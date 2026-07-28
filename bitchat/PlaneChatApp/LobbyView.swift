//
// LobbyView.swift
// PlaneChatApp
//
// Post-room, pre-chat waiting room (SPEC.md Lobby screen). Shows the room
// name and who's connected over the mesh so far, then hands off to
// ContentView (bitchat's existing chat UI) once the user is ready to talk.
//
// UX invariant (SPEC.md): the zero-peer state must never look like an
// error — it's the normal state right after creating/joining a room, before
// anyone else's device has come into BLE range. MeshEmptyStateView already
// implements this (radar animation + sightings tally) for bitchat's chat
// timeline, so Lobby reuses it directly instead of inventing a second
// "searching" visual language.
//

import SwiftUI

struct LobbyView: View {
    let roomName: String
    let onEnterChat: () -> Void

    @EnvironmentObject private var peerListModel: PeerListModel
    @ThemedPalette private var palette

    private var connectedCount: Int { peerListModel.connectedMeshPeerCount }

    var body: some View {
        ZStack {
            ThemedRootBackground().ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Text(verbatim: roomName)
                        .bitchatFont(size: 28, weight: .bold)
                        .foregroundColor(palette.primary)
                    Text(verbatim: connectedCount == 0
                         ? "Waiting for others to join…"
                         : "\(connectedCount) connected")
                        .bitchatFont(size: 15)
                        .foregroundColor(palette.secondary)
                }

                if connectedCount == 0 {
                    MeshEmptyStateView(fillHeight: 160)
                } else {
                    MeshPeerList(
                        onTapPeer: { _ in },
                        onToggleFavorite: { _ in },
                        onShowFingerprint: { _ in }
                    )
                    .frame(maxHeight: 280)
                }

                Spacer()

                // Composer stays reachable even at zero peers (SPEC.md
                // invariant: messages queue in the outbox) — Enter Chat is
                // never gated on connectedCount.
                Button {
                    onEnterChat()
                } label: {
                    Text(verbatim: "Enter Chat")
                        .bitchatFont(size: 17, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .foregroundColor(.white)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
    }
}
