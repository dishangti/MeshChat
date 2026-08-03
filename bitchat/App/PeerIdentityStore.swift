import BitFoundation
import BitLogger
import Combine
import Foundation
import SwiftUI

/// The security signal shown beside a person. This is deliberately separate
/// from `EncryptionStatus`: a transport timeout does not constitute
/// attributable suspicious data, while a saved identity verification remains
/// meaningful offline.
enum IdentityLockState: Equatable {
    case unverified
    case verified
    case identityMismatch

    var icon: String {
        "lock.fill"
    }

    var color: Color {
        switch self {
        case .unverified:
            return .gray
        case .verified:
            return .green
        case .identityMismatch:
            return .yellow
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .unverified:
            return AppLanguageSettings.localized(
                 "fingerprint.badge.not_verified",
                comment: "Identity lock state for a person whose identity has not been verified"
            )
        case .verified:
            return AppLanguageSettings.localized(
                 "fingerprint.badge.verified",
                comment: "Identity lock state for a person whose identity has been verified"
            )
        case .identityMismatch:
            return AppLanguageSettings.localized(
                 "identity.status.mismatch",
                defaultValue: "Identity-key conflict recorded",
                comment: "Permanent identity lock state shown after authenticated conflicting data was rejected for this exact key fingerprint"
            )
        }
    }
}

struct DetectedIdentityConflict: Identifiable, Equatable {
    let id: UUID
    let reason: PeerIdentityConflictReason
    let detectedAt: Date

    init(
        id: UUID = UUID(),
        reason: PeerIdentityConflictReason,
        detectedAt: Date
    ) {
        self.id = id
        self.reason = reason
        self.detectedAt = detectedAt
    }
}

@MainActor
final class PeerIdentityStore: ObservableObject {
    /// Identity conflict latches use the same device-only, protected Keychain
    /// storage as the app's long-lived identity state. They are keyed by the
    /// complete Noise fingerprint, never by a routable or truncated peer ID.
    static let identityConflictStorageKey = "peerIdentityConflicts.v2"
    private static let legacyIdentityConflictStorageKey = "peerIdentityConflicts.v1"

    private struct PersistedIdentityConflictSnapshot: Codable {
        let schemaVersion: Int
        let conflicts: [PersistedIdentityConflict]
    }

    private struct PersistedIdentityConflict: Codable {
        let id: UUID
        let fingerprint: String
        let reason: String
        let detectedAt: Date
    }

    /// A failed or undecodable Keychain read is not evidence that the durable
    /// snapshot is empty. Keep that distinction explicit so an in-memory
    /// incident can never replace a snapshot that protected storage has not
    /// made available yet.
    private enum IdentityConflictLoadResult {
        case authoritative([String: DetectedIdentityConflict])
        case unavailable
    }

    private enum IdentityConflictPersistenceState: Equatable {
        case available
        case unavailable
    }

    @Published private(set) var encryptionStatuses: [PeerID: EncryptionStatus] = [:]
    @Published private(set) var verifiedFingerprints: Set<String> = []
    @Published private(set) var identityConflicts: [String: DetectedIdentityConflict] = [:]

    private(set) var peerFingerprintsByPeerID: [PeerID: String] = [:]
    private(set) var selectedPrivateChatFingerprint: String?

    private var stablePeerIDsByShortID: [PeerID: PeerID] = [:]
    private var encryptionStatusCache: [PeerID: EncryptionStatus] = [:]
    private var pendingIdentityConflicts: [String: DetectedIdentityConflict] = [:]
    private var identityConflictPersistenceState: IdentityConflictPersistenceState = .available
    private let keychain: KeychainManagerProtocol?

    /// A nil keychain keeps lightweight previews and isolated store tests
    /// ephemeral. Production owners inject the same Keychain instance used
    /// for the rest of the identity lifecycle.
    init(keychain: KeychainManagerProtocol? = nil) {
        self.keychain = keychain
        if let keychain {
            switch Self.loadIdentityConflicts(from: keychain) {
            case .authoritative(let conflicts):
                identityConflicts = conflicts
            case .unavailable:
                identityConflictPersistenceState = .unavailable
            }
        }
    }

    func stablePeerID(forShortID peerID: PeerID) -> PeerID? {
        stablePeerIDsByShortID[peerID]
    }

    func shortPeerID(forStablePeerID stablePeerID: PeerID) -> PeerID? {
        stablePeerIDsByShortID.first(where: { $0.value == stablePeerID })?.key
    }

