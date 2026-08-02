// SPDX-License-Identifier: MIT

import Foundation

/// User-controlled classes of local alerts. These settings affect only system
/// notifications; messages continue to be received, stored, and counted.
enum NotificationTopic: String, CaseIterable, Identifiable, Sendable {
    case directMessages
    case locationChannels
    case mesh
    case security

    var id: String { rawValue }
}

/// Persistent notification policy with injectable storage and time for tests.
enum NotificationDeliverySettings {
    private static let keyPrefix = "notifications.topic."
    private static let pausedUntilKey = "notifications.pausedUntil"

    static func isEnabled(
        _ topic: NotificationTopic,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        let key = keyPrefix + topic.rawValue
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func setEnabled(
        _ enabled: Bool,
        for topic: NotificationTopic,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: keyPrefix + topic.rawValue)
    }

    static func pausedUntil(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: pausedUntilKey) as? Date
    }

    static func activePauseUntil(
        now: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> Date? {
        guard let deadline = pausedUntil(in: defaults) else { return nil }
        guard deadline > now else {
            defaults.removeObject(forKey: pausedUntilKey)
            return nil
        }
        return deadline
    }

    static func pause(
        until deadline: Date,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(deadline, forKey: pausedUntilKey)
    }

    static func resume(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pausedUntilKey)
    }

    static func allows(
        _ topic: NotificationTopic,
        now: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> Bool {
        activePauseUntil(now: now, in: defaults) == nil && isEnabled(topic, in: defaults)
    }

    /// Panic-wipe hook. A wiped app returns to the upgrade-compatible default
    /// where every topic is enabled and no pause deadline remains.
    static func reset(in defaults: UserDefaults = .standard) {
        for topic in NotificationTopic.allCases {
            defaults.removeObject(forKey: keyPrefix + topic.rawValue)
        }
        defaults.removeObject(forKey: pausedUntilKey)
    }
}
