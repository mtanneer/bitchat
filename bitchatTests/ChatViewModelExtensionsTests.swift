//
// ChatViewModelExtensionsTests.swift
// bitchatTests
//
// Tests for ChatViewModel extensions (PrivateChat, Nostr, Tor).
//

import Testing
import Foundation
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import BitFoundation
@testable import PlaneChat

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Private Chat Extension Tests

struct ChatViewModelPrivateChatExtensionTests {

    @Test @MainActor
    func sendPrivateMessage_mesh_storesAndSends() async {
        let (viewModel, transport) = makeTestableViewModel()
        // Use valid hex string for PeerID (32 bytes = 64 hex chars for Noise key usually, or just valid hex)
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)
        
        // Simulate connection
        transport.connectedPeers.insert(peerID)
        transport.peerNicknames[peerID] = "MeshUser"
        
        viewModel.sendPrivateMessage("Hello Mesh", to: peerID)
        
        // Verify transport was called
        // Note: MockTransport stores sent messages
        // Since sendPrivateMessage delegates to MessageRouter which delegates to Transport...
        // We need to ensure MessageRouter is using our MockTransport.
        // ChatViewModel init sets up MessageRouter with the passed transport.
        
        // Wait for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify message stored locally
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Hello Mesh")
        
        // Verify message sent to transport (MockTransport captures sendPrivateMessage)
        // MockTransport.sendPrivateMessage is what MessageRouter calls for connected peers
        // Check MockTransport implementation... it might need update or verification
    }

    /// An unreachable recipient no longer means instant failure: the message
    /// is routed anyway so the router's outbox/courier/bridge machinery can
    /// deliver it, and it stays "sending" until a router callback resolves it.
    @Test @MainActor
    func sendPrivateMessage_unreachable_staysSendingForStoreAndForward() async {
        let (viewModel, _) = makeTestableViewModel()
        let validHex = "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10"
        let peerID = PeerID(str: validHex)

        viewModel.sendPrivateMessage("Hello", to: peerID)

        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.last?.deliveryStatus == .sending)
    }
    
    @Test @MainActor
    func handlePrivateMessage_storesMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Private Content",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "Me",
            senderPeerID: peerID
        )
        
        // Simulate receiving a private message via the handlePrivateMessage extension method
        viewModel.handlePrivateMessage(message)
        
        // Verify stored
        #expect(viewModel.privateChats[peerID]?.count == 1)
        #expect(viewModel.privateChats[peerID]?.first?.content == "Private Content")
        
        // Verify notification trigger (unread count should increase if not viewing)
        #expect(viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func handlePrivateMessage_deduplicates() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        viewModel.handlePrivateMessage(message) // Duplicate
        
        #expect(viewModel.privateChats[peerID]?.count == 1)
    }
    
    @Test @MainActor
    func handlePrivateMessage_sendsReadReceipt_whenViewing() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "SENDER_001")
        
        // Set as currently viewing
        viewModel.selectedPrivateChatPeer = peerID
        
        let message = BitchatMessage(
            id: "msg-1",
            sender: "Sender",
            content: "Content",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: peerID
        )
        
        viewModel.handlePrivateMessage(message)
        
        // Should NOT be marked unread
        #expect(!viewModel.unreadPrivateMessages.contains(peerID))
    }
    
    @Test @MainActor
    func migratePrivateChats_consolidatesHistory_onFingerprintMatch() async {
        let (viewModel, _) = makeTestableViewModel()
        let oldPeerID = PeerID(str: "OLD_PEER")
        let newPeerID = PeerID(str: "NEW_PEER")
        let fingerprint = "fp_123"
        
        // Setup old chat
        let oldMessage = BitchatMessage(
            id: "msg-old",
            sender: "User",
            content: "Old message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: oldPeerID
        )
        viewModel.seedPrivateChat([oldMessage], for: oldPeerID)
        viewModel.peerIDToPublicKeyFingerprint[oldPeerID] = fingerprint
        
        // Setup new peer fingerprint
        viewModel.peerIDToPublicKeyFingerprint[newPeerID] = fingerprint
        
        // Trigger migration
        viewModel.migratePrivateChatsIfNeeded(for: newPeerID, senderNickname: "User")
        
        // Verify migration
        #expect(viewModel.privateChats[newPeerID]?.count == 1)
        #expect(viewModel.privateChats[newPeerID]?.first?.content == "Old message")
        #expect(viewModel.privateChats[oldPeerID] == nil) // Old chat removed
    }
}
// MARK: - Single-Writer Intent Operation Tests

