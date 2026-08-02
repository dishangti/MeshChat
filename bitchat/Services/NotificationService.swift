//
// NotificationService.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import BitFoundation
import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

protocol NotificationAuthorizing {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    )
}

protocol NotificationRequestDelivering {
    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void)
}

protocol NotificationCategoryRegistering {
    func setCategories(_ categories: Set<UNNotificationCategory>)
}

protocol NotificationClearing {
    func removeAllDeliveredNotifications()
    func removeAllPendingNotificationRequests()
}

private final class NotificationCenterAuthorizerAdapter: NotificationAuthorizing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }
}

private final class NotificationCenterRequestDelivererAdapter: NotificationRequestDelivering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void) {
        center.add(request) { _ in completionHandler() }
    }
}

private final class NotificationCenterCategoryRegistrarAdapter: NotificationCategoryRegistering {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func setCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
}

private final class NotificationCenterClearingAdapter: NotificationClearing {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) {
        self.center = center
    }

    func removeAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }

    func removeAllPendingNotificationRequests() {
        center.removeAllPendingNotificationRequests()
    }
}

private struct NoopNotificationAuthorizer: NotificationAuthorizing {
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        completionHandler(false, nil)
    }
}

private struct NoopNotificationRequestDeliverer: NotificationRequestDelivering {
    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

private struct NoopNotificationCategoryRegistrar: NotificationCategoryRegistering {
    func setCategories(_ categories: Set<UNNotificationCategory>) {}
}

private struct NoopNotificationClearer: NotificationClearing {
    func removeAllDeliveredNotifications() {}
    func removeAllPendingNotificationRequests() {}
}

final class NotificationService {
    static let shared = NotificationService()

    /// Category for the nearby MeshChat users notification, carrying the wave quick action.
    static let nearbyCategoryID = "chat.bitchat.category.nearby"
    static let waveActionID = "chat.bitchat.action.wave"

    /// Copy used when `NotificationPrivacySettings.hideMessagePreviews` is on.
    /// These say that something arrived without naming who sent it, quoting it,
    /// or disclosing which geohash it came from.
    private enum Redacted {
        static var directMessageTitle: String {
            String(localized: "notification.redacted.dm.title", defaultValue: "🔒 New DM", comment: "Lock-screen notification title for a received direct message when message previews are hidden; deliberately names neither the sender nor the content")
        }
        static var mentionTitle: String {
            String(localized: "notification.redacted.mention.title", defaultValue: "🫵 You Were Mentioned", comment: "Lock-screen notification title telling someone they were mentioned when message previews are hidden; deliberately omits who mentioned them")
        }
        static var geohashActivityTitle: String {
            String(localized: "notification.redacted.geohash.title", defaultValue: "📍 New Activity Nearby", comment: "Lock-screen notification title for activity in a location channel when message previews are hidden; deliberately omits the geohash")
        }
        static var body: String {
            String(localized: "notification.redacted.body", defaultValue: "Open MeshChat to read", comment: "Lock-screen notification body shown in place of the message text when message previews are hidden")
        }
        static var securityTitle: String {
            String(localized: "notification.redacted.security.title", defaultValue: "Verify Encryption", comment: "Privacy-preserving title for a verification notification when previews are hidden")
        }
    }

    /// Notification copy used only when the user has chosen to show previews.
    private enum Visible {
        static func directMessageTitle(sender: String) -> String {
            String(
                format: String(localized: "notification.dm.title", defaultValue: "🔒 DM from %@", comment: "Notification title for a visible direct-message preview; %@ is the sender name"),
                locale: .current,
                sender
            )
        }

        static func mentionTitle(sender: String) -> String {
            String(
                format: String(localized: "notification.mention.title", defaultValue: "🫵 You were mentioned by %@", comment: "Notification title for a visible mention preview; %@ is the sender name"),
                locale: .current,
                sender
            )
        }

        static var nearbyTitle: String {
            String(localized: "notification.nearby.title", defaultValue: "👥 MeshChat users nearby!", comment: "Time-sensitive notification title announcing nearby MeshChat users")
        }

