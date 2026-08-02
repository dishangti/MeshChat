import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct AppURLRoutingTests {
    @Test
    func canonicalAndAliasGeohashLinksRouteFromAnyScreen() throws {
        let canonical = try #require(URL(string: "bitchat://geohash/U4PRUY"))
        let alias = try #require(URL(string: "meshchat://geohash/u4pruy"))

        #expect(ChatURLScheme.route(for: canonical) == .geohash("u4pruy"))
        #expect(ChatURLScheme.route(for: alias) == .geohash("u4pruy"))
        // Repeating an already-selected destination remains an explicit route
        // intent, allowing the root to reveal it from Home.
        #expect(ChatURLScheme.route(for: canonical) == .geohash("u4pruy"))
    }

    @Test
    func invalidGeohashLinksAreRejectedBeforeNavigation() throws {
        let invalidCharacter = try #require(URL(string: "bitchat://geohash/u4p!"))
        let tooShort = try #require(URL(string: "bitchat://geohash/u"))

        #expect(ChatURLScheme.route(for: invalidCharacter) == nil)
        #expect(ChatURLScheme.route(for: tooShort) == nil)
    }

    @Test
    func userAndVerificationLinksSurviveCanonicalParsing() throws {
        let user = try #require(URL(string: "bitchat://user/aabbccdd00112233"))
        let verification = try #require(URL(string: "bitchat://verify?v=1&noise=aa"))

        #expect(ChatURLScheme.route(for: user) == .user(PeerID(str: "aabbccdd00112233")))
        #expect(ChatURLScheme.route(for: verification) == .verification(verification.absoluteString))
    }

    @Test
    func homeDoesNotSuppressRetainedChannelOrPrivateNotifications() {
        let geohashInfo: [AnyHashable: Any] = [
            "deeplink": "bitchat://geohash/u4pruy"
        ]
        let directInfo: [AnyHashable: Any] = [
            "peerID": "aabbccdd00112233"
        ]

        #expect(!AppNotificationVisibilityPolicy.shouldSuppress(
            identifier: "geo-activity-u4pruy-1",
            userInfo: geohashInfo,
            visibleConversation: nil
        ))
        #expect(AppNotificationVisibilityPolicy.shouldSuppress(
            identifier: "geo-activity-u4pruy-1",
            userInfo: geohashInfo,
            visibleConversation: .geohash("u4pruy")
        ))
        #expect(!AppNotificationVisibilityPolicy.shouldSuppress(
            identifier: "private-1",
            userInfo: directInfo,
            visibleConversation: nil
        ))
        #expect(AppNotificationVisibilityPolicy.shouldSuppress(
            identifier: "private-1",
            userInfo: directInfo,
            visibleConversation: .direct(PeerID(str: "aabbccdd00112233"))
        ))
    }

    @Test @MainActor
    func pendingDirectRouteSurvivesColdLaunchUntilTheRootConsumesIt() {
        let routes = AppRouteModel()
        let peerID = PeerID(str: "aabbccdd00112233")

        routes.enqueue(.user(peerID))
        #expect(routes.pendingURLRoute == .user(peerID))

        routes.consume(.user(peerID))
        #expect(routes.pendingURLRoute == nil)
    }
}
