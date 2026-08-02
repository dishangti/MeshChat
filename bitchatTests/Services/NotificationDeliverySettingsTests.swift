// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import bitchat

struct NotificationDeliverySettingsTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "meshchat.tests.notification-delivery.\(UUID().uuidString)")!
    }

    @Test
    func freshInstallEnablesEveryTopic() {
        let defaults = isolatedDefaults()

        for topic in NotificationTopic.allCases {
            #expect(NotificationDeliverySettings.isEnabled(topic, in: defaults))
            #expect(NotificationDeliverySettings.allows(topic, in: defaults))
        }
    }

    @Test
    func topicsCanBeControlledIndependently() {
        let defaults = isolatedDefaults()

        NotificationDeliverySettings.setEnabled(false, for: .locationChannels, in: defaults)

        #expect(!NotificationDeliverySettings.allows(.locationChannels, in: defaults))
        #expect(NotificationDeliverySettings.allows(.directMessages, in: defaults))
        #expect(NotificationDeliverySettings.allows(.mesh, in: defaults))
        #expect(NotificationDeliverySettings.allows(.security, in: defaults))
    }

    @Test
    func aPauseSuppressesAllTopicsAndExpiresAtItsDeadline() {
        let defaults = isolatedDefaults()
        let now = Date(timeIntervalSince1970: 10_000)
        let deadline = now.addingTimeInterval(60)
        NotificationDeliverySettings.pause(until: deadline, in: defaults)

        for topic in NotificationTopic.allCases {
            #expect(!NotificationDeliverySettings.allows(topic, now: now, in: defaults))
        }
        for topic in NotificationTopic.allCases {
            #expect(NotificationDeliverySettings.allows(topic, now: deadline, in: defaults))
        }
        #expect(NotificationDeliverySettings.pausedUntil(in: defaults) == nil)
    }

    @Test
    func resetRestoresEnabledAndUnpausedDefaults() {
        let defaults = isolatedDefaults()
        NotificationDeliverySettings.setEnabled(false, for: .directMessages, in: defaults)
        NotificationDeliverySettings.pause(until: .distantFuture, in: defaults)

        NotificationDeliverySettings.reset(in: defaults)

        #expect(NotificationDeliverySettings.pausedUntil(in: defaults) == nil)
        for topic in NotificationTopic.allCases {
            #expect(NotificationDeliverySettings.allows(topic, in: defaults))
        }
    }
}