/// Contracts for the owner-side intent ops that are the sole mutation paths
/// for `ChatViewModel`'s shared coordinator state (`nostrKeyMapping`,
/// `sentReadReceipts`, `sentGeoDeliveryAcks`, `isBatchingPublic`, the geo
/// subscription IDs, and the selected private chat hand-off).
struct ChatViewModelIntentOperationTests {

    @Test @MainActor
    func markReadReceiptSent_returnsFalseOnSecondCall() async {
        let (viewModel, _) = makeTestableViewModel()

        #expect(viewModel.markReadReceiptSent("read-1"))
        #expect(!viewModel.markReadReceiptSent("read-1"))
        #expect(viewModel.sentReadReceipts.contains("read-1"))
    }

    @Test @MainActor
    func pruneSentReadReceipts_dropsStaleIDsAndReturnsRemovedCount() async {
        let (viewModel, _) = makeTestableViewModel()
        viewModel.sentReadReceipts = ["keep-1", "keep-2", "drop-1", "drop-2"]

        let removed = viewModel.pruneSentReadReceipts(keeping: ["keep-1", "keep-2", "unrelated"])

        #expect(removed == 2)
        #expect(viewModel.sentReadReceipts == ["keep-1", "keep-2"])
        // Nothing stale left: a second prune removes nothing.
        #expect(viewModel.pruneSentReadReceipts(keeping: ["keep-1", "keep-2"]) == 0)
    }

    @Test @MainActor
    func setPublicBatching_publishesBatchingState() async {
        let (viewModel, _) = makeTestableViewModel()

        #expect(!viewModel.isBatchingPublic)
        viewModel.setPublicBatching(true)
        #expect(viewModel.isBatchingPublic)
        viewModel.setPublicBatching(false)
        #expect(!viewModel.isBatchingPublic)
    }

    @Test @MainActor
    func handOffSelectedPrivateChat_movesSelectionOnlyWhenSelectedPeerIsMigrated() async {
        let (viewModel, _) = makeTestableViewModel()
        let oldPeer = PeerID(str: "aaaaaaaaaaaaaaaa")
        let unrelatedPeer = PeerID(str: "cccccccccccccccc")
        let newPeer = PeerID(str: "bbbbbbbbbbbbbbbb")

        // Selection not among the migrated peers: untouched.
        viewModel.selectedPrivateChatPeer = unrelatedPeer
        viewModel.handOffSelectedPrivateChat(from: [oldPeer], to: newPeer)
        #expect(viewModel.selectedPrivateChatPeer == unrelatedPeer)

        // Selection being migrated away: handed off to the new peer.
        viewModel.selectedPrivateChatPeer = oldPeer
        viewModel.handOffSelectedPrivateChat(from: [oldPeer], to: newPeer)
        #expect(viewModel.selectedPrivateChatPeer == newPeer)
    }
}

@Suite(.serialized)
struct ChatViewModelMediaTransferTests {

    @Test @MainActor
    func handleTransferEvent_updatesPrivateMessageProgressAndClearsMappingOnCompletion() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708090a0b0c0d0e0f100102030405060708090a0b0c0d0e0f10")
        let message = viewModel.enqueueMediaMessage(content: "[voice] clip.m4a", targetPeer: peerID)
        let transferID = "transfer-1"

        viewModel.registerTransfer(transferId: transferID, messageID: message.id)
        viewModel.handleTransferEvent(.started(id: transferID, totalFragments: 4))
        #expect(isPartiallyDelivered(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id), reached: 0, total: 4))

        viewModel.handleTransferEvent(.updated(id: transferID, sentFragments: 2, totalFragments: 4))
        #expect(isPartiallyDelivered(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id), reached: 2, total: 4))