    func setStablePeerID(_ stablePeerID: PeerID, forShortID peerID: PeerID) {
        stablePeerIDsByShortID[peerID] = stablePeerID
    }

    func fingerprint(for peerID: PeerID) -> String? {
        peerFingerprintsByPeerID[peerID]
    }

    func setFingerprint(_ fingerprint: String?, for peerID: PeerID) {
        if let fingerprint {
            peerFingerprintsByPeerID[peerID] = Self.normalizeFingerprint(fingerprint)
        } else {
            peerFingerprintsByPeerID.removeValue(forKey: peerID)
        }
    }

    func replaceFingerprintMappings(_ mappings: [PeerID: String]) {
        peerFingerprintsByPeerID = mappings.mapValues(Self.normalizeFingerprint)
    }

    @discardableResult
    func migrateFingerprintMapping(
        from oldPeerID: PeerID,
        to newPeerID: PeerID,
        fallback: String? = nil
    ) -> String? {
        let fingerprint = peerFingerprintsByPeerID.removeValue(forKey: oldPeerID)
            ?? fallback.map(Self.normalizeFingerprint)
        if let fingerprint {
            peerFingerprintsByPeerID[newPeerID] = fingerprint
            if selectedPrivateChatFingerprint == nil {
                selectedPrivateChatFingerprint = fingerprint
            }
        }
        return fingerprint
    }