        static func nearbyBody(peerCount: Int) -> String {
            if peerCount == 1 {
                return String(localized: "notification.nearby.body.one", defaultValue: "1 person around", comment: "Notification body when exactly one MeshChat user is nearby")
            }
            let format = String(localized: "notification.nearby.body.other", defaultValue: "%lld people around", comment: "Notification body when multiple MeshChat users are nearby; %lld is the number of people")
            return String(format: format, locale: .current, Int64(peerCount))
        }
    }

    /// Whether delivered alerts must withhold sender, content, and geohash.
    ///
    /// Injected rather than read from the preference directly so tests state
    /// which behavior they are asserting instead of inheriting whatever the
    /// shared preference happens to hold when they run.
    private let hidePreviewsProvider: () -> Bool

    private var hidePreviews: Bool {
        hidePreviewsProvider()
    }

    private let isRunningTestsProvider: () -> Bool
    private let authorizer: NotificationAuthorizing
    private let requestDeliverer: NotificationRequestDelivering
    private let categoryRegistrar: NotificationCategoryRegistering
    private let notificationClearer: NotificationClearing
    private let notificationPolicyProvider: (NotificationTopic) -> Bool

    private enum DeliveryOperation {
        case deliver(
            request: UNNotificationRequest,
            topic: NotificationTopic,
            generation: UInt64
        )
        case clear
    }

    /// Completion-aware FIFO for the system notification center. A pause or
    /// panic increments the generation immediately, invalidating queued adds,
    /// then runs its clear only after an add already accepted by the system
    /// center has completed. This prevents an old alert from appearing after
    /// the clear merely because `UNUserNotificationCenter.add` was in flight.
    private let deliveryLock = NSLock()
    private var deliveryGeneration: UInt64 = 0
    private var deliveryOperations: [DeliveryOperation] = []
    private var isProcessingDeliveryOperation = false
    private var activeDeliveryToken: UInt64?
    private var nextDeliveryToken: UInt64 = 0
    private let deliveryCompletionTimeout: TimeInterval

    /// Returns true if running in test environment (XCTest, Swift Testing, or CI)
    private var isRunningTests: Bool {
        isRunningTestsProvider()
    }

    private init() {
        self.hidePreviewsProvider = { NotificationPrivacySettings.hideMessagePreviews }
        self.isRunningTestsProvider = {
            let env = ProcessInfo.processInfo.environment
            return NSClassFromString("XCTestCase") != nil ||
                   env["XCTestConfigurationFilePath"] != nil ||
                   env["XCTestBundlePath"] != nil ||
                   env["GITHUB_ACTIONS"] != nil ||
                   env["CI"] != nil
        }
        if isRunningTestsProvider() {
            self.authorizer = NoopNotificationAuthorizer()
            self.requestDeliverer = NoopNotificationRequestDeliverer()
            self.categoryRegistrar = NoopNotificationCategoryRegistrar()
            self.notificationClearer = NoopNotificationClearer()
        } else {
            let center = UNUserNotificationCenter.current()
            self.authorizer = NotificationCenterAuthorizerAdapter(center: center)
            self.requestDeliverer = NotificationCenterRequestDelivererAdapter(center: center)
            self.categoryRegistrar = NotificationCenterCategoryRegistrarAdapter(center: center)
            self.notificationClearer = NotificationCenterClearingAdapter(center: center)
        }
        self.notificationPolicyProvider = { NotificationDeliverySettings.allows($0) }
        self.deliveryCompletionTimeout = 5
    }

    internal init(
        isRunningTestsProvider: @escaping () -> Bool,
        authorizer: NotificationAuthorizing,
        requestDeliverer: NotificationRequestDelivering,
        categoryRegistrar: NotificationCategoryRegistering = NoopNotificationCategoryRegistrar(),
        hidePreviewsProvider: @escaping () -> Bool = { NotificationPrivacySettings.hideMessagePreviews },
        notificationClearer: NotificationClearing = NoopNotificationClearer(),
        notificationPolicyProvider: @escaping (NotificationTopic) -> Bool = { _ in true },
        deliveryCompletionTimeout: TimeInterval = 5
    ) {
        self.isRunningTestsProvider = isRunningTestsProvider
        self.authorizer = authorizer
        self.requestDeliverer = requestDeliverer
        self.categoryRegistrar = categoryRegistrar
        self.hidePreviewsProvider = hidePreviewsProvider
        self.notificationClearer = notificationClearer
        self.notificationPolicyProvider = notificationPolicyProvider
        self.deliveryCompletionTimeout = deliveryCompletionTimeout
    }

