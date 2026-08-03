import XCTest
import UserNotifications
import BitFoundation
import Foundation
@testable import bitchat

final class NotificationServiceTests: XCTestCase {
    func test_requestAuthorization_skipsWhenRunningTests() {
        let authorizer = RecordingNotificationAuthorizer()
        let service = NotificationService(
            isRunningTestsProvider: { true },
            authorizer: authorizer,
            requestDeliverer: RecordingNotificationRequestDeliverer()
        )

        service.requestAuthorization()

        XCTAssertEqual(authorizer.requestCallCount, 0)
    }

    func test_requestAuthorization_requestsAlertSoundAndBadgePermissions() {
        let authorizer = RecordingNotificationAuthorizer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: authorizer,
            requestDeliverer: RecordingNotificationRequestDeliverer()
        )

        service.requestAuthorization()

        XCTAssertEqual(authorizer.requestCallCount, 1)
        XCTAssertEqual(authorizer.lastOptions, [.alert, .sound, .badge])
    }

    func test_sendLocalNotification_buildsImmediateRequestWithUserInfo() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer
        )

        service.sendLocalNotification(
            title: "Hello",
            body: "World",
            identifier: "custom-id",
            topic: .security,
            userInfo: ["peerID": "abcd"],
            interruptionLevel: .timeSensitive
        )

        let request = deliverer.requests.singleValue
        XCTAssertEqual(request?.identifier, "custom-id")
        XCTAssertEqual(request?.content.title, "Hello")
        XCTAssertEqual(request?.content.body, "World")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, "abcd")
        XCTAssertEqual(request?.content.interruptionLevel, .timeSensitive)
        XCTAssertNil(request?.trigger)
    }

    /// Previews shown: the opt-in behavior. Stated explicitly rather than
    /// inherited from the shared preference, which now defaults to hidden.
    func test_sendPrivateMessageNotification_populatesPeerMetadata() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { false }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = deliverer.requests.singleValue
        XCTAssertEqual(request?.content.title, "🔒 DM from Alice")
        XCTAssertEqual(request?.content.body, "hi")
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
        XCTAssertEqual(request?.content.userInfo["senderName"] as? String, "Alice")
    }

    /// Previews hidden: the default. The routing payload has to survive
    /// redaction, or tapping the alert would not open the conversation.
    func test_sendPrivateMessageNotification_withPreviewsHidden_keepsRoutingButDropsContent() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { true }
        )
        let peerID = PeerID(str: "deadbeefdeadbeef")

        service.sendPrivateMessageNotification(from: "Alice", message: "hi", peerID: peerID)

        let request = deliverer.requests.singleValue
        XCTAssertFalse(request?.content.title.contains("Alice") ?? true)
        XCTAssertFalse(request?.content.body.contains("hi") ?? true)
        XCTAssertFalse(request?.content.title.isEmpty ?? true)
        XCTAssertEqual(request?.content.userInfo["peerID"] as? String, peerID.id)
    }

    func test_wrapperNotifications_setExpectedIdentifiersAndDeepLinks() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer
        )

        service.sendGeohashActivityNotification(geohash: "87yv", bodyPreview: "Someone is here")
        service.sendNetworkAvailableNotification(peerCount: 2)

        XCTAssertEqual(deliverer.requests.count, 2)
        XCTAssertEqual(deliverer.requests[0].content.userInfo["deeplink"] as? String, "bitchat://geohash/87yv")
        XCTAssertTrue(deliverer.requests[0].identifier.hasPrefix("geo-activity-87yv-"))
        XCTAssertEqual(deliverer.requests[1].identifier, "network-available")
        XCTAssertEqual(deliverer.requests[1].content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(deliverer.requests[1].content.body, "2 people around")
    }

    func test_visibleMentionAndNearbyNotifications_useLocalizedCopy() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { false }
        )

        service.sendMentionNotification(from: "Alice", message: "hello", topic: .mesh)
        service.sendNetworkAvailableNotification(peerCount: 1)
        service.sendNetworkAvailableNotification(peerCount: 3)

        XCTAssertEqual(deliverer.requests.count, 3)
        XCTAssertEqual(deliverer.requests[0].content.title, "🫵 You were mentioned by Alice")
        XCTAssertEqual(deliverer.requests[1].content.title, "👥 MeshChat users nearby!")
        XCTAssertEqual(deliverer.requests[1].content.body, "1 person around")
        XCTAssertEqual(deliverer.requests[2].content.body, "3 people around")
    }

    func test_nearbyNotification_removesOnlyItselfAfterItsLifetime() {
        let clearer = RecordingNotificationClearer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: RecordingNotificationRequestDeliverer(),
            notificationClearer: clearer,
            nearbyNotificationLifetime: 0.02
        )

        service.sendNetworkAvailableNotification(peerCount: 2)

        XCTAssertEqual(
            clearer.targetedRemoval.wait(
                timeout: .now() + TestConstants.settleTimeout
            ),
            .success
        )
        XCTAssertEqual(clearer.deliveredIdentifiers, [["network-available"]])
        XCTAssertEqual(clearer.pendingIdentifiers, [["network-available"]])
        XCTAssertEqual(clearer.deliveredClearCount, 0)
        XCTAssertEqual(clearer.pendingClearCount, 0)
    }

    func test_topicPolicy_suppressesOnlyTheDisabledTopic() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            notificationPolicyProvider: { $0 != .mesh }
        )

        service.sendNetworkAvailableNotification(peerCount: 2)
        service.sendPrivateMessageNotification(
            from: "Alice",
            message: "hello",
            peerID: PeerID(str: "deadbeefdeadbeef")
        )

        XCTAssertEqual(deliverer.requests.count, 1)
        XCTAssertTrue(deliverer.requests[0].identifier.hasPrefix("private-"))
    }

    func test_securityNotification_honorsPreviewRedaction() {
        let deliverer = RecordingNotificationRequestDeliverer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: deliverer,
            hidePreviewsProvider: { true }
        )

        service.sendSecurityNotification(
            title: "Mutual verification",
            body: "You and Alice verified each other",
            identifier: "verify-test"
        )

        let content = deliverer.requests.singleValue?.content
        XCTAssertEqual(content?.title, "Verify Encryption")
        XCTAssertFalse(content?.title.contains("Alice") ?? true)
        XCTAssertFalse(content?.body.contains("Alice") ?? true)
    }

    func test_clearAllNotifications_clearsDeliveredAndPendingRequests() {
        let clearer = RecordingNotificationClearer()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: RecordingNotificationRequestDeliverer(),
            notificationClearer: clearer
        )

        service.clearAllNotifications()

        XCTAssertEqual(clearer.deliveredClearCount, 1)
        XCTAssertEqual(clearer.pendingClearCount, 1)
    }

    func test_clearAllNotifications_serializesAgainstAnInFlightEnqueue() {
        let center = BlockingNotificationCenter()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: center,
            notificationClearer: center
        )
        let sendFinished = expectation(description: "send finished")
        let clearAttempted = DispatchSemaphore(value: 0)
        let clearEnqueued = expectation(description: "clear enqueued")

        DispatchQueue.global().async {
            service.sendLocalNotification(
                title: "Sensitive sender",
                body: "Sensitive body",
                identifier: "in-flight",
                topic: .directMessages
            )
            sendFinished.fulfill()
        }
        XCTAssertEqual(center.addStarted.wait(timeout: .now() + 1), .success)

        // This request is queued behind the blocked add. Clear must release
        // it immediately without ever handing its plaintext to the center.
        service.sendLocalNotification(
            title: "Queued sensitive sender",
            body: "Queued sensitive body",
            identifier: "queued-sensitive",
            topic: .directMessages
        )

        DispatchQueue.global().async {
            clearAttempted.signal()
            service.clearAllNotifications()
            clearEnqueued.fulfill()
        }
        XCTAssertEqual(clearAttempted.wait(timeout: .now() + 1), .success)

        // Panic/pause clears immediately even while the system add is in
        // flight, and releases every queued request body synchronously.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(center.pendingClearCount, 1)

        center.releaseAdd.signal()
        wait(for: [sendFinished, clearEnqueued], timeout: TestConstants.settleTimeout)
        XCTAssertEqual(center.clearCompleted.wait(timeout: .now() + 1), .success)

        // The completion-aware barrier clears again after the late add.
        XCTAssertEqual(center.pendingClearCount, 2)
        XCTAssertEqual(center.addCallCount, 1)
        XCTAssertTrue(center.requests.isEmpty)
    }

    func test_clearAllNotifications_hasBoundedFallbackWhenAddNeverCompletes() {
        let center = StalledNotificationCenter()
        let service = NotificationService(
            isRunningTestsProvider: { false },
            authorizer: RecordingNotificationAuthorizer(),
            requestDeliverer: center,
            notificationClearer: center,
            deliveryCompletionTimeout: 0.02
        )

        service.sendLocalNotification(
            title: "Sensitive sender",
            body: "Sensitive body",
            identifier: "stalled",
            topic: .directMessages
        )
        service.clearAllNotifications()

        XCTAssertEqual(center.pendingClearCount, 1)
        XCTAssertEqual(center.secondClear.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(center.pendingClearCount, 2)
    }
}

