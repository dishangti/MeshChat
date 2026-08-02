import BitFoundation
import Combine
import Foundation

enum RuntimeScenePhase: String, Sendable, Equatable {
    case active
    case inactive
    case background
}

enum TorLifecycleEvent: String, Sendable, Equatable {
    case willStart
    case willRestart
    case didBecomeReady
    case preferenceChanged
    /// Bootstrap ran out its deadline without completing.
    case bootstrapDidStall
}

enum AppEvent: Sendable, Equatable {
    case launched
    case startupCompleted
    case scenePhaseChanged(RuntimeScenePhase)
    case openedURL(String)
    case sharedContentReadyForReview(SharedContentKind)
    case notificationOpened(peerID: PeerID?)
    case deepLinkOpened(String)
    case torLifecycleChanged(TorLifecycleEvent)
    case nostrRelayConnectionChanged(Bool)
    case terminationRequested
}

/// Conversation that is actually on screen. Selection alone is insufficient:
/// Home intentionally retains the last public channel for draft continuity.
enum AppVisibleConversation: Equatable {
    case mesh
    case geohash(String)
    case direct(PeerID)
}

/// Lightweight route/visibility state shared by AppRuntime and the adaptive
/// shell. It stays separate from the transport-owning runtime so previews and
/// view tests never need to construct a second ChatViewModel just to navigate.
@MainActor
final class AppRouteModel: ObservableObject {
    @Published private(set) var pendingURLRoute: ChatURLRoute? = nil
    private(set) var visibleConversation: AppVisibleConversation? = nil

    func enqueue(_ route: ChatURLRoute) {
        pendingURLRoute = route
    }

    func consume(_ route: ChatURLRoute) {
        guard pendingURLRoute == route else { return }
        pendingURLRoute = nil
    }

    func clearPendingRoute() {
        pendingURLRoute = nil
    }

    func setVisibleConversation(_ conversation: AppVisibleConversation?) {
        visibleConversation = conversation
    }
}

actor AppEventStream {
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    func emit(_ event: AppEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

}

/// Identity key for a direct conversation. Equality and hashing use the
/// canonical `id` only; `routingPeerID` carries the transport-level peer ID
/// the conversation is keyed under (see `ConversationID.directPeer`).
struct PeerHandle: Sendable, Identifiable {
    let id: String
    let routingPeerID: PeerID
}

extension PeerHandle: Equatable {
    static func == (lhs: PeerHandle, rhs: PeerHandle) -> Bool {
        lhs.id == rhs.id
    }
}

extension PeerHandle: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ConversationID: Hashable, Sendable {
    case mesh
    case geohash(String)
    case direct(PeerHandle)

    init(channelID: ChannelID) {
        switch channelID {
        case .mesh:
            self = .mesh
        case .location(let channel):
            self = .geohash(channel.geohash.lowercased())
        }
    }
}