    func requestAuthorization() {
        guard !isRunningTests else { return }
        registerCategories()
        authorizer.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                // Permission granted
            } else {
                // Permission denied
            }
        }
    }

    private func registerCategories() {
        let wave = UNNotificationAction(
            identifier: Self.waveActionID,
            title: String(localized: "notification.action.wave", comment: "Title of the notification action button that sends a friendly wave back to a nearby person"),
            options: []
        )
        let nearby = UNNotificationCategory(
            identifier: Self.nearbyCategoryID,
            actions: [wave],
            intentIdentifiers: [],
            options: []
        )
        categoryRegistrar.setCategories([nearby])
    }
    
    func sendLocalNotification(
        title: String,
        body: String,
        identifier: String,
        topic: NotificationTopic,
        userInfo: [String: Any]? = nil,
        interruptionLevel: UNNotificationInterruptionLevel = .active,
        categoryIdentifier: String? = nil
    ) {
        guard !isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel
        if let categoryIdentifier = categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

        if let userInfo = userInfo {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        enqueueDelivery(request, topic: topic)
    }
    
    func sendMentionNotification(from sender: String, message: String, topic: NotificationTopic) {
        let title = hidePreviews ? Redacted.mentionTitle : Visible.mentionTitle(sender: sender)
        let body = hidePreviews ? Redacted.body : message
        let identifier = "mention-\(UUID().uuidString)"

        sendLocalNotification(title: title, body: body, identifier: identifier, topic: topic)
    }

    func sendPrivateMessageNotification(from sender: String, message: String, peerID: PeerID) {
        let title = hidePreviews ? Redacted.directMessageTitle : Visible.directMessageTitle(sender: sender)
        let body = hidePreviews ? Redacted.body : message
        let identifier = "private-\(UUID().uuidString)"
        // Routing payload, not display copy: `userInfo` never reaches the lock
        // screen, and the conversation to open still has to be identifiable.
        let userInfo = ["peerID": peerID.id, "senderName": sender]

        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            topic: .directMessages,
            userInfo: userInfo
        )
    }

    // Geohash public chat notification with deep link to a specific geohash
    func sendGeohashActivityNotification(geohash: String, titlePrefix: String = "#", bodyPreview: String) {
        // The geohash itself is location data, so hiding previews withholds it
        // from the alert while leaving the deep link intact for the tap.
        let title = hidePreviews ? Redacted.geohashActivityTitle : "\(titlePrefix)\(geohash)"
        let body = hidePreviews ? Redacted.body : bodyPreview
        let identifier = "geo-activity-\(geohash)-\(Date().timeIntervalSince1970)"
        let deeplink = "bitchat://geohash/\(geohash)"
        let userInfo: [String: Any] = ["deeplink": deeplink]
        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            topic: .locationChannels,
            userInfo: userInfo
        )
    }

    func sendNetworkAvailableNotification(peerCount: Int) {
        let title = Visible.nearbyTitle
        let body = Visible.nearbyBody(peerCount: peerCount)
        // Fixed identifier so iOS updates the existing notification instead of creating new ones
        let identifier = "network-available"

        sendLocalNotification(
            title: title,
            body: body,
            identifier: identifier,
            topic: .mesh,
            interruptionLevel: .timeSensitive,
            categoryIdentifier: Self.nearbyCategoryID
        )
    }

    func sendSecurityNotification(title: String, body: String, identifier: String) {
        sendLocalNotification(
            title: hidePreviews ? Redacted.securityTitle : title,
            body: hidePreviews ? Redacted.body : body,
            identifier: identifier,
            topic: .security
        )
    }

    func clearAllNotifications() {
        guard !isRunningTests else { return }
        enqueueClear()
    }

    private func enqueueDelivery(_ request: UNNotificationRequest, topic: NotificationTopic) {
        deliveryLock.lock()
        let generation = deliveryGeneration
        deliveryOperations.append(.deliver(request: request, topic: topic, generation: generation))
        let shouldStart = !isProcessingDeliveryOperation
        if shouldStart { isProcessingDeliveryOperation = true }
        deliveryLock.unlock()

        if shouldStart { processNextDeliveryOperation() }
    }

    private func enqueueClear() {
        deliveryLock.lock()
        deliveryGeneration &+= 1
        // Panic/pause must release queued request bodies and routing metadata
        // synchronously. Keep only the barrier; new-generation deliveries may
        // be appended after the lock is released.
        deliveryOperations.removeAll(keepingCapacity: false)
        deliveryOperations.append(.clear)
        let shouldStart = !isProcessingDeliveryOperation
        if shouldStart { isProcessingDeliveryOperation = true }
        deliveryLock.unlock()

        if shouldStart {
            // No add is in flight, so processing the barrier now is the
            // immediate privacy clear.
            processNextDeliveryOperation()
        } else {
            // Clear once immediately for privacy; the queued barrier clears
            // again after an already accepted add completes.
            clearSystemNotifications()
        }
    }

    private func processNextDeliveryOperation() {
        while true {
            deliveryLock.lock()
            guard !deliveryOperations.isEmpty else {
                isProcessingDeliveryOperation = false
                deliveryLock.unlock()
                return
            }
            let operation = deliveryOperations.removeFirst()
            let currentGeneration = deliveryGeneration
            deliveryLock.unlock()

            switch operation {
            case .deliver(let request, let topic, let generation):
                guard generation == currentGeneration,
                      notificationPolicyProvider(topic) else {
                    continue
                }

                deliveryLock.lock()
                guard generation == deliveryGeneration else {
                    deliveryLock.unlock()
                    continue
                }
                nextDeliveryToken &+= 1
                let token = nextDeliveryToken
                activeDeliveryToken = token
                deliveryLock.unlock()

                // Test adapters may complete inline, while the system center
                // completes asynchronously. Detect the inline case so a long
                // skipped/synchronous backlog drains as a loop, not recursion.
                let completionLock = NSLock()
                var addReturned = false
                var completedInline = false
                requestDeliverer.add(request) { [weak self] in
                    completionLock.lock()
                    if addReturned {
                        completionLock.unlock()
                        self?.finishDeliveryOperation(
                            token: token,
                            generation: generation,
                            reachedCenterCompletion: true
                        )
                    } else {
                        completedInline = true
                        completionLock.unlock()
                    }
                }
                completionLock.lock()
                addReturned = true
                let shouldContinueInline = completedInline
                completionLock.unlock()

                if shouldContinueInline {
                    deliveryLock.lock()
                    if activeDeliveryToken == token {
                        activeDeliveryToken = nil
                    }
                    deliveryLock.unlock()
                    continue
                }

                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + deliveryCompletionTimeout
                ) { [weak self] in
                    self?.finishDeliveryOperation(
                        token: token,
                        generation: generation,
                        reachedCenterCompletion: false
                    )
                }
                return

            case .clear:
                clearSystemNotifications()
                continue
            }
        }
    }

    /// Releases a stalled FIFO slot after a bounded wait. If the system add
    /// callback arrives later and a pause/panic advanced the generation, it
    /// performs one more clear so the late request cannot reappear.
    private func finishDeliveryOperation(
        token: UInt64,
        generation: UInt64,
        reachedCenterCompletion: Bool
    ) {
        deliveryLock.lock()
        guard activeDeliveryToken == token else {
            let shouldClearLateCompletion = reachedCenterCompletion && generation != deliveryGeneration
            deliveryLock.unlock()
            if shouldClearLateCompletion { clearSystemNotifications() }
            return
        }
        activeDeliveryToken = nil
        deliveryLock.unlock()

        processNextDeliveryOperation()
    }

    private func clearSystemNotifications() {
        notificationClearer.removeAllDeliveredNotifications()
        notificationClearer.removeAllPendingNotificationRequests()
    }
}
