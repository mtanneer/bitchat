//
// RoomHistoryBridge.swift
// PlaneChatApp
//
// Connects ConversationStore (bitchat's existing in-memory message state) to
// RoomHistoryStore (SwiftData) without touching ConversationStore itself:
// subscribes to its existing `changes` publisher and persists `.appended`
// events, keeping SwiftData a bolt-on rather than entangling core mesh/chat
// code with PlaneChat's persistence choice.
//

import Combine
import Foundation

@MainActor
final class RoomHistoryBridge {
    private let history: RoomHistoryStore
    private let roomId: UUID
    private var cancellable: AnyCancellable?

    init(conversations: ConversationStore, history: RoomHistoryStore, roomId: UUID) {
        self.history = history
        self.roomId = roomId

        cancellable = conversations.changes.sink { [weak self] change in
            guard let self, case .appended(let conversationID, let message) = change else { return }
            self.history.append(message, conversationKey: conversationID.persistenceKey, roomId: self.roomId)
        }

        restoreHistory(into: conversations)
    }

    private func restoreHistory(into conversations: ConversationStore) {
        for (conversationKey, message) in history.loadHistory(roomId: roomId) {
            guard let conversationID = ConversationID(persistenceKey: conversationKey) else { continue }
            conversations.append(message, to: conversationID)
        }
    }
}
