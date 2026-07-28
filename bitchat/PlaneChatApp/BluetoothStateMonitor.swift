//
// BluetoothStateMonitor.swift
// PlaneChatApp
//
// Home needs to detect Bluetooth-off (airplane mode leaves BLE off unless the
// user re-enables it) before any room exists, so before BLEService is ever
// constructed — SPEC.md's "airplane mode onboarding must appear proactively"
// UX invariant applies at the very first screen, not just in the mesh views.
//

import CoreBluetooth
import Foundation

@MainActor
final class BluetoothStateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var state: CBManagerState = .unknown

    private var manager: CBCentralManager?

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        Task { @MainActor in
            self.state = newState
        }
    }
}
