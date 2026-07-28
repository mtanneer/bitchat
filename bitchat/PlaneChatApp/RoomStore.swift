//
// RoomStore.swift
// PlaneChatApp
//
// Gates the app's root view: bitchat's ContentView (and the AppRuntime/mesh
// underneath it) must not exist until a room is chosen, since BLEService's
// service UUID is scoped to `roomId` at construction time (see BLEService.swift
// init). Home owns this store; Create/Join Room screens populate it.
//
// Persistence (Step 7 / SPEC.md "SwiftData + iOS Keychain for room key"): the
// room's Noise static key is secret material, so it lives in Keychain, not
// SwiftData — reusing bitchat's existing generic save/load(key:service:) API
// rather than the identity-key-specific calls (those are scoped to bitchat's
// own mesh identity, a different key).
//

import BitFoundation
import CryptoKit
import Foundation

/// One device's local view of the room it's currently in.
struct ActiveRoomSession {
    let roomId: UUID
    let staticKey: Curve25519.KeyAgreement.PrivateKey
    let roomName: String
}

/// Codable mirror of ActiveRoomSession for Keychain storage — the private
/// key type itself isn't Codable, so it round-trips via rawRepresentation.
private struct PersistedRoomSession: Codable {
    let roomId: UUID
    let staticKeyRaw: Data
    let roomName: String
}

@MainActor
final class RoomStore: ObservableObject {
    private static let keychainService = "chat.planechat.room-session"
    private static let keychainKey = "active-room-session"

    @Published private(set) var activeSession: ActiveRoomSession?

    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
        self.activeSession = Self.loadPersisted(keychain: keychain)
    }

    func setActiveSession(_ session: ActiveRoomSession) {
        activeSession = session
        persist(session)
    }

    /// SPEC.md UX invariant: session end must always offer archive-or-clear,
    /// never silently wipe. This type only owns the Keychain-held session —
    /// whether to also clear the room's SwiftData history is the caller's
    /// call (LeaveRoomControl), made via RoomHistoryStore before calling this.
    func leaveRoom() {
        activeSession = nil
        keychain.delete(key: Self.keychainKey, service: Self.keychainService)
    }

    private func persist(_ session: ActiveRoomSession) {
        let persisted = PersistedRoomSession(
            roomId: session.roomId,
            staticKeyRaw: session.staticKey.rawRepresentation,
            roomName: session.roomName
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        keychain.save(key: Self.keychainKey, data: data, service: Self.keychainService, accessible: nil)
    }

    private static func loadPersisted(keychain: KeychainManagerProtocol) -> ActiveRoomSession? {
        guard let data = keychain.load(key: keychainKey, service: keychainService),
              let persisted = try? JSONDecoder().decode(PersistedRoomSession.self, from: data),
              let staticKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: persisted.staticKeyRaw)
        else { return nil }

        return ActiveRoomSession(roomId: persisted.roomId, staticKey: staticKey, roomName: persisted.roomName)
    }
}
