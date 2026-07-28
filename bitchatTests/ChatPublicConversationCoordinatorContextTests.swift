//
// ChatPublicConversationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPublicConversationCoordinator` against a mock
// `ChatPublicConversationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: haptics (UIApplication) are not exercised here.
// `checkForMentions` posts through the injected context
// (`notifyMention(from:message:)`) and is covered, as are `sendPublicRaw`
// and all timeline/store/blocking flows.
//

import Testing
import Foundation
import BitFoundation
@testable import PlaneChat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPublicConversationContext` proving that
/// `ChatPublicConversationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPublicConversationContext: ChatPublicConversationContext {
    // Channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    private(set) var isBatchingPublic = false
    private(set) var notifyUIChangedCount = 0

    func setPublicBatching(_ isBatching: Bool) {
        isBatchingPublic = isBatching
    }

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    // Public conversation store (single-writer intents)
    var conversations: [ConversationID: [BitchatMessage]] = [:]

    func publicMessages(in conversationID: ConversationID) -> [BitchatMessage] {
        conversations[conversationID] ?? []
    }

    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        guard conversations[conversationID]?.contains(where: { $0.id == message.id }) != true else {
            return false
        }
        conversations[conversationID, default: []].append(message)
        return true
    }

    func publicConversationContainsMessage(withID messageID: String, in conversationID: ConversationID) -> Bool {
        conversations[conversationID]?.contains(where: { $0.id == messageID }) == true
    }

    @discardableResult
    func removePublicMessage(withID messageID: String) -> BitchatMessage? {
        for (conversationID, timeline) in conversations {
            guard let index = timeline.firstIndex(where: { $0.id == messageID }) else { continue }
            var updated = timeline
            let removed = updated.remove(at: index)
            conversations[conversationID] = updated
            return removed
        }
        return nil
    }

    private(set) var clearedConversations: [ConversationID] = []

    func clearPublicConversation(_ conversationID: ConversationID) {
        clearedConversations.append(conversationID)
        conversations[conversationID] = []
    }

    // Private chats
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var unreadPrivateMessages: Set<PeerID> = []
    private(set) var removedPrivateChats: [PeerID] = []
    private(set) var cleanedUpFileMessageIDs: [String] = []

    func removePrivateChat(_ peerID: PeerID) {
        removedPrivateChats.append(peerID)
        privateChats.removeValue(forKey: peerID)
        unreadPrivateMessages.remove(peerID)
    }

    @discardableResult
    func removePrivateMessage(withID messageID: String) -> BitchatMessage? {
        var removed: BitchatMessage?
        for (peerID, chat) in privateChats {
            guard let message = chat.first(where: { $0.id == messageID }) else { continue }
            removed = removed ?? message
            let remaining = chat.filter { $0.id != messageID }
            if remaining.isEmpty {
                privateChats.removeValue(forKey: peerID)
            } else {
                privateChats[peerID] = remaining
            }
        }
        return removed
    }

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        cleanedUpFileMessageIDs.append(message.id)
    }

    // Mesh transport
    var meshNicknames: [PeerID: String] = [:]
    private(set) var sentMeshMessages: [(content: String, messageID: String)] = []

    func meshPeerNicknames() -> [PeerID: String] {
        meshNicknames
    }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMeshMessages.append((content, messageID))
    }

    // Inbound public message processing
    var blockedMessageIDs: Set<String> = []
    var rateLimitAllowed = true
    private(set) var rateLimitChecks: [(senderKey: String, contentKey: String)] = []
    private(set) var enqueuedMessages: [(messageID: String, conversationID: ConversationID)] = []
    var enqueuedMessageIDs: [String] { enqueuedMessages.map(\.messageID) }
    var stablePeerIDs: [PeerID: PeerID] = [:]

    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        message
    }

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        blockedMessageIDs.contains(message.id)
    }

    func allowPublicMessage(senderKey: String, contentKey: String) -> Bool {
        rateLimitChecks.append((senderKey, contentKey))
        return rateLimitAllowed
    }

    func enqueuePublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) {
        enqueuedMessages.append((message.id, conversationID))
    }

    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? {
        stablePeerIDs[shortPeerID]
    }

    // Content dedup & formatting
    var contentTimestamps: [String: Date] = [:]
    private(set) var recordedContentKeys: [(key: String, timestamp: Date)] = []
    private(set) var prewarmedMessageIDs: [String] = []

    func normalizedContentKey(_ content: String) -> String {
        content.lowercased()
    }

    func contentTimestamp(forKey key: String) -> Date? {
        contentTimestamps[key]
    }

    func recordContentKey(_ key: String, timestamp: Date) {
        recordedContentKeys.append((key, timestamp))
    }

    func prewarmMessageFormatting(_ message: BitchatMessage) {
        prewarmedMessageIDs.append(message.id)
    }

    // Notifications
    private(set) var mentionNotifications: [(sender: String, message: String)] = []

    func notifyMention(from sender: String, message: String) {
        mentionNotifications.append((sender, message))
    }
}

// MARK: - Helpers

