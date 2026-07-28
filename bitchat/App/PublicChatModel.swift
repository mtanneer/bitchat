import BitFoundation
import Combine
import SwiftUI

/// Feature model for the mesh public timeline.
///
/// Observes the mesh `Conversation` object in the single-writer
/// `ConversationStore` so appends to background conversations (private
/// chats) never invalidate it. `messages` reads the observed conversation's
/// backing array directly; there is no mirror copy.
@MainActor
final class PublicChatModel: ObservableObject {
    /// The active public conversation's timeline.
    var messages: [BitchatMessage] { activeConversation.messages }

    private let conversations: ConversationStore
    private var activeConversation: Conversation
    private var activeConversationCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(conversations: ConversationStore) {
        self.conversations = conversations
        self.activeConversation = conversations.conversation(for: .mesh)

        observeActiveConversation()
        bind()
    }

    private func bind() {
        // The store replaces a conversation's object when it is removed
        // (panic clear); retarget to the fresh instance so the observation
        // never goes stale.
        conversations.changes
            .sink { [weak self] change in
                guard let self,
                      case .removed(let id) = change,
                      id == self.activeConversation.id else { return }
                self.retargetActiveConversation()
            }
            .store(in: &cancellables)
    }

    private func retargetActiveConversation() {
        let conversation = conversations.conversation(for: .mesh)
        guard conversation !== activeConversation else {
            // Same object: keep the existing observation, but `messages` may
            // still differ from what views last rendered, so republish.
            objectWillChange.send()
            return
        }
        objectWillChange.send()
        activeConversation = conversation
        observeActiveConversation()
    }

    private func observeActiveConversation() {
        activeConversationCancellable = activeConversation.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}
