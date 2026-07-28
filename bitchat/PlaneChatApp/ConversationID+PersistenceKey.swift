//
// ConversationID+PersistenceKey.swift
// PlaneChatApp
//
// Stable, reversible string encoding of ConversationID for SwiftData storage.
// ConversationID.auditDescription (ConversationStore.swift) exists already
// but is fileprivate and deliberately lossy (truncates peer keys for log
// safety) — persistence needs the full round-trip instead.
//

import BitFoundation
import Foundation

extension ConversationID {
    /// Reversible key: "mesh", "geohash:<name>", or "direct:<handle-id>:<routingPeerID>".
    var persistenceKey: String {
        switch self {
        case .mesh:
            return "mesh"
        case .geohash(let name):
            return "geohash:\(name)"
        case .direct(let handle):
            return "direct:\(handle.id):\(handle.routingPeerID.id)"
        }
    }

    init?(persistenceKey: String) {
        if persistenceKey == "mesh" {
            self = .mesh
            return
        }
        if let name = persistenceKey.stripPrefix("geohash:") {
            self = .geohash(name)
            return
        }
        if let rest = persistenceKey.stripPrefix("direct:") {
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            self = .direct(PeerHandle(id: parts[0], routingPeerID: PeerID(str: parts[1])))
            return
        }
        return nil
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