private final class RecordingNotificationAuthorizer: NotificationAuthorizing {
    private(set) var requestCallCount = 0
    private(set) var lastOptions: UNAuthorizationOptions?

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        requestCallCount += 1
        lastOptions = options
        completionHandler(true, nil)
    }
}

private final class RecordingNotificationRequestDeliverer: NotificationRequestDelivering {
    private(set) var requests: [UNNotificationRequest] = []

    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void) {
        requests.append(request)
        completionHandler()
    }
}

private final class RecordingNotificationClearer: NotificationClearing {
    private(set) var deliveredClearCount = 0
    private(set) var pendingClearCount = 0
    private(set) var deliveredIdentifiers: [[String]] = []
    private(set) var pendingIdentifiers: [[String]] = []
    let targetedRemoval = DispatchSemaphore(value: 0)

    func removeAllDeliveredNotifications() {
        deliveredClearCount += 1
    }

    func removeAllPendingNotificationRequests() {
        pendingClearCount += 1
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredIdentifiers.append(identifiers)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pendingIdentifiers.append(identifiers)
        targetedRemoval.signal()
    }
}

private final class BlockingNotificationCenter: NotificationRequestDelivering, NotificationClearing {
    let addStarted = DispatchSemaphore(value: 0)
    let releaseAdd = DispatchSemaphore(value: 0)
    let clearCompleted = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedRequests: [UNNotificationRequest] = []
    private var storedPendingClearCount = 0
    private var storedAddCallCount = 0

