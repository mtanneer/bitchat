import BitFoundation
import Combine
import SwiftUI

struct MeshPeerRow: Identifiable, Equatable {
    let peerID: PeerID
    let displayName: String
    let isMe: Bool
    let hasUnread: Bool
    let isBlocked: Bool
    let isFavorite: Bool
    let isConnected: Bool
    let isReachable: Bool
    let isMutualFavorite: Bool
    let encryptionStatus: EncryptionStatus
    let showsVerifiedBadgeWhenOffline: Bool
    /// Vouched-for by someone I verified, without an explicit verification of
    /// mine — rendered as the unfilled seal (verified gets the filled one).
    let showsVouchedBadge: Bool

    var id: String { peerID.id }
}

struct GroupChatRow: Identifiable, Equatable {
    let peerID: PeerID
    let name: String
    let memberCount: Int
    let isCreator: Bool
    let hasUnread: Bool

    var id: String { peerID.id }
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var allPeers: [BitchatPeer] = []
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var groupRows: [GroupChatRow] = []
    @Published private(set) var reachableMeshPeerCount = 0
    @Published private(set) var connectedMeshPeerCount = 0
    @Published private(set) var renderID = ""

    private let chatViewModel: ChatViewModel
    private let conversations: ConversationStore
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversations: ConversationStore,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversations = conversations
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.allPeers = chatViewModel.allPeers

        bind()
        refresh()
    }

    func colorForMeshPeer(id peerID: PeerID, isDark: Bool) -> Color {
        chatViewModel.colorForMeshPeer(id: peerID, isDark: isDark)
    }

    func startConversation(with peerID: PeerID) {
        chatViewModel.startPrivateChat(with: peerID)
    }

    func toggleFavorite(peerID: PeerID) {
        chatViewModel.toggleFavorite(peerID: peerID)
    }

    private func bind() {
        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.allPeers = peers
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        conversations.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.groupStore.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        let myPeerID = chatViewModel.meshService.myPeerID
        let meshRows = allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let fingerprint = isMe ? nil : chatViewModel.getFingerprint(for: peer.peerID)
            let isVerifiedFingerprint = fingerprint.map { peerIdentityStore.isVerified($0) } ?? false
            let verifiedBadge = !peer.isConnected && isVerifiedFingerprint
            // Vouched is subordinate to verified: never show both seals.
            let vouchedBadge = !isVerifiedFingerprint
                && (fingerprint.map { chatViewModel.isVouchedFingerprint($0) } ?? false)

            return MeshPeerRow(
                peerID: peer.peerID,
                displayName: isMe ? chatViewModel.nickname : peer.nickname,
                isMe: isMe,
                hasUnread: chatViewModel.hasUnreadMessages(for: peer.peerID),
                isBlocked: !isMe && chatViewModel.isPeerBlocked(peer.peerID),
                isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                isConnected: peer.isConnected,
                isReachable: peer.isReachable,
                isMutualFavorite: peer.isMutualFavorite,
                encryptionStatus: chatViewModel.getEncryptionStatus(for: peer.peerID),
                showsVerifiedBadgeWhenOffline: verifiedBadge,
                showsVouchedBadge: vouchedBadge
            )
        }

        let meshCounts = meshRows.reduce(into: (reachable: 0, connected: 0)) { counts, row in
            guard !row.isMe else { return }
            if row.isConnected {
                counts.connected += 1
                counts.reachable += 1
            } else if row.isReachable {
                counts.reachable += 1
            }
        }

        let groupRows = buildGroupRows()

        self.meshRows = meshRows
        reachableMeshPeerCount = meshCounts.reachable
        connectedMeshPeerCount = meshCounts.connected
        self.groupRows = groupRows
        renderID = (
            meshRows.map {
                "\($0.id)-\($0.isConnected)-\($0.isReachable)-\($0.hasUnread)-\($0.isFavorite)-\($0.isBlocked)"
            } +
            groupRows.map {
                "group:\($0.id)-\($0.name)-\($0.memberCount)-\($0.hasUnread)"
            }
        ).joined(separator: "|")
    }

    private func buildGroupRows() -> [GroupChatRow] {
        let myFingerprint = chatViewModel.meshService.noiseIdentityFingerprint()
        return chatViewModel.groupStore.groups.map { group in
            GroupChatRow(
                peerID: group.peerID,
                name: group.name,
                memberCount: group.members.count,
                isCreator: group.creatorFingerprint == myFingerprint,
                hasUnread: chatViewModel.hasUnreadMessages(for: group.peerID)
            )
        }
    }
}