@MainActor
private func makePublicMessage(
    id: String = UUID().uuidString,
    sender: String = "alice",
    content: String = "hello world",
    senderPeerID: PeerID? = PeerID(str: "aabbccddeeff0011")
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestamp: Date(),
        isRelay: false,
        isPrivate: false,
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPublicConversationCoordinator` against
/// `MockChatPublicConversationContext` — no `ChatViewModel` involved.
struct ChatPublicConversationCoordinatorContextTests {

    @Test @MainActor
    func handlePublicMessage_meshMessage_enqueuesForBatchedStoreCommit() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let message = makePublicMessage(id: "mesh-msg-1", content: "Hello Mesh")

        coordinator.handlePublicMessage(message)

        // Visible-channel arrival: buffered for the batched pipeline flush
        // (which commits to the store), not appended directly.
        #expect(context.rateLimitChecks.count == 1)
        #expect(context.rateLimitChecks.first?.senderKey == "mesh:aabbccddeeff0011")
        #expect(context.rateLimitChecks.first?.contentKey == "hello mesh")
        #expect(context.enqueuedMessages.map(\.messageID) == ["mesh-msg-1"])
        #expect(context.enqueuedMessages.first?.conversationID == .mesh)
        #expect(context.publicMessages(in: .mesh).isEmpty)

        // Already committed to the store: not re-enqueued.
        context.appendPublicMessage(message, to: .mesh)
        coordinator.handlePublicMessage(message)
        #expect(context.enqueuedMessageIDs == ["mesh-msg-1"])
    }

    @Test @MainActor
    func handlePublicMessage_blockedOrRateLimited_dropsMessage() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        // Blocked sender: dropped before rate limiting and storage.
        context.blockedMessageIDs = ["blocked-msg"]
        coordinator.handlePublicMessage(makePublicMessage(id: "blocked-msg"))
        #expect(context.rateLimitChecks.isEmpty)
        #expect(context.publicMessages(in: .mesh).isEmpty)
        #expect(context.enqueuedMessageIDs.isEmpty)

        // Rate limited: consulted, then dropped before storage.
        context.rateLimitAllowed = false
        coordinator.handlePublicMessage(makePublicMessage(id: "limited-msg"))
        #expect(context.rateLimitChecks.count == 1)
        #expect(context.publicMessages(in: .mesh).isEmpty)
        #expect(context.enqueuedMessageIDs.isEmpty)
    }

    @Test @MainActor
    func removeMessage_removesEverywhereAndCleansUpFile() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let message = makePublicMessage(id: "doomed-msg")
        context.conversations[.mesh] = [message]
        context.privateChats[peerID] = [message]

        coordinator.removeMessage(withID: "doomed-msg", cleanupFile: true)

        #expect(context.publicMessages(in: .mesh).isEmpty)
        #expect(context.privateChats[peerID] == nil)
        #expect(context.cleanedUpFileMessageIDs == ["doomed-msg"])
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func addPublicSystemMessage_appendsToActiveConversationAndRecordsContentKey() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        coordinator.addPublicSystemMessage("Tor Ready")

        #expect(context.publicMessages(in: .mesh).count == 1)
        #expect(context.publicMessages(in: .mesh).first?.sender == "system")
        #expect(context.recordedContentKeys.map(\.key) == ["tor ready"])
    }

    @Test @MainActor
    func sendPublicRaw_onMeshChannel_sendsViaMeshTransport() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        coordinator.sendPublicRaw("raw mesh payload")

        #expect(context.sentMeshMessages.count == 1)
        #expect(context.sentMeshMessages.first?.content == "raw mesh payload")
    }

    @Test @MainActor
    func pipelineDelegate_readsAndWritesContextState() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let pipeline = PublicMessagePipeline()
        let message = makePublicMessage(id: "pipeline-msg")
        context.contentTimestamps["key-1"] = Date(timeIntervalSince1970: 42)

        #expect(coordinator.pipeline(pipeline, normalizeContent: "HeLLo") == "hello")
        #expect(coordinator.pipeline(pipeline, contentTimestampForKey: "key-1") == Date(timeIntervalSince1970: 42))

        // Commit lands in the store via the append intent; a duplicate ID
        // reports `false` (the store's dedup contract).
        #expect(coordinator.pipeline(pipeline, commit: message, to: .mesh))
        #expect(context.publicMessages(in: .mesh).map(\.id) == ["pipeline-msg"])
        #expect(!coordinator.pipeline(pipeline, commit: message, to: .mesh))

        coordinator.pipeline(pipeline, recordContentKey: "key-2", timestamp: Date(timeIntervalSince1970: 7))
        #expect(context.recordedContentKeys.map(\.key) == ["key-2"])

        coordinator.pipelinePrewarmMessage(pipeline, message: message)
        #expect(context.prewarmedMessageIDs == ["pipeline-msg"])

        coordinator.pipelineSetBatchingState(pipeline, isBatching: true)
        #expect(context.isBatchingPublic)
    }

    @Test @MainActor
    func currentPublicSender_derivesMeshIdentity() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        let meshSender = coordinator.currentPublicSender()
        #expect(meshSender.name == "me")
        #expect(meshSender.peerID == context.myPeerID)
    }
    @Test @MainActor
    func checkForMentions_postsMentionNotificationOnlyForOthersMentioningMe() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        // A mention of my nickname from someone else notifies.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-1",
                sender: "alice",
                content: "hey @me",
                timestamp: Date(),
                isRelay: false,
                mentions: ["me"]
            )
        )
        #expect(context.mentionNotifications.count == 1)
        #expect(context.mentionNotifications.first?.sender == "alice")
        #expect(context.mentionNotifications.first?.message == "hey @me")

        // Mentioning someone else does not notify.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-2",
                sender: "alice",
                content: "hey @bob",
                timestamp: Date(),
                isRelay: false,
                mentions: ["bob"]
            )
        )
        #expect(context.mentionNotifications.count == 1)

        // My own message mentioning myself does not notify.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-3",
                sender: "me",
                content: "talking about @me",
                timestamp: Date(),
                isRelay: false,
                mentions: ["me"]
            )
        )
        #expect(context.mentionNotifications.count == 1)
    }

}
