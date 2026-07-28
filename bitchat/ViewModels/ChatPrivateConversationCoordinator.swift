import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatPrivateConversationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPrivateConversationCoordinatorContextTests`) and makes
/// its true dependencies explicit. The surface is intentionally large — it
/// documents the coordinator's real coupling to private-chat state, peer
/// identity, and the routing/ack transports.
@MainActor
protocol ChatPrivateConversationContext: AnyObject {
    // MARK: Conversation state
    var privateChats: [PeerID: [BitchatMessage]] { get }
    /// A single private chat's timeline. Witnessed by the store-direct
    /// lookup on `ChatViewModel` (no `privateChats` dictionary build).
    func privateMessages(for peerID: PeerID) -> [BitchatMessage]
    var sentReadReceipts: Set<String> { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var nickname: String { get }

    // MARK: Conversation store intents
    // The sole mutation paths for private message state (single-writer
    // `ConversationStore` ops; see docs/CONVERSATION-STORE-DESIGN.md).
    /// Appends a private message in timestamp order; returns `false` on
    /// duplicate message ID.
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool
    /// Replace-or-append a private message by ID, keeping its position.
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID)
    /// Applies a delivery status by message ID; returns `false` when the
    /// message is unknown or the update would downgrade the status.
    @discardableResult
    func setPrivateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, peerID: PeerID) -> Bool
    func markPrivateChatUnread(_ peerID: PeerID)
    func markPrivateChatRead(_ peerID: PeerID)
    /// Moves all messages from `oldPeerID`'s chat into `newPeerID`'s chat
    /// (dedup by ID, order preserved, unread carried, old chat removed).
    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID)
    /// `true` when any private chat contains a message with `messageID`.
    func privateChatsContainMessage(withID messageID: String) -> Bool
    /// `true` when `peerID`'s chat contains a message with `messageID`.
    func privateChat(_ peerID: PeerID, containsMessageWithID messageID: String) -> Bool

    /// Records that a read receipt is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool
    /// Moves the open private chat to `newPeerID` when the current selection is
    /// one of the peer IDs being migrated away.
    func handOffSelectedPrivateChat(from oldPeerIDs: [PeerID], to newPeerID: PeerID)
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Peers & identity
    var myPeerID: PeerID { get }
    func peerNickname(for peerID: PeerID) -> String?
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    func isPeerBlocked(_ peerID: PeerID) -> Bool
    func noisePublicKey(for peerID: PeerID) -> Data?
    /// Resolves the ephemeral (short) peer ID for a known Noise public key, if connected.
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID?
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getFingerprint(for peerID: PeerID) -> String?
    func storedFingerprint(for peerID: PeerID) -> String?
    func clearStoredFingerprint(for peerID: PeerID)

    // MARK: Routing & acknowledgements
    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String)
    @discardableResult
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool
    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)

    // MARK: System messages
    func addMeshOnlySystemMessage(_ content: String)
    /// Appends a local-only system line into a specific private thread —
    /// errors about a DM belong in that DM, not on the active timeline.
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID)

    // MARK: Favorites & notifications
    /// The persisted favorite relationship for the peer's Noise static key, if any.
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship?
    /// The persisted favorite relationship resolved from a short 16-hex mesh
    /// peer ID (matched against the IDs derived from stored noise keys).
    func favoriteRelationship(forPeerID peerID: PeerID) -> FavoritesPersistenceService.FavoriteRelationship?
    /// Persists that the peer favorited/unfavorited us (favorites store write).
    func updatePeerFavoritedUs(noiseKey: Data, favorited: Bool, nickname: String)
    /// Posts the incoming-private-message local notification.
    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID)
}

extension ChatViewModel: ChatPrivateConversationContext {
    // `privateChats` and `notifyUIChanged()` are shared requirements with
    // `ChatDeliveryContext`; the single-writer intent ops (`markReadReceiptSent`,
    // `handOffSelectedPrivateChat`) live next to their
    // backing state in `ChatViewModel`. The remaining state members are
    // satisfied by existing `ChatViewModel` properties and methods.

    var myPeerID: PeerID { meshService.myPeerID }

    func peerNickname(for peerID: PeerID) -> String? {
        meshService.peerNickname(peerID: peerID)
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        meshService.isPeerConnected(peerID)
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        meshService.isPeerReachable(peerID)
    }

    func noisePublicKey(for peerID: PeerID) -> Data? {
        unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
    }

    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID? {
        unifiedPeerService.peers.first(where: { $0.noisePublicKey == noiseKey })?.peerID
    }

    func storedFingerprint(for peerID: PeerID) -> String? {
        peerIDToPublicKeyFingerprint[peerID]
    }

    func clearStoredFingerprint(for peerID: PeerID) {
        peerIdentityStore.setFingerprint(nil, for: peerID)
    }

    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        messageRouter.sendPrivate(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
    }

    @discardableResult
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool {
        messageRouter.sendReadReceipt(receipt, to: peerID)
    }

    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        meshService.sendReadReceipt(receipt, to: peerID)
    }

    func addSystemMessage(_ content: String) {
        addSystemMessage(content, timestamp: Date())
    }

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
    }

    // `favoriteRelationship(forPeerID:)` is shared with
    // `ChatPeerIdentityContext`; its witness lives in
    // `ChatPeerIdentityCoordinator.swift`.

    func updatePeerFavoritedUs(noiseKey: Data, favorited: Bool, nickname: String) {
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: noiseKey,
            favorited: favorited,
            peerNickname: nickname
        )
    }

    func notifyPrivateMessage(from senderName: String, message: String, peerID: PeerID) {
        NotificationService.shared.sendPrivateMessageNotification(from: senderName, message: message, peerID: peerID)
    }
}

@MainActor
final class ChatPrivateConversationCoordinator {
    private unowned let context: any ChatPrivateConversationContext

    init(context: any ChatPrivateConversationContext) {
        self.context = context
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        guard !content.isEmpty else { return }

        if context.isPeerBlocked(peerID) {
            let nickname = context.peerNickname(for: peerID) ?? "anon"
            context.addLocalPrivateSystemMessage(
                String(
                    format: String(localized: "system.dm.blocked_recipient", comment: "System message when attempting to message a blocked person"),
                    locale: .current,
                    nickname
                ),
                to: peerID
            )
            return
        }

        // Resolve the favorite behind this conversation. It may be keyed by
        // the full 64-hex noise-key ID (offline favorite row) or the short
        // 16-hex mesh ID — the raw hex bytes of a short ID are a routing ID,
        // never a noise key, so they must not be used as a favorites key.
        let noiseKey = peerID.noiseKey ?? context.noisePublicKey(for: peerID)
        let isConnected = context.isPeerConnected(peerID)
        let isReachable = context.isPeerReachable(peerID)
        let favoriteStatus = noiseKey.flatMap { context.favoriteRelationship(forNoiseKey: $0) }
            ?? context.favoriteRelationship(forPeerID: peerID)
        let isMutualFavorite = favoriteStatus?.isMutual ?? false

        // "anon" matches the app's default-nickname convention; "user" is
        // banned copy.
        let recipientNickname = context.peerNickname(for: peerID)
            ?? favoriteStatus?.peerNickname
            ?? "anon"

        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: context.nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: context.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )

        context.appendPrivateMessage(message, to: peerID)
        context.notifyUIChanged()

        // Always hand the message to the router — it owns delivery. A live
        // link sends now; an unreachable peer gets the retained-outbox path
        // (resend on reconnect, courier deposits). Pre-judging
        // reachability here used to mark the message failed without ever
        // routing it, silently bypassing all of that (field-found: DMs
        // composed after a peer's reachability window lapsed were dead on
        // arrival while identical DMs sent a minute earlier delivered).
        context.routePrivateMessage(
            content,
            to: peerID,
            recipientNickname: recipientNickname,
            messageID: messageID
        )
        if isConnected || isReachable || isMutualFavorite {
            context.setPrivateDeliveryStatus(.sent, forMessageID: messageID, peerID: peerID)
        }
        // Otherwise the message stays "sending"; router callbacks move it to
        // carried (📦) when a courier copy ships, delivered/read on
        // acks, or failed when the outbox TTL expires.
    }

    func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.debug("📥 handlePrivateMessage called for message from \(message.sender)", category: .session)
        let senderPeerID = message.senderPeerID ?? context.getPeerIDForNickname(message.sender)

        guard let peerID = senderPeerID else {
            SecureLogger.warning("⚠️ Could not get peer ID for sender \(message.sender)", category: .session)
            return
        }

        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            handleFavoriteNotification(message.content, from: peerID, senderNickname: message.sender)
            return
        }

        migratePrivateChatsIfNeeded(for: peerID, senderNickname: message.sender)

        if isDuplicateMessage(message.id, targetPeerID: peerID) {
            return
        }

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: peerID)
        let noiseKey = peerID.noiseKey ?? context.noisePublicKey(for: peerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: peerID, key: noiseKey)

        let isViewing = context.selectedPrivateChatPeer == peerID
        if isViewing {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: context.myPeerID,
                readerNickname: context.nickname
            )
            context.sendMeshReadReceipt(receipt, to: peerID)
            context.markReadReceiptSent(message.id)
        } else {
            context.markPrivateChatUnread(peerID)
            context.notifyPrivateMessage(from: message.sender, message: message.content, peerID: peerID)
        }

        context.notifyUIChanged()
    }

    /// O(1)-per-conversation dedup via the store's message-ID indexes
    /// (replaces the full scan over every private chat).
    func isDuplicateMessage(_ messageId: String, targetPeerID _: PeerID) -> Bool {
        context.privateChatsContainMessage(withID: messageId)
    }

    func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID) {
        // Store upsert replaces in place by message ID or inserts in
        // timestamp order; the old per-append sanitize re-sort is obsolete.
        context.upsertPrivateMessage(message, in: targetPeerID)
    }

    func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?) {
        guard let key,
              let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key),
              ephemeralPeerID != targetPeerID
        else {
            return
        }

        context.upsertPrivateMessage(message, in: ephemeralPeerID)
    }

    func handleViewingThisChat(
        _ message: BitchatMessage,
        targetPeerID: PeerID,
        key: Data?
    ) {
        context.markPrivateChatRead(targetPeerID)
        if let key,
           let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key) {
            context.markPrivateChatRead(ephemeralPeerID)
        }
        guard !context.sentReadReceipts.contains(message.id) else { return }

        if let key {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: context.myPeerID,
                readerNickname: context.nickname
            )
            SecureLogger.debug("Viewing chat; sending READ ack for \(message.id.prefix(8))… via router", category: .session)
            context.routeReadReceipt(receipt, to: PeerID(hexData: key))
            context.markReadReceiptSent(message.id)
        }
    }

    func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: PeerID,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String
    ) {
        guard shouldMarkAsUnread else { return }

        context.markPrivateChatUnread(targetPeerID)
        if let key,
           let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key),
           ephemeralPeerID != targetPeerID {
            context.markPrivateChatUnread(ephemeralPeerID)
        }
        if isRecentMessage {
            context.notifyPrivateMessage(from: senderNickname, message: messageContent, peerID: targetPeerID)
        }
    }

    /// Applies an inbound `[FAVORITED]`/`[UNFAVORITED]` marker. `peerID` must
    /// resolve to a noise key — a full 64-hex ID or one the unified peer list
    /// knows; otherwise the notification is dropped.
    func handleFavoriteNotification(_ content: String, from peerID: PeerID, senderNickname: String) {
        let isFavorite = content.hasPrefix("[FAVORITED]")

        let noiseKey = peerID.noiseKey ?? context.noisePublicKey(for: peerID)
        guard let finalNoiseKey = noiseKey else {
            SecureLogger.warning("⚠️ Cannot get Noise key for peer \(peerID)", category: .session)
            return
        }

        let prior = context.favoriteRelationship(forNoiseKey: finalNoiseKey)?.theyFavoritedUs ?? false
        context.updatePeerFavoritedUs(
            noiseKey: finalNoiseKey,
            favorited: isFavorite,
            nickname: senderNickname
        )

        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            context.addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
    }

    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ")
            && message.content.hasSuffix(" *")
            && (message.content.contains("🫂")
                || message.content.contains("🐟")
                || message.content.contains("took a screenshot"))

        guard isActionMessage else { return message }

        return BitchatMessage(
            id: message.id,
            sender: "system",
            content: String(message.content.dropFirst(2).dropLast(2)),
            timestamp: message.timestamp,
            isRelay: message.isRelay,
            originalSender: message.originalSender,
            isPrivate: message.isPrivate,
            recipientNickname: message.recipientNickname,
            senderPeerID: message.senderPeerID,
            mentions: message.mentions,
            deliveryStatus: message.deliveryStatus
        )
    }

    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        let currentFingerprint = context.getFingerprint(for: peerID)

        if context.privateMessages(for: peerID).isEmpty {
            // Chats migrated wholesale go through the store's
            // `migrateConversation` intent; partially-migrated chats keep
            // their non-recent tail, so the recent messages are copied in
            // via ordered append (dedup by ID) instead.
            var partiallyMigratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [PeerID] = []
            var didMigrate = false
            let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)

            for (oldPeerID, messages) in context.privateChats where oldPeerID != peerID {
                let oldFingerprint = context.storedFingerprint(for: oldPeerID)
                let recentMessages = messages.filter { $0.timestamp > cutoffTime }
                guard !recentMessages.isEmpty else { continue }

                if let currentFp = currentFingerprint,
                   let oldFp = oldFingerprint,
                   currentFp == oldFp {
                    didMigrate = true
                    if recentMessages.count == messages.count {
                        oldPeerIDsToRemove.append(oldPeerID)
                    } else {
                        partiallyMigratedMessages.append(contentsOf: recentMessages)
                        SecureLogger.info(
                            "📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)",
                            category: .session
                        )
                    }

                    SecureLogger.info(
                        "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)",
                        category: .session
                    )
                } else if currentFingerprint == nil || oldFingerprint == nil {
                    let isRelevantChat = recentMessages.contains { msg in
                        (msg.sender == senderNickname && msg.sender != context.nickname)
                            || (msg.sender == context.nickname && msg.recipientNickname == senderNickname)
                    }

                    if isRelevantChat {
                        didMigrate = true
                        if recentMessages.count == messages.count {
                            oldPeerIDsToRemove.append(oldPeerID)
                        } else {
                            partiallyMigratedMessages.append(contentsOf: recentMessages)
                        }

                        SecureLogger.warning(
                            "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)",
                            category: .session
                        )
                    }
                }
            }

            if !oldPeerIDsToRemove.isEmpty {
                for oldID in oldPeerIDsToRemove {
                    // The old behavior dropped the unread flag of removed
                    // chats instead of transferring it; clear it before the
                    // migration so the store doesn't carry it over.
                    context.markPrivateChatRead(oldID)
                    context.migratePrivateChat(from: oldID, to: peerID)
                    context.clearStoredFingerprint(for: oldID)
                }

                context.handOffSelectedPrivateChat(from: oldPeerIDsToRemove, to: peerID)
            }

            for message in partiallyMigratedMessages {
                context.appendPrivateMessage(message, to: peerID)
            }

            if didMigrate {
                context.notifyUIChanged()
            }
        }
    }

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID ?? context.getPeerIDForNickname(message.sender) {
            if context.isPeerBlocked(peerID) { return true }
        }
        return false
    }
}

/// Default for conforming test contexts that model chats as a dictionary;
/// `ChatViewModel` overrides with a store-direct lookup.
extension ChatPrivateConversationContext {
    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }
}