    func setSelectedPrivateChatFingerprint(_ fingerprint: String?) {
        selectedPrivateChatFingerprint = fingerprint.map(Self.normalizeFingerprint)
    }

    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        encryptionStatusCache[peerID]
    }

    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID) {
        encryptionStatusCache[peerID] = status
    }

    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        if let peerID {
            encryptionStatusCache.removeValue(forKey: peerID)
        } else {
            encryptionStatusCache.removeAll()
        }
    }

    func encryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        encryptionStatuses[peerID]
    }

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        if let status {
            encryptionStatuses[peerID] = status
        } else {
            encryptionStatuses.removeValue(forKey: peerID)
        }
        invalidateEncryptionCache(for: peerID)
    }

    func setVerifiedFingerprints(_ fingerprints: Set<String>) {
        verifiedFingerprints = Set(fingerprints.map(Self.normalizeFingerprint))
    }

    func setVerified(_ fingerprint: String, verified: Bool) {
        let fingerprint = Self.normalizeFingerprint(fingerprint)
        if verified {
            verifiedFingerprints.insert(fingerprint)
        } else {
            verifiedFingerprints.remove(fingerprint)
        }
    }

    func isVerified(_ fingerprint: String) -> Bool {
        verifiedFingerprints.contains(Self.normalizeFingerprint(fingerprint))
    }

    /// Returns an identity-only presentation state. A recorded suspicious-data
    /// incident always outranks a saved verification; ordinary inactivity and
    /// connectivity changes do not create that state.
    func identityLockState(fingerprint suppliedFingerprint: String?) -> IdentityLockState {
        retryIdentityConflictLoadIfNeeded()
        let fingerprint = suppliedFingerprint.map(Self.normalizeFingerprint)
        if let fingerprint, identityConflicts[fingerprint] != nil {
            return .identityMismatch
        }

        // A missing or corrupt protected-storage read is not an authoritative
        // absence of a durable conflict. Do not show positive trust until the
        // snapshot can be loaded and reconciled.
        guard identityConflictPersistenceState == .available else {
            return .unverified
        }

        guard let fingerprint else { return .unverified }
        return isVerified(fingerprint) ? .verified : .unverified
    }

    func recordIdentityConflict(
        forFingerprint suppliedFingerprint: String,
        reason: PeerIdentityConflictReason,
        detectedAt: Date = Date()
    ) {
        retryIdentityConflictLoadIfNeeded()
        let fingerprint = Self.normalizeFingerprint(suppliedFingerprint)
        guard Self.isValidIdentityFingerprint(fingerprint) else {
            SecureLogger.error(
                "Refused to record an identity conflict without a full fingerprint",
                category: .security
            )
            return
        }
        let incident = DetectedIdentityConflict(
            reason: reason,
            detectedAt: detectedAt
        )
        let selected = Self.preferredConflict(
            identityConflicts[fingerprint],
            incident
        )

        // A lower-severity observation must not replace a stronger current
        // latch, even when it arrived later.
        guard identityConflicts[fingerprint] != selected else {
            return
        }

        var snapshot = identityConflicts
        snapshot[fingerprint] = selected

        guard identityConflictPersistenceState == .available else {
            pendingIdentityConflicts[fingerprint] = Self.preferredConflict(
                pendingIdentityConflicts[fingerprint],
                selected
            )
            identityConflicts = snapshot
            return
        }

        if !persistIdentityConflicts(snapshot) {
            // Preserve the incident in memory and retry from an authoritative
            // read later. The failed atomic replacement leaves the prior
            // durable snapshot untouched.
            pendingIdentityConflicts[fingerprint] = Self.preferredConflict(
                pendingIdentityConflicts[fingerprint],
                selected
            )
            identityConflictPersistenceState = .unavailable
            SecureLogger.error(
                "Failed to persist an identity conflict latch",
                category: .security
            )
        }
        identityConflicts = snapshot
    }

    func clearAll() {
        encryptionStatuses.removeAll()
        verifiedFingerprints.removeAll()
        if let keychain,
           !keychain.deleteIdentityKey(forKey: Self.identityConflictStorageKey) {
            // Panic recovery already keeps the runtime suspended when its
            // whole-Keychain deletion fails. Keep this store's in-memory wipe
            // synchronous while making an isolated failure visible in logs.
            SecureLogger.error(
                "Failed to delete persisted identity conflict latches",
                category: .security
            )
        }
        if let keychain,
           !keychain.deleteIdentityKey(forKey: Self.legacyIdentityConflictStorageKey) {
            SecureLogger.error(
                "Failed to delete legacy identity conflict latches",
                category: .security
            )
        }
        identityConflicts.removeAll()
        pendingIdentityConflicts.removeAll()
        identityConflictPersistenceState = .available
        peerFingerprintsByPeerID.removeAll()
        selectedPrivateChatFingerprint = nil
        stablePeerIDsByShortID.removeAll()
        encryptionStatusCache.removeAll()
    }

    // MARK: - Identity conflict persistence

    private func persistIdentityConflicts(
        _ conflicts: [String: DetectedIdentityConflict]
    ) -> Bool {
        guard let keychain else { return true }

        let persisted = conflicts
            .map { fingerprint, conflict in
                PersistedIdentityConflict(
                    id: conflict.id,
                    fingerprint: fingerprint,
                    reason: Self.persistedValue(for: conflict.reason),
                    detectedAt: conflict.detectedAt
                )
            }
            .sorted { $0.fingerprint < $1.fingerprint }
        let snapshot = PersistedIdentityConflictSnapshot(
            schemaVersion: 2,
            conflicts: persisted
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            guard case .success = keychain.saveIdentityKeyWithResult(
                data,
                forKey: Self.identityConflictStorageKey
            ) else {
                return false
            }
            return true
        } catch {
            SecureLogger.error(
                "Failed to encode identity conflict latches: \(error)",
                category: .security
            )
            return false
        }
    }

    private static func loadIdentityConflicts(
        from keychain: KeychainManagerProtocol
    ) -> IdentityConflictLoadResult {
        let data: Data
        switch keychain.getIdentityKeyWithResult(
            forKey: identityConflictStorageKey
        ) {
        case .success(let storedData):
            data = storedData
        case .itemNotFound:
            return .authoritative([:])
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            SecureLogger.error(
                "Persisted identity conflict latches are temporarily unavailable",
                category: .security
            )
            return .unavailable
        }

        do {
            let snapshot = try JSONDecoder().decode(
                PersistedIdentityConflictSnapshot.self,
                from: data
            )
            guard snapshot.schemaVersion == 2 else {
                SecureLogger.error(
                    "Unsupported identity conflict snapshot version",
                    category: .security
                )
                return .unavailable
            }

            var restored: [String: DetectedIdentityConflict] = [:]
            for entry in snapshot.conflicts {
                let fingerprint = normalizeFingerprint(entry.fingerprint)
                guard isValidIdentityFingerprint(fingerprint),
                      let reason = runtimeReason(for: entry.reason) else {
                    SecureLogger.error(
                        "Invalid persisted identity conflict entry",
                        category: .security
                    )
                    return .unavailable
                }
                let conflict = DetectedIdentityConflict(
                    id: entry.id,
                    reason: reason,
                    detectedAt: entry.detectedAt
                )
                restored[fingerprint] = preferredConflict(
                    restored[fingerprint],
                    conflict
                )
            }
            return .authoritative(restored)
        } catch {
            SecureLogger.error(
                "Failed to decode persisted identity conflict latches: \(error)",
                category: .security
            )
            return .unavailable
        }
    }

    private static func persistedValue(
        for reason: PeerIdentityConflictReason
    ) -> String {
        switch reason {
        case .claimedPeerIDMismatch:
            return "claimedPeerIDMismatch"
        case .noiseStaticKeyMismatch:
            return "noiseStaticKeyMismatch"
        case .signingKeyMismatch:
            return "signingKeyMismatch"
        case .authenticatedSigningKeyMismatch:
            return "authenticatedSigningKeyMismatch"
        case .qrIdentityBindingMismatch:
            return "qrIdentityBindingMismatch"
        case .malformedAuthenticatedData:
            return "malformedAuthenticatedData"
        case .malformedAuthenticatedPeerState:
            return "malformedAuthenticatedPeerState"
        }
    }

    private static func runtimeReason(
        for persistedValue: String
    ) -> PeerIdentityConflictReason? {
        switch persistedValue {
        case "claimedPeerIDMismatch":
            return .claimedPeerIDMismatch
        case "noiseStaticKeyMismatch":
            return .noiseStaticKeyMismatch
        case "signingKeyMismatch":
            return .signingKeyMismatch
        case "authenticatedSigningKeyMismatch":
            return .authenticatedSigningKeyMismatch
        case "qrIdentityBindingMismatch":
            return .qrIdentityBindingMismatch
        case "malformedAuthenticatedData":
            return .malformedAuthenticatedData
        case "malformedAuthenticatedPeerState":
            return .malformedAuthenticatedPeerState
        default:
            return nil
        }
    }

    private func retryIdentityConflictLoadIfNeeded() {
        guard identityConflictPersistenceState == .unavailable,
              let keychain else {
            return
        }

        guard case .authoritative(let durableConflicts) =
            Self.loadIdentityConflicts(from: keychain) else {
            return
        }

        let merged = Self.mergeIdentityConflicts(
            durableConflicts,
            pendingIdentityConflicts
        )
        identityConflicts = merged

        guard !pendingIdentityConflicts.isEmpty else {
            identityConflictPersistenceState = .available
            return
        }

        guard persistIdentityConflicts(merged) else {
            // The read was authoritative, but pending incidents are not yet
            // durable. Retain them and continue suppressing positive trust.
            return
        }

        pendingIdentityConflicts.removeAll()
        identityConflictPersistenceState = .available
    }

    private static func mergeIdentityConflicts(
        _ durable: [String: DetectedIdentityConflict],
        _ pending: [String: DetectedIdentityConflict]
    ) -> [String: DetectedIdentityConflict] {
        var merged = durable
        for (fingerprint, conflict) in pending {
            merged[fingerprint] = preferredConflict(
                merged[fingerprint],
                conflict
            )
        }
        return merged
    }

    private static func preferredConflict(
        _ existing: DetectedIdentityConflict?,
        _ candidate: DetectedIdentityConflict
    ) -> DetectedIdentityConflict {
        guard let existing else { return candidate }

        let existingSeverity = conflictSeverity(existing.reason)
        let candidateSeverity = conflictSeverity(candidate.reason)
        if existingSeverity != candidateSeverity {
            let stronger = existingSeverity > candidateSeverity
                ? existing
                : candidate
            let latestDetection = max(existing.detectedAt, candidate.detectedAt)
            guard stronger.detectedAt != latestDetection else {
                return stronger
            }
            return DetectedIdentityConflict(
                id: stronger.id,
                reason: stronger.reason,
                detectedAt: latestDetection
            )
        }
        return existing.detectedAt > candidate.detectedAt ? existing : candidate
    }

    private static func conflictSeverity(
        _ reason: PeerIdentityConflictReason
    ) -> Int {
        switch reason {
        case .signingKeyMismatch,
                .authenticatedSigningKeyMismatch,
                .qrIdentityBindingMismatch:
            return 2
        case .claimedPeerIDMismatch,
                .noiseStaticKeyMismatch,
                .malformedAuthenticatedPeerState:
            return 1
        case .malformedAuthenticatedData:
            return 0
        }
    }

    private static func normalizeFingerprint(_ fingerprint: String) -> String {
        fingerprint.lowercased()
    }

    private static func isValidIdentityFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.count == 64 && Data(hexString: fingerprint)?.count == 32
    }
}
