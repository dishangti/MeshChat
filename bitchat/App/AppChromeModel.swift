import BitFoundation
import Combine
import CoreBluetooth
import Foundation

struct BlockedPersonRow: Identifiable, Equatable {
    enum Source: String {
        case mesh
        /// The persistent Nostr block set is shared by location channels,
        /// bridge participants, and relay identities. Without durable origin
        /// metadata, claiming a more specific source would be misleading.
        case nostr
    }

    let source: Source
    let stableID: String
    let displayName: String

    var id: String { "\(source.rawValue):\(stableID)" }

    /// Human-checkable cryptographic suffix shown next to untrusted,
    /// non-unique nicknames so the unblock target is never ambiguous.
    var identityHint: String {
        let normalized = stableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 12 else { return normalized }
        return "\(normalized.prefix(6))…\(normalized.suffix(6))"
    }
}

@MainActor
final class AppChromeModel: ObservableObject {
    @Published private(set) var hasUnreadPrivateMessages = false
    @Published var nickname: String
    @Published var showingFingerprintFor: PeerID?
    @Published var isAppInfoPresented = false
    @Published var isLocationChannelsSheetPresented = false
    @Published var isNoticesSheetPresented = false
    /// When the sheet is opened for "notes left here" (empty mesh timeline),
    /// it should land on the geo tab instead of the channel-derived default.
    @Published var noticesSheetPrefersGeoTab = false
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var showScreenshotPrivacyWarning = false

    private let chatViewModel: ChatViewModel
    private let onPanicWipe: () -> Void
    private var cancellables = Set<AnyCancellable>()
    /// The composer owns capture state above ChatViewModel. ContentView
    /// installs this hook so both panic entry points synchronously stop it.
    private var prepareForPanic: (@MainActor () -> Void)?

    /// Bulletin-board coordinator, created on first use of the board sheet.
    private(set) lazy var boardManager = BoardManager(transport: chatViewModel.meshService)

    init(
        chatViewModel: ChatViewModel,
        privateInboxModel: PrivateInboxModel,
        onPanicWipe: @escaping () -> Void = {}
    ) {
        self.chatViewModel = chatViewModel
        self.onPanicWipe = onPanicWipe
        self.nickname = chatViewModel.nickname

        bind(privateInboxModel: privateInboxModel)
    }

    var shouldSuppressScreenshotNotification: Bool {
        isLocationChannelsSheetPresented || isAppInfoPresented
    }

    func setNickname(_ nickname: String) {
        self.nickname = nickname
        if chatViewModel.nickname != nickname {
            chatViewModel.nickname = nickname
        }
    }

    func validateAndSaveNickname() {
        chatViewModel.validateAndSaveNickname()
        if nickname != chatViewModel.nickname {
            nickname = chatViewModel.nickname
        }
    }

    func openMostRelevantPrivateChat() {
        chatViewModel.openMostRelevantPrivateChat()
    }

    func showFingerprint(for peerID: PeerID) {
        showingFingerprintFor = peerID
    }

    func clearFingerprint() {
        showingFingerprintFor = nil
    }

    func presentAppInfo(pane: AppInfoPane = .info) {
        UserDefaults.standard.set(pane.rawValue, forKey: AppInfoPane.storageKey)
        isAppInfoPresented = true
    }

    func blockedPeople() -> [BlockedPersonRow] {
        let meshRows = chatViewModel.identityManager.getBlockedSocialIdentities().map { identity in
            let preferredName = identity.localPetname?.trimmedOrNilIfEmpty
                ?? identity.claimedNickname.trimmedOrNilIfEmpty
                ?? String(identity.fingerprint.prefix(12))
            return BlockedPersonRow(
                source: .mesh,
                stableID: identity.fingerprint,
                displayName: preferredName
            )
        }

        let nostrRows = chatViewModel.identityManager.getBlockedNostrPubkeys().map { pubkey in
            BlockedPersonRow(
                source: .nostr,
                stableID: pubkey,
                displayName: chatViewModel.geoNicknames[pubkey]
                    ?? "\(pubkey.prefix(12))…"
            )
        }

        return (meshRows + nostrRows).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func unblock(_ person: BlockedPersonRow) {
        switch person.source {
        case .mesh:
            chatViewModel.identityManager.setBlocked(person.stableID, isBlocked: false)
        case .nostr:
            chatViewModel.identityManager.setNostrBlocked(person.stableID, isBlocked: false)
        }
        NotificationCenter.default.post(name: Notification.Name("peerStatusUpdated"), object: nil)
    }

    func presentNotices(geoTab: Bool = false) {
        noticesSheetPrefersGeoTab = geoTab
        isNoticesSheetPresented = true
    }

    /// Builds the mesh topology map model from the transport's gossiped
    /// graph plus the live nickname table. Unknown nodes (heard about via a
    /// neighbor claim but never announced to us) fall back to a short ID.
    func meshTopologyDisplayModel() -> MeshTopologyDisplayModel {
        let mesh = chatViewModel.meshService
        guard let diagnostics = mesh as? MeshDiagnosing,
              let snapshot = diagnostics.currentMeshTopology() else { return .empty }
        let nicknames = mesh.getPeerNicknames()

        let nodes = snapshot.nodes.map { peerID -> MeshTopologyDisplayModel.Node in
            let isSelf = peerID == snapshot.localPeerID
            let label: String
            if isSelf {
                label = chatViewModel.nickname
            } else {
                label = nicknames[peerID] ?? "\(peerID.id.prefix(8))…"
            }
            return MeshTopologyDisplayModel.Node(id: peerID.id, label: label, isSelf: isSelf)
        }
        let edges = snapshot.edges.map { ($0.a.id, $0.b.id) }
        return MeshTopologyDisplayModel(nodes: nodes, edges: edges)
    }

    func triggerScreenshotPrivacyWarning() {
        showScreenshotPrivacyWarning = true
    }

    func setPanicPreparation(_ preparation: (@MainActor () -> Void)?) {
        prepareForPanic = preparation
    }

    /// Closes every model-owned transient surface before sensitive state is
    /// erased. Internal visibility keeps this behavior directly testable.
    func dismissTransientSurfacesForPanic() {
        showingFingerprintFor = nil
        isAppInfoPresented = false
        isLocationChannelsSheetPresented = false
        isNoticesSheetPresented = false
        noticesSheetPrefersGeoTab = false
        showBluetoothAlert = false
        bluetoothAlertMessage = ""
        showScreenshotPrivacyWarning = false
    }

    func panicClearAllData() {
        dismissTransientSurfacesForPanic()
        defer { dismissTransientSurfacesForPanic() }
        prepareForPanic?()
        onPanicWipe()
        chatViewModel.panicClearAllData()
    }

    private func bind(privateInboxModel: PrivateInboxModel) {
        privateInboxModel.$unreadPeerIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadPeerIDs in
                self?.hasUnreadPrivateMessages = !unreadPeerIDs.isEmpty
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nickname in
                guard let self, self.nickname != nickname else { return }
                self.nickname = nickname
            }
            .store(in: &cancellables)

        chatViewModel.$showBluetoothAlert
            .receive(on: DispatchQueue.main)
            .assign(to: &$showBluetoothAlert)

        chatViewModel.$bluetoothAlertMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothAlertMessage)

        chatViewModel.$bluetoothState
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        hasUnreadPrivateMessages = !privateInboxModel.unreadPeerIDs.isEmpty
    }
}