    var requests: [UNNotificationRequest] {
        lock.withLock { storedRequests }
    }

    var pendingClearCount: Int {
        lock.withLock { storedPendingClearCount }
    }

    var addCallCount: Int {
        lock.withLock { storedAddCallCount }
    }

    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void) {
        lock.withLock { storedAddCallCount += 1 }
        addStarted.signal()
        releaseAdd.wait()
        lock.withLock {
            storedRequests.append(request)
        }
        completionHandler()
    }

    func removeAllDeliveredNotifications() {}

    func removeAllPendingNotificationRequests() {
        lock.withLock {
            storedPendingClearCount += 1
            storedRequests.removeAll()
        }
        clearCompleted.signal()
    }
}

private final class StalledNotificationCenter: NotificationRequestDelivering, NotificationClearing {
    let secondClear = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedPendingClearCount = 0

    var pendingClearCount: Int {
        lock.withLock { storedPendingClearCount }
    }

    func add(_ request: UNNotificationRequest, completionHandler: @escaping () -> Void) {
        // Intentionally never completes, simulating a suspended or wedged
        // notification-center callback.
    }

    func removeAllDeliveredNotifications() {}

    func removeAllPendingNotificationRequests() {
        let count = lock.withLock { () -> Int in
            storedPendingClearCount += 1
            return storedPendingClearCount
        }
        if count == 2 { secondClear.signal() }
    }
}

private extension Array {
    var singleValue: Element? {
        count == 1 ? self[0] : nil
    }
}
