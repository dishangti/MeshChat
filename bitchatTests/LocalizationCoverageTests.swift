import Testing
import Foundation

/// Guards against locale gaps in the string catalogs: every translatable key
/// must have a localization for every supported locale, so no user ever sees
/// an English fallback (see PR #1391 review).
struct LocalizationCoverageTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root

    private struct Catalog {
        /// key -> set of locales with a localization entry
        let coverage: [String: Set<String>]
        /// all locales appearing anywhere in the catalog
        var allLocales: Set<String> { coverage.values.reduce(into: []) { $0.formUnion($1) } }
    }

    private static func loadCatalog(_ relativePath: String) throws -> Catalog {
        let url = repoRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        var coverage: [String: Set<String>] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            var locales: Set<String> = []
            for (locale, loc) in localizations {
                guard let loc = loc as? [String: Any] else { continue }
                // A localization counts if it has a non-empty stringUnit value
                // or uses variations/substitutions (plural forms).
                if let unit = loc["stringUnit"] as? [String: Any],
                   let unitValue = unit["value"] as? String, !unitValue.isEmpty {
                    locales.insert(locale)
                } else if loc["variations"] != nil || loc["substitutions"] != nil {
                    locales.insert(locale)
                }
            }
            coverage[key] = locales
        }
        return Catalog(coverage: coverage)
    }

    @Test func mainCatalogCoversAllLocalesForEveryKey() throws {
        let catalog = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let expected = catalog.allLocales
        #expect(expected.count > 1, "catalog should declare more locales than the source language")
        for (key, locales) in catalog.coverage.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(locales).sorted()
            #expect(missing.isEmpty, "\(key) is missing locales: \(missing.joined(separator: ", "))")
        }
    }

    @Test func shareExtensionCatalogCoversAllLocalesForEveryKey() throws {
        let catalog = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let expected = catalog.allLocales
        for (key, locales) in catalog.coverage.sorted(by: { $0.key < $1.key }) {
            let missing = expected.subtracting(locales).sorted()
            #expect(missing.isEmpty, "\(key) is missing locales: \(missing.joined(separator: ", "))")
        }
    }

    @Test func shareExtensionSupportsSameLocalesAsMainApp() throws {
        let main = try Self.loadCatalog("bitchat/Localizable.xcstrings")
        let shareExt = try Self.loadCatalog("bitchatShareExtension/Localization/Localizable.xcstrings")
        let missing = main.allLocales.subtracting(shareExt.allLocales).sorted()
        #expect(missing.isEmpty, "share extension is missing locales: \(missing.joined(separator: ", "))")
    }

    @Test func notificationPermissionWarningCoversEveryLocaleWithoutFormatPlaceholders() throws {
        let url = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let expectedLocales = try Self.loadCatalog("bitchat/Localizable.xcstrings").allLocales
        let keys = [
            "app_info.settings.notifications.denied.title",
            "app_info.settings.notifications.denied.message",
            "app_info.settings.notifications.denied.open_settings"
        ]

        #expect(expectedLocales.count == 30)
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            #expect(Set(localizations.keys) == expectedLocales, "\(key) must cover all 30 locales")

            for (locale, localization) in localizations {
                let localization = try #require(localization as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let value = try #require(unit["value"] as? String)
                #expect(!value.contains("%"), "\(key) unexpectedly contains a format placeholder in \(locale)")
            }
        }
    }

    @Test func englishCoreLabelsAndFormatSpecifiersStayCanonical() throws {
        let url = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])

        let expectedValues = [
            "app_info.appearance.aurora": "Aurora",
            "app_info.appearance.matrix": "Matrix",
            "app_info.appearance.title": "Appearance",
            "app_info.settings.danger.panic_button": "Reset Identity & Wipe Data",
            "app_info.settings.danger.panic_confirm_action": "Reset Identity and Wipe",
            "app_info.settings.danger.panic_confirm_title": "Reset Identity and Wipe All Data?",
            "app_info.settings.danger.panic_note": "Creates new local Noise and signing keys by deleting all MeshChat data on this device, including chats, contacts, nicknames, verification and block records, groups, and media. Other devices keep your old messages and fingerprint; they will see the new identity as unverified. This cannot be undone. Triple-tapping the MeshChat logo performs the same wipe immediately.",
            "location_channels.sheet_title": "#location Channel",
            "content.accessibility.add_favorite": "Add Friend",
            "content.accessibility.remove_favorite": "Remove Friend",
            "content.clear.confirm_action": "Delete Chat History",
            "content.clear.confirm_title": "Delete Chat History?",
            "content.clear.confirm_message": "This deletes this chat's history from this device only. Identity settings are preserved.",
            "fingerprint.badge.not_verified": "Not verified",
            "fingerprint.badge.verified": "Verified",
            "fingerprint.local_alias.label": "Local Nickname",
            "friends.action.add": "Add Friend",
            "friends.remove.confirm_title": "Remove %@ from Friends?",
            "friends.remove.confirm_message": "Their chat history, local nickname, verification, and block setting will be preserved.",
            "mesh_peers.section.friends": "Friends",
            "mesh_peers.section.nearby": "Nearby",
            "mesh_peers.section.recent": "Recent",
            "recent_chat.delete.action": "Delete Chat",
            "recent_chat.delete.confirm_title": "Delete Chat with %@?",
            "recent_chat.delete.confirm_message": "This removes the chat from Recent and deletes its history from this device. Identity settings are preserved, and a new message may make the chat appear again.",
            "verification.qr.title": "QR Code",
            "verification.tabs.my_qr": "My QR",
            "verification.tabs.scan": "Scan",
            "verification.scan.status.invalid": "This QR code could not be verified.",
            "verification.scan.status.expired": "This QR code has expired or the devices' clocks differ. Ask the other person to reopen it, then scan again.",
            "fingerprint.action.mark_verified": "Verify Encryption",
            "notification.redacted.security.title": "Verify Encryption",
            "meshchat.help.title": "Help",
            "meshchat.help.open_hint": "Opens Help, Info, and Settings",
            "meshchat.help.introduction": "Learn how MeshChat connects, identifies people, delivers alerts, and protects your privacy.",
            "meshchat.help.chats.title": "Chats and Contacts",
            "meshchat.help.chats.description": "Use the conversation Actions menu to delete history or remove a friend. Press and hold or right-click a Recent row to Delete Chat. History deletion is local; Remove Friend keeps history, local nickname, verification, and block settings; Delete Chat removes the Recent entry and local history, keeps identity settings, and a new message may bring the chat back.",
            "meshchat.help.bridge.description": "Mesh Bridge connects nearby groups beyond Bluetooth range through the internet. With Bluetooth off, each device needs internet and location access, and both must be in the same or a neighboring approximate area. With Bluetooth available, a nearby bridge peer can supply the area instead.",
            "meshchat.help.recent.description": "Recent lists offline people you have privately chatted with but have not added as friends, newest conversation first. Tap a person to continue chatting.",
            "meshchat.help.friends.description": "Adding a friend is optional and separate from assigning a local nickname. You can nickname or block any known person; local nicknames stay only on this device.",
            "meshchat.help.qr.description": "Use the global scanner to recognize a MeshChat QR code. Scanning can find a person, but adding them as a friend and verifying their encryption are separate, optional actions.",
            "meshchat.help.verification.description": "Compare fingerprints or complete the Bitchat-compatible QR challenge over the live encrypted link. Gray means unverified; green means verified. Yellow means an attributable conflict was recorded for that exact key fingerprint, not its temporary peer ID. Normal traffic and reverification never clear it; an identity reset creates separate new keys that start gray.",
            "meshchat.help.notifications.description": "In Settings, choose alerts separately for private and group messages, mesh activity, #location channels, and security events. Pause all alerts temporarily or resume them at any time.",
            "meshchat.help.privacy.description": "Private text messages and private groups use end-to-end encryption. Before sending media to a legacy client that does not support encrypted private media, MeshChat warns that the file will not be end-to-end encrypted and asks for confirmation. Public mesh and #location channel messages are visible to participants. Keep Tor enabled to hide your IP address from internet relays.",
            "app_info.legend.encrypted": "Encrypted session; identity not verified",
            "app_info.legend.private_message": "Private message",
            "identity.status.mismatch": "Identity-key conflict recorded",
            "content.accessibility.bridged_count": "%lld more people across the bridge",
            "content.accessibility.notices_new": "%lld new"
        ]

        for (key, expectedValue) in expectedValues {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])
            let unit = try #require(english["stringUnit"] as? [String: Any])
            #expect(unit["value"] as? String == expectedValue)
        }
    }

    @Test func destructiveChatCopyCoversEveryLocaleAndPreservesNameFormats() throws {
        let url = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        #expect(strings["identity.warning.title"] == nil)
        #expect(strings["identity.warning.message"] == nil)
        let expectedLocales = try Self.loadCatalog(
            "bitchat/Localizable.xcstrings"
        ).allLocales
        let newKeys = [
            "content.clear.confirm_message",
            "friends.remove.confirm_title",
            "friends.remove.confirm_message",
            "recent_chat.delete.action",
            "recent_chat.delete.confirm_title",
            "recent_chat.delete.confirm_message",
            "meshchat.help.chats.title",
            "meshchat.help.chats.description"
        ]
        let formattedTitleKeys = Set([
            "friends.remove.confirm_title",
            "recent_chat.delete.confirm_title"
        ])

        #expect(expectedLocales.count == 30)
        for key in newKeys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(
                Set(localizations.keys) == expectedLocales,
                "\(key) must cover all 30 locales"
            )

            guard formattedTitleKeys.contains(key) else { continue }
            for (locale, localization) in localizations {
                let localization = try #require(
                    localization as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                let value = try #require(unit["value"] as? String)
                let placeholderCount = value
                    .components(separatedBy: "%@").count - 1
                #expect(
                    placeholderCount == 1,
                    "\(key) must contain exactly one %@ in \(locale)"
                )
            }
        }
    }

    @Test func identityConflictCopyCoversEveryLocale() throws {
        let url = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let expectedLocales = try Self.loadCatalog(
            "bitchat/Localizable.xcstrings"
        ).allLocales
        let keys = [
            "meshchat.help.verification.description",
            "identity.status.mismatch"
        ]

        #expect(expectedLocales.count == 30)
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(
                Set(localizations.keys) == expectedLocales,
                "\(key) must cover all 30 locales"
            )
        }
    }

    @Test func identityBadgeCopyUsesNaturalCaseWithoutEmbeddedGlyphs() throws {
        let url = Self.repoRoot.appendingPathComponent("bitchat/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let expectedLocales = try Self.loadCatalog(
            "bitchat/Localizable.xcstrings"
        ).allLocales
        let casedLocales: Set<String> = [
            "de", "en", "es", "fil", "fr", "id", "it", "ms", "nl",
            "pl", "pt", "pt-BR", "ru", "sv", "tr", "uk", "vi"
        ]

        for key in [
            "fingerprint.badge.not_verified",
            "fingerprint.badge.verified"
        ] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == expectedLocales)

            for (locale, localization) in localizations {
                let localization = try #require(
                    localization as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                let value = try #require(unit["value"] as? String)
                #expect(!value.contains("✓"), "\(key) embeds a checkmark in \(locale)")
                #expect(!value.contains("⚠"), "\(key) embeds a warning icon in \(locale)")
                if casedLocales.contains(locale) {
                    #expect(
                        value != value.uppercased(),
                        "\(key) uses all caps in \(locale)"
                    )
                }
            }
        }
    }
}
