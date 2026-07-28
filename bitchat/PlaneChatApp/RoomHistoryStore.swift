//
// RoomHistoryStore.swift
// PlaneChatApp
//
// SwiftData-backed message history (SPEC.md "SwiftData + iOS Keychain for
// room key" — this is the SwiftData half; the key itself lives in Keychain,
// see RoomStore.swift). Persists BitchatMessage rows scoped to a roomId so
// history survives relaunch and can be archived or cleared independently
// per room (SPEC.md UX invariant: session end always offers archive-or-clear,
// never silently wipes).
//
// Deliberately flat: one row per message, keyed by (roomId, conversationKey),
// rather than modeling ConversationStore's full Conversation/cap/index
// structure in SwiftData. On restore, rows are replayed through
// ConversationStore's existing `append` intent API, which already knows how
// to rebuild that in-memory structure — persisting it twice would be two
// sources of truth for the same thing.
//

import BitFoundation
import Foundation
import SwiftData

@Model
final class PersistedMessage {
    /// Scopes rows to a room so leaving/clearing one room's history never
    /// touches another's — rooms are otherwise fully independent per SPEC.md.
    var roomId: UUID
    /// Stable string form of ConversationID (see ConversationID+PersistenceKey.swift).
    var conversationKey: String
    var messageID: String
    /// Full BitchatMessage, JSON-encoded — it's already Codable and the
    /// schema is exactly its wire shape, so re-modeling every field as
    /// separate SwiftData properties would just be a lossy second copy.
    var encodedMessage: Data
    var timestamp: Date

    init(roomId: UUID, conversationKey: String, messageID: String, encodedMessage: Data, timestamp: Date) {
        self.roomId = roomId
        self.conversationKey = conversationKey
        self.messageID = messageID
        self.encodedMessage = encodedMessage
        self.timestamp = timestamp
    }
}

@MainActor
final class RoomHistoryStore {
    private let container: ModelContainer

    init(container: ModelContainer = RoomHistoryStore.makeDefaultContainer()) {
        self.container = container
    }

    nonisolated static func makeDefaultContainer() -> ModelContainer {
        // swiftlint:disable:next force_try
        try! ModelContainer(for: PersistedMessage.self)
    }

    func append(_ message: BitchatMessage, conversationKey: String, roomId: UUID) {
        guard let encoded = try? JSONEncoder().encode(message) else { return }
        let row = PersistedMessage(
            roomId: roomId,
            conversationKey: conversationKey,
            messageID: message.id,
            encodedMessage: encoded,
            timestamp: message.timestamp
        )
        container.mainContext.insert(row)
    }

    /// Restores every conversation's messages for `roomId`, oldest first —
    /// callers replay these through `ConversationStore.append`.
    func loadHistory(roomId: UUID) -> [(conversationKey: String, message: BitchatMessage)] {
        let predicate = #Predicate<PersistedMessage> { $0.roomId == roomId }
        let descriptor = FetchDescriptor<PersistedMessage>(predicate: predicate, sortBy: [SortDescriptor(\.timestamp)])
        guard let rows = try? container.mainContext.fetch(descriptor) else { return [] }

        return rows.compactMap { row in
            guard let message = try? JSONDecoder().decode(BitchatMessage.self, from: row.encodedMessage) else { return nil }
            return (row.conversationKey, message)
        }
    }

    /// SPEC.md's "clear" half of archive-or-clear — deletes every row for
    /// this room. "Archive" is simply *not* calling this: history stays on
    /// disk, scoped to a roomId the user will never revisit unless they
    /// rejoin the exact same room.
    func clearHistory(roomId: UUID) {
        let predicate = #Predicate<PersistedMessage> { $0.roomId == roomId }
        guard let rows = try? container.mainContext.fetch(FetchDescriptor<PersistedMessage>(predicate: predicate)) else { return }
        for row in rows {
            container.mainContext.delete(row)
        }
    }
}
