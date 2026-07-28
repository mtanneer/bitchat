//
// LeaveRoomControl.swift
// PlaneChatApp
//
// SPEC.md UX invariant: session end must always offer "archive or clear" —
// never silently wipe. Floats over ContentView (bitchat's chat UI, reused
// as-is for Chat — see BitchatApp.swift) rather than editing bitchat's own
// header chrome for a single PlaneChat-specific action.
//

import SwiftUI

struct LeaveRoomControl: View {
    let session: ActiveRoomSession
    @ObservedObject var roomStore: RoomStore
    @ThemedPalette private var palette

    @State private var showConfirmation = false

    var body: some View {
        Button {
            showConfirmation = true
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.bitchatSystem(size: 14, weight: .medium))
                .foregroundColor(palette.secondary)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.top, 8)
        .padding(.trailing, 12)
        .confirmationDialog(
            "Leave \"\(session.roomName)\"?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button {
                roomStore.leaveRoom()
            } label: {
                Text(verbatim: "Archive & Leave")
            }
            Button(role: .destructive) {
                RoomHistoryStore().clearHistory(roomId: session.roomId)
                roomStore.leaveRoom()
            } label: {
                Text(verbatim: "Clear & Leave")
            }
            Button(role: .cancel) {} label: {
                Text(verbatim: "Cancel")
            }
        } message: {
            Text(verbatim: "Archive keeps this room's messages on this device. Clear deletes them permanently.")
        }
    }
}