        viewModel.handleTransferEvent(.completed(id: transferID, totalFragments: 4))
        #expect(isSent(status: deliveryStatus(in: viewModel, peerID: peerID, messageID: message.id)))
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
        #expect(viewModel.transferIdToMessageIDs[transferID] == nil)
    }

    @Test @MainActor
    func handleTransferEvent_cancelledRemovesOutgoingMessage() async {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "1111111111111111111111111111111111111111111111111111111111111111")
        let message = viewModel.enqueueMediaMessage(content: "[image] pic.jpg", targetPeer: peerID)
        let transferID = "transfer-2"

        viewModel.registerTransfer(transferId: transferID, messageID: message.id)
        viewModel.handleTransferEvent(.cancelled(id: transferID, sentFragments: 1, totalFragments: 3))

        #expect(viewModel.privateChats[peerID]?.contains(where: { $0.id == message.id }) != true)
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
    }

    @Test @MainActor
    func sendVoiceNote_outsideAllowedContextDeletesTempFile() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")

        try Data("voice".utf8).write(to: url)
        // Media transfer isn't wired for group conversations, so selecting a
        // group peer is the current "disallowed context" for media sends.
        viewModel.selectedPrivateChatPeer = PeerID(groupID: Data(repeating: 0xAA, count: 16))

        viewModel.sendVoiceNote(at: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(viewModel.messages.contains(where: { $0.sender == "system" }))
    }

    @Test @MainActor
    func sendImage_outsideAllowedContextRunsCleanup() async {
        let (viewModel, _) = makeTestableViewModel()
        var cleanupCalled = false

        viewModel.selectedPrivateChatPeer = PeerID(groupID: Data(repeating: 0xBB, count: 16))
        viewModel.sendImage(from: URL(fileURLWithPath: "/tmp/ignored.jpg")) {
            cleanupCalled = true
        }

        #expect(cleanupCalled)
        #expect(viewModel.messages.contains(where: { $0.sender == "system" }))
    }

    @Test @MainActor
    func sendVoiceNote_privateChatUsesPrivateFileTransfer() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "2222222222222222222222222222222222222222222222222222222222222222")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("voice payload".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendVoiceNote(at: url)

        // Media sends hop through Task.detached; the global executor is
        // shared with every parallel test worker, so a loaded runner can
        // exceed the 5s default. waitUntil returns as soon as the condition
        // holds, so passing runs never pay the longer timeout.
        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: TestConstants.longTimeout)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.first?.peerID == peerID)
        #expect(viewModel.privateChats[peerID]?.last?.content.contains("[voice]") == true)
        #expect(viewModel.messageIDToTransferId.count == 1)
        #expect(viewModel.transferIdToMessageIDs.count == 1)
    }

    @Test @MainActor
    func sendVoiceNote_oversizedFileFailsAndDeletesTempFile() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "3333333333333333333333333333333333333333333333333333333333333333")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-too-large-\(UUID().uuidString).m4a")
        try Data(repeating: 0x55, count: FileTransferLimits.maxVoiceNoteBytes + 1).write(to: url, options: .atomic)

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendVoiceNote(at: url)

        let didFail = await TestHelpers.waitUntil({
            isFailed(status: viewModel.privateChats[peerID]?.last?.deliveryStatus)
        }, timeout: TestConstants.longTimeout)
        #expect(didFail)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(transport.sentPrivateFiles.isEmpty)
    }

    @Test @MainActor
    func sendImage_privateChatProcessesAndTransfersImage() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "4444444444444444444444444444444444444444444444444444444444444444")
        let sourceURL = try makeTemporaryImageURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendImage(from: sourceURL)

        let didSend = await TestHelpers.waitUntil({ transport.sentPrivateFiles.count == 1 }, timeout: TestConstants.longTimeout)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.first?.peerID == peerID)
        #expect(transport.sentPrivateFiles.first?.packet.mimeType == "image/jpeg")
        #expect(viewModel.privateChats[peerID]?.last?.content.contains("[image]") == true)
        #expect(viewModel.messageIDToTransferId.count == 1)
    }

    @Test @MainActor
    func sendImage_invalidSourceAddsFailureSystemMessage() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "5555555555555555555555555555555555555555555555555555555555555555")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).jpg")
        try Data("not-an-image".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.selectedPrivateChatPeer = peerID
        viewModel.sendImage(from: url)

        let didNotify = await TestHelpers.waitUntil({
            viewModel.messages.contains(where: { $0.sender == "system" && $0.content.contains("Failed to prepare image") })
        }, timeout: TestConstants.longTimeout)
        #expect(didNotify)
        #expect(transport.sentPrivateFiles.isEmpty)
        #expect(viewModel.privateChats[peerID]?.isEmpty != false)
    }

    @Test @MainActor
    func clearTransferMapping_promotesQueuedTransferForSameID() async {
        let (viewModel, _) = makeTestableViewModel()
        viewModel.registerTransfer(transferId: "transfer-queue", messageID: "first")
        viewModel.registerTransfer(transferId: "transfer-queue", messageID: "second")

        viewModel.clearTransferMapping(for: "first")

        #expect(viewModel.messageIDToTransferId["first"] == nil)
        #expect(viewModel.transferIdToMessageIDs["transfer-queue"] == ["second"])
        #expect(viewModel.messageIDToTransferId["second"] == "transfer-queue")
    }

    @Test @MainActor
    func cancelMediaSend_cancelsActiveTransferRemovesMessageAndDeletesFile() async throws {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "6666666666666666666666666666666666666666666666666666666666666666")
        let fileName = "cancel-\(UUID().uuidString).m4a"
        let fileURL = try mediaFileURL(subdirectory: "voicenotes/outgoing", fileName: fileName)
        try Data("cancel me".utf8).write(to: fileURL, options: .atomic)

        let message = BitchatMessage(
            id: "cancel-msg",
            sender: viewModel.nickname,
            content: "[voice] \(fileName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sending
        )
        viewModel.seedPrivateChat([message], for: peerID)
        viewModel.registerTransfer(transferId: "transfer-cancel", messageID: message.id)

        viewModel.cancelMediaSend(messageID: message.id)

        #expect(transport.cancelledTransfers == ["transfer-cancel"])
        #expect(viewModel.privateChats[peerID] == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func deleteMediaMessage_removesStoredMessageAndCleansImageFile() async throws {
        let (viewModel, _) = makeTestableViewModel()
        let peerID = PeerID(str: "7777777777777777777777777777777777777777777777777777777777777777")
        let fileName = "delete-\(UUID().uuidString).jpg"
        let fileURL = try mediaFileURL(subdirectory: "images/outgoing", fileName: fileName)
        try Data("image bytes".utf8).write(to: fileURL, options: .atomic)

        let message = BitchatMessage(
            id: "delete-msg",
            sender: viewModel.nickname,
            content: "[image] \(fileName)",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.seedPrivateChat([message], for: peerID)
        viewModel.registerTransfer(transferId: "transfer-delete", messageID: message.id)

        viewModel.deleteMediaMessage(messageID: message.id)

        #expect(viewModel.privateChats[peerID] == nil)
        #expect(viewModel.messageIDToTransferId[message.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test @MainActor
    func makeTransferID_isPrefixedByMessageIDAndUnique() async {
        let (viewModel, _) = makeTestableViewModel()

        let first = viewModel.makeTransferID(messageID: "base")
        let second = viewModel.makeTransferID(messageID: "base")

        #expect(first.hasPrefix("base-"))
        #expect(second.hasPrefix("base-"))
        #expect(first != second)
    }
}

