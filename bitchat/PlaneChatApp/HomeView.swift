//
// HomeView.swift
// PlaneChatApp
//
// First screen, shown before any room exists (SPEC.md pre-flight UX: Create
// Room / Join Room). Gates ContentView/AppRuntime — see RoomStore.swift for
// why: BLEService's service UUID is scoped to roomId at construction, so the
// mesh can't start until a room is chosen here.
//

import CoreBluetooth
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var roomStore: RoomStore
    @StateObject private var bluetoothMonitor = BluetoothStateMonitor()
    @ThemedPalette private var palette

    @State private var showCreateRoom = false
    @State private var showJoinRoom = false

    var body: some View {
        ZStack {
            ThemedRootBackground().ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Text("PlaneChat")
                        .bitchatFont(size: 34, weight: .bold)
                        .foregroundColor(palette.primary)
                    Text(verbatim: "Private group chat, no signal required.")
                        .bitchatFont(size: 15)
                        .foregroundColor(palette.secondary)
                }

                if bluetoothMonitor.state == .poweredOff || bluetoothMonitor.state == .unauthorized {
                    BluetoothOffBanner(state: bluetoothMonitor.state, palette: palette)
                }

                VStack(spacing: 16) {
                    Button {
                        showCreateRoom = true
                    } label: {
                        Text(verbatim: "Create Room")
                            .bitchatFont(size: 17, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .foregroundColor(.white)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button {
                        showJoinRoom = true
                    } label: {
                        Text(verbatim: "Join Room")
                            .bitchatFont(size: 17, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .foregroundColor(palette.accent)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(palette.accent, lineWidth: 1.5)
                    )
                }
                .padding(.horizontal, 32)

                Spacer()
                Spacer()
            }
        }
        .onAppear { bluetoothMonitor.start() }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView()
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomView()
        }
    }
}

private struct BluetoothOffBanner: View {
    let state: CBManagerState
    let palette: ThemePalette

    var body: some View {
        VStack(spacing: 6) {
            Label {
                Text(verbatim: state == .unauthorized ? "Bluetooth access needed" : "Bluetooth is off")
                    .bitchatFont(size: 14, weight: .medium)
            } icon: {
                Image(systemName: "airplane.circle.fill")
            }
            .foregroundColor(palette.alertRed)

            Text(verbatim: "PlaneChat needs Bluetooth to find nearby room members. Turn it on in Settings or Control Center.")
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(palette.alertRed.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 32)
    }
}

#Preview {
    HomeView()
        .environmentObject(RoomStore())
}