@MainActor
private func deliveryStatus(in viewModel: ChatViewModel, peerID: PeerID, messageID: String) -> DeliveryStatus? {
    viewModel.privateChats[peerID]?.first(where: { $0.id == messageID })?.deliveryStatus
}

private func isFailed(status: DeliveryStatus?) -> Bool {
    if case .failed = status {
        return true
    }
    return false
}

private func isSent(status: DeliveryStatus?) -> Bool {
    if case .sent = status {
        return true
    }
    return false
}

private func isPartiallyDelivered(status: DeliveryStatus?, reached: Int, total: Int) -> Bool {
    if case .partiallyDelivered(let actualReached, let actualTotal) = status {
        return actualReached == reached && actualTotal == total
    }
    return false
}

private enum ChatViewModelExtensionsTestError: Error {
    case invalidPrivateMessageContent
}

private func mediaFileURL(subdirectory: String, fileName: String) throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    ).appendingPathComponent("files", isDirectory: true)
    let directory = base.appendingPathComponent(subdirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(fileName)
}

private func makeTemporaryImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("image-\(UUID().uuidString).png")
    let data = try makeImageData()
    try data.write(to: url, options: .atomic)
    return url
}

private func makeImageData() throws -> Data {
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    guard let data = image.pngData() else {
        throw ChatViewModelExtensionsTestError.invalidPrivateMessageContent
    }
    return data
    #else
    let image = NSImage(size: CGSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
    image.unlockFocus()
    guard
        let tiffData = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiffData),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw ChatViewModelExtensionsTestError.invalidPrivateMessageContent
    }
    return data
    #endif
}
