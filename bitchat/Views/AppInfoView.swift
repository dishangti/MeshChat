import SwiftUI
import UserNotifications

enum AppInfoPane: String {
    static let storageKey = "appInfo.selectedPane"
    case settings
    case info
    case help
}

private enum BlockedPeopleStrings {
    static var title: String {
        AppLanguageSettings.localized(
         "app_info.settings.blocked.title",
        defaultValue: "Blocked People",
        comment: "Title of the settings destination listing people blocked by the user"
        )
    }
}

/// The sheet behind the MeshChat logo: a segmented Help/Info/Settings surface.
/// Help is task-oriented guidance, Info is product metadata and diagnostics,
/// and Settings gathers preferences and destructive controls.
struct AppInfoView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ThemedPalette private var palette
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.defaultTheme.rawValue
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @ObservedObject private var bridgeService = BridgeService.shared

    /// Supplies the mesh topology map data. Nil (previews, missing wiring)
    /// hides the topology row entirely.
    var topologyProvider: (@MainActor () -> MeshTopologyDisplayModel)?
    /// Destructive actions are supplied independently so resetting identity
    /// never implicitly erases user data, and erasing data can retain keys.
    var onResetIdentity: (@MainActor () -> Void)?
    var onEraseData: (@MainActor () -> Void)?
    /// Secure identity data stays behind the app model; Settings receives only
    /// presentation rows and an explicit unblock intent.
    var blockedPeopleProvider: (@MainActor () -> [BlockedPersonRow])?
    var onUnblockPerson: (@MainActor (BlockedPersonRow) -> Void)?
    /// Injectable because Swift Package view tests do not run inside an app
    /// bundle, where `UNUserNotificationCenter.current()` is unavailable.
    var notificationAuthorizationProvider: (@escaping (UNAuthorizationStatus) -> Void) -> Void = { completion in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    @State private var showTopology = false
    @State private var liveVoiceEnabled = PTTSettings.liveVoiceEnabled
    @State private var locationNotesEnabled = LocationNotesSettings.enabled
    @State private var proofOfWorkEnabled = NostrPoWSettings.enabled
    @State private var hideMessagePreviews = NotificationPrivacySettings.hideMessagePreviews
    @State private var directMessageNotifications = NotificationDeliverySettings.isEnabled(.directMessages)
    @State private var locationNotifications = NotificationDeliverySettings.isEnabled(.locationChannels)
    @State private var meshNotifications = NotificationDeliverySettings.isEnabled(.mesh)
    @State private var securityNotifications = NotificationDeliverySettings.isEnabled(.security)
    @State private var notificationPauseUntil = NotificationDeliverySettings.activePauseUntil()
    @State private var notificationPauseTask: Task<Void, Never>?
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus?
    @State private var blockedPeople: [BlockedPersonRow] = []
    @State private var showBlockedPeople = false
    @State private var customRelays = NostrRelaySettings.customRelays()
    @State private var relayInput = ""
    @State private var relayError: String?
    @State private var outerProxyDraft = OuterProxySettings.loadDraft()
    @State private var outerProxyStatus: String?
    @State private var outerProxyStatusIsError = false
    #if os(macOS)
    @State private var detectedSystemProxy = OuterProxySettings.systemProxyDescription()
    #endif
    @ObservedObject private var locationManager = LocationChannelManager.shared
    /// The presenting entry point chooses Help (app logo) or Settings (gear)
    /// by writing this shared selection before the sheet appears. Info remains
    /// available from the segmented control.
    @AppStorage(AppInfoPane.storageKey) private var selectedPane: AppInfoPane = .help
    @State private var showIdentityResetConfirmation = false
    @State private var showDataEraseConfirmation = false
    @AppStorage(AppLanguageSettings.overrideKey) private var languageOverride = ""

    private var selectedTheme: AppTheme {
        AppTheme.resolve(appThemeRawValue)
    }

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return "v\(version) (\(build))"
        case let (.some(version), .none):
            return "v\(version)"
        case let (.none, .some(build)):
            return build
        case (.none, .none):
            return "MeshChat"
        }
    }

    // MARK: - Constants
    private enum Strings {
        static let appName: LocalizedStringKey = "app_info.app_name"
        static let tagline: LocalizedStringKey = "app_info.tagline"
        static let aboutDescription: LocalizedStringKey = "app_info.about.description"
        static let appearanceTitle: LocalizedStringKey = "app_info.appearance.title"

        /// New keys carry their English copy inline (defaultValue) until the
        /// i18n pass lands them in the catalog; moved keys keep their homes.
        enum Settings {
            static var tabPickerLabel: String { AppLanguageSettings.localized("app_info.tab.picker_label", defaultValue: "View", comment: "Accessibility label for the segmented control switching between the Help, Info, and Settings panes") }
            static var tabSettings: String { AppLanguageSettings.localized("app_info.tab.settings", defaultValue: "Settings", comment: "Segmented control label for the settings pane of the app info sheet") }
            static var tabInfo: String { AppLanguageSettings.localized("app_info.tab.info", defaultValue: "Info", comment: "Segmented control label for the info pane of the app info sheet") }
            static var tabHelp: String { AppLanguageSettings.localized("meshchat.help.title", defaultValue: "Help", comment: "Segmented control label for the standalone MeshChat help page") }

            static var connectivityTitle: String { AppLanguageSettings.localized("app_info.settings.connectivity.title", defaultValue: "Connectivity", comment: "Section header for settings that control mesh bridging, Tor routing, relays, proof-of-work, and location features") }

            static var languageTitle: String { AppLanguageSettings.localized("app_info.settings.language.title", defaultValue: "Language", comment: "Section header for the app language picker in settings") }
            static var languagePickerLabel: String { AppLanguageSettings.localized("app_info.settings.language.picker_label", defaultValue: "App Language", comment: "Label of the app language picker row in settings") }
            static var languageSystem: String { AppLanguageSettings.localized("app_info.settings.language.system", defaultValue: "System Default", comment: "Menu option that clears the in-app language override so the app follows the device language") }

            static var bridgeTitle: String { AppLanguageSettings.localized("app_info.settings.bridge.title", defaultValue: "Mesh Bridge", comment: "Title of the mesh bridge toggle in settings") }
            static var bridgeSubtitle: String { AppLanguageSettings.localized("app_info.settings.bridge.subtitle", defaultValue: "Joins nearby mesh islands over the internet: what you say in the mesh channel also reaches people in your area beyond radio range, and their messages appear here marked with the network glyph. While you have internet, your device also carries bridge and location-channel traffic for phones around you that have none.", comment: "Subtitle explaining what the mesh bridge toggle does") }
            static func bridgeCell(_ cell: String) -> String {
                String(
                    format: AppLanguageSettings.localized("app_info.settings.bridge.cell", defaultValue: "Rendezvous cell: %@", comment: "Caption under the mesh bridge toggle showing the geohash cell the bridge is meeting on"),
                    locale: .current,
                    cell
                )
            }
            static var bridgeNoCell: String { AppLanguageSettings.localized("app_info.settings.bridge.no_cell", defaultValue: "No rendezvous cell yet — needs location access or a nearby bridge peer.", comment: "Caption under the mesh bridge toggle when the bridge is on but has no geohash cell to meet on") }

            // Moved from LocationChannelsSheet; keys unchanged. (The former
            // internet-gateway toggle is gone: the bridge switch drives all
            // internet sharing, including geohash-channel gatewaying.)
            static let torTitle: LocalizedStringKey = "location_channels.tor.title"
            // Replaces `location_channels.tor.subtitle`, which described the
            // setting as location-channels-only. It covers private messages and
            // relay-directory refreshes too, and said nothing about the cost of
            // switching it off.
            static var torSubtitle: String { AppLanguageSettings.localized("app_info.settings.tor.subtitle", defaultValue: "Sends internet traffic through Tor, so relay operators see Tor's address instead of yours. Covers location channels and private messages delivered over the internet. Recommended: on.", comment: "Subtitle for the Tor routing toggle in settings, explaining what it covers") }
            static var torOffWarning: String { AppLanguageSettings.localized("app_info.settings.tor.off_warning", defaultValue: "Tor is off: every relay you connect to can see your IP address, including relays carrying your private messages.", comment: "Warning shown under the Tor toggle while Tor is switched off, stating that relay operators can see the device IP address") }

            static var outerProxyTitle: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.title", defaultValue: "Outer Proxy", comment: "Title of the proxy configuration card") }
            static var outerProxySubtitle: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.subtitle_apple", defaultValue: "Routes relay traffic through system routing or a custom proxy. The path is Proxy → optional Tor → relay, so turning Tor on still keeps this proxy on the outside.", comment: "Description of how the outer proxy and optional Tor routing are ordered") }
            static var proxyCustom: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.custom", defaultValue: "Custom", comment: "Proxy mode configured separately inside MeshChat") }
            static var proxyDetected: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.detected", defaultValue: "Detected: %@", comment: "Status showing the static proxy detected in macOS settings; placeholder is the proxy description") }
            static var proxyNotDetected: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.not_detected", defaultValue: "No static system proxy detected. Direct connections still follow macOS, while Tor connects directly unless a Custom proxy is configured.", comment: "Status shown when macOS has no static HTTP or SOCKS proxy available for the embedded Tor client") }
            static var proxyIOSSystem: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.ios_system", defaultValue: "System Default follows iOS network routing. An active VPN already carries MeshChat and Tor traffic; choose Custom only for a separate HTTP or SOCKS5 proxy.", comment: "Explanation of system proxy behavior on iOS and iPadOS") }
            static var proxyType: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.type", defaultValue: "Type", comment: "Label for the custom proxy protocol picker") }
            static var proxyHost: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.host", defaultValue: "Host", comment: "Label for the custom proxy host field") }
            static var proxyPort: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.port", defaultValue: "Port", comment: "Label for the custom proxy port field") }
            static var proxyUsername: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.username", defaultValue: "Username (Optional)", comment: "Label for the optional custom proxy username field") }
            static var proxyPassword: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.password", defaultValue: "Password (Optional)", comment: "Label for the optional custom proxy password field") }
            static var proxyCredentialNote: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.credentials_note", defaultValue: "Proxy credentials authenticate the outer hop and are stored in Keychain. They do not replace Tor or message encryption.", comment: "Security note below custom proxy credential fields") }
            static var proxyApply: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.apply", defaultValue: "Apply Proxy", comment: "Button that saves and applies proxy settings") }
            static var proxyApplied: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.applied", defaultValue: "Proxy settings applied. Active relay connections are reconnecting.", comment: "Success status after applying proxy settings") }
            static var proxyErrorSettings: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.error.settings", defaultValue: "Check the proxy host and enter a port from 1 to 65535.", comment: "Validation error for an invalid custom proxy host or port") }
            static var proxyErrorCredentials: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.error.credentials", defaultValue: "Enter both a username and password, or leave both empty.", comment: "Validation error for incomplete custom proxy credentials") }
            static var proxyErrorSave: String { AppLanguageSettings.localized("app_info.settings.outer_proxy.error.save", defaultValue: "The proxy password could not be saved to Keychain.", comment: "Error shown when saving the proxy password fails") }
            static var proofOfWorkTitle: String { AppLanguageSettings.localized("app_info.settings.proof_of_work.title", defaultValue: "Proof of Work", comment: "Title of the toggle that controls NIP-13 proof-of-work on outgoing location-channel messages") }
            static var proofOfWorkSubtitle: String { AppLanguageSettings.localized("app_info.settings.proof_of_work.subtitle", defaultValue: "Adds a small computational cost to outgoing #location messages to reduce spam and qualify for less restrictive sender rate limits. BitChat enables this by default.", comment: "Subtitle explaining the effect and default of the outgoing location-channel proof-of-work toggle") }

            static var relaysTitle: String { AppLanguageSettings.localized("app_info.settings.relays.title", defaultValue: "Private Message Relays", comment: "Title of the relay list editor in settings") }
            static var relaysSubtitle: String { AppLanguageSettings.localized("app_info.settings.relays.subtitle", defaultValue: "When the mesh can't reach someone, private messages travel through these relays. The built-in ones are well-known addresses that a network filter can block, so you can add your own — including .onion addresses.", comment: "Subtitle explaining what the relay list is for and why someone would add a relay") }
            static var relayBuiltIn: String { AppLanguageSettings.localized("app_info.settings.relays.built_in", defaultValue: "Built-in", comment: "Label marking a relay as one of the built-in relays, which cannot be removed") }
            static var relayPlaceholder: String { AppLanguageSettings.localized("app_info.settings.relays.placeholder", defaultValue: "wss://relay.example.com", comment: "Placeholder text in the field for adding a relay address") }
            static var relayAdd: String { AppLanguageSettings.localized("app_info.settings.relays.add", defaultValue: "Add", comment: "Button that adds the typed relay address to the list") }
            static var relayRemove: String { AppLanguageSettings.localized("app_info.settings.relays.remove", defaultValue: "Remove Relay", comment: "Accessibility label for the button that removes an added relay") }

            static func relayError(_ failure: NostrRelaySettings.AddFailure) -> String {
                switch failure {
                case .malformed:
                    return AppLanguageSettings.localized("app_info.settings.relays.error.malformed", defaultValue: "That doesn't look like a relay address. Try wss://host.", comment: "Error shown when a typed relay address cannot be parsed")
                case .alreadyPresent:
                    return AppLanguageSettings.localized("app_info.settings.relays.error.duplicate", defaultValue: "That relay is already in the list.", comment: "Error shown when the typed relay address is already in the list")
                case .limitReached:
                    return String(
                        format: AppLanguageSettings.localized("app_info.settings.relays.error.limit", defaultValue: "You can add up to %d relays.", comment: "Error shown when the relay list is already at its maximum size; %d is that maximum"),
                        locale: .current,
                        NostrRelaySettings.maxCustomRelays
                    )
                }
            }
            static let toggleOn: LocalizedStringKey = "common.toggle.on"
            static let toggleOff: LocalizedStringKey = "common.toggle.off"

            static var privacyTitle: String { AppLanguageSettings.localized("app_info.settings.privacy.title", defaultValue: "Privacy", comment: "Section header for privacy settings such as hiding notification previews") }
            static var hidePreviewsTitle: String { AppLanguageSettings.localized("app_info.settings.hide_previews.title", defaultValue: "Hide Message Previews", comment: "Title of the setting that keeps message text, sender names, and geohashes out of lock-screen notifications") }
            static var hidePreviewsSubtitle: String { AppLanguageSettings.localized("app_info.settings.hide_previews.subtitle", defaultValue: "Notifications say that something arrived without showing the message, who sent it, or which location channel it came from. Anyone holding your locked phone learns nothing from the lock screen. On by default.", comment: "Subtitle explaining what hiding notification message previews does") }

            static var notificationsTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.title", defaultValue: "Notifications", comment: "Section header for notification delivery preferences") }
            static var notificationsDeniedTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.denied.title", defaultValue: "Notifications Are Off in System Settings", comment: "Title of the warning shown when system notification permission has been denied") }
            static var notificationsDeniedMessage: String { AppLanguageSettings.localized("app_info.settings.notifications.denied.message", defaultValue: "MeshChat cannot show alerts until notifications are allowed in System Settings. Your choices below will take effect when permission is restored.", comment: "Explanation shown when system notification permission has been denied") }
            static var notificationsDeniedOpenSettings: String { AppLanguageSettings.localized("app_info.settings.notifications.denied.open_settings", defaultValue: "Open System Settings", comment: "Button opening this app's notification permission in system settings") }
            static var pauseAllNotifications: String { AppLanguageSettings.localized("app_info.settings.notifications.pause_all", defaultValue: "Pause All Notifications", comment: "Menu label for temporarily pausing every local notification") }
            static var resumeNotifications: String { AppLanguageSettings.localized("app_info.settings.notifications.resume", defaultValue: "Resume Notifications", comment: "Button that ends a temporary notification pause") }
            static var pausedUntil: String { AppLanguageSettings.localized("app_info.settings.notifications.paused_until", defaultValue: "Paused until %@", comment: "Status text showing when notifications will automatically resume; parameter is a localized date and time") }
            static var pauseOneHour: String { AppLanguageSettings.localized("app_info.settings.notifications.pause.1_hour", defaultValue: "1 hour", comment: "Notification pause duration of one hour") }
            static var pauseEightHours: String { AppLanguageSettings.localized("app_info.settings.notifications.pause.8_hours", defaultValue: "8 hours", comment: "Notification pause duration of eight hours") }
            static var pauseOneDay: String { AppLanguageSettings.localized("app_info.settings.notifications.pause.24_hours", defaultValue: "24 hours", comment: "Notification pause duration of twenty-four hours") }
            static var pauseOneWeek: String { AppLanguageSettings.localized("app_info.settings.notifications.pause.1_week", defaultValue: "1 week", comment: "Notification pause duration of one week") }
            static var directNotificationsTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.direct.title", defaultValue: "Private Messages & Groups", comment: "Notification topic for direct and private group conversations") }
            static var directNotificationsSubtitle: String { AppLanguageSettings.localized("app_info.settings.notifications.direct.subtitle", defaultValue: "Direct and group conversation alerts", comment: "Description of the private-message notification topic") }
            static var meshNotificationsTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.mesh.title", defaultValue: "Mesh Activity", comment: "Notification topic for nearby mesh activity") }
            static var meshNotificationsSubtitle: String { AppLanguageSettings.localized("app_info.settings.notifications.mesh.subtitle", defaultValue: "Nearby peers and mesh events", comment: "Description of the mesh notification topic") }
            static var locationNotificationsTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.location.title", defaultValue: "#location Channels", comment: "Notification topic for location channels") }
            static var locationNotificationsSubtitle: String { AppLanguageSettings.localized("app_info.settings.notifications.location.subtitle", defaultValue: "Messages from joined #location channels", comment: "Description of the location-channel notification topic") }
            static var securityNotificationsTitle: String { AppLanguageSettings.localized("app_info.settings.notifications.security.title", defaultValue: "Security & Verification", comment: "Notification topic for encryption and verification events") }
            static var securityNotificationsSubtitle: String { AppLanguageSettings.localized("app_info.settings.notifications.security.subtitle", defaultValue: "Encryption and verification alerts", comment: "Description of the security notification topic") }

            static var dangerTitle: String { AppLanguageSettings.localized("app_info.settings.danger.title", defaultValue: "Danger Zone", comment: "Section header for destructive actions in settings") }
            static var identityResetButton: String { AppLanguageSettings.localized("app_info.settings.danger.identity_reset_button", defaultValue: "Reset Identity", comment: "Button that rotates local communications identity keys without deleting retained user data") }
            static var identityResetNote: String { AppLanguageSettings.localized("app_info.settings.danger.identity_reset_note", defaultValue: "Creates new Mesh, signing, and Nostr keys. Chats, media, contacts, nicknames, blocks, and settings stay. Private groups and queued messages are removed because they use the old keys. Other devices will see you as unverified. This cannot be undone.", comment: "Warning for identity reset explaining retained data, identity-bound removals, and what remote peers retain") }
            static var eraseDataButton: String { AppLanguageSettings.localized("app_info.settings.danger.erase_button", defaultValue: "Erase Data", comment: "Button that erases local user data while retaining communications identity keys") }
            static var eraseDataNote: String { AppLanguageSettings.localized("app_info.settings.danger.erase_note", defaultValue: "Deletes chats, media, contacts, nicknames, verification and block records, groups, location history, queued messages, and notification and relay settings. Your identity keys and nickname stay, so your fingerprint does not change. This cannot be undone. Triple-tapping the MeshChat logo also resets identity.", comment: "Warning for local data erasure explaining retained identity keys and the separate emergency wipe") }
        }

        enum Voice {
            static let title: LocalizedStringKey = "app_info.voice.title"
            // The live-voice title/description keys are referenced inline at
            // the toggle (they ride the shared settingToggle now).
        }

        enum Location {
            static let notes = AppInfoFeatureInfo(
                icon: "mappin.and.ellipse",
                title: "app_info.location.notes.title",
                description: "app_info.location.notes.description"
            )
        }

        enum Network {
            static let title: LocalizedStringKey = "app_info.network.title"
            static let topology = AppInfoFeatureInfo(
                icon: "point.3.connected.trianglepath.dotted",
                title: "app_info.network.topology.title",
                description: "app_info.network.topology.description"
            )
        }

    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Custom header for macOS
            HStack {
                Spacer()
                Button("app_info.done") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(textColor)
                .padding()
            }
            .themedSurface(opacity: 0.95)

            VStack(spacing: 0) {
                panePicker

                paneContent
            }
            .themedSheetBackground()
        }
        .frame(width: 600, height: 700)
        .sheet(isPresented: $showTopology) {
            if let topologyProvider {
                MeshTopologyView(provider: topologyProvider)
            }
        }
        .sheet(isPresented: $showBlockedPeople) {
            blockedPeopleManagementView
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: scenePhase, perform: handleScenePhaseChange)
        #else
        NavigationView {
            VStack(spacing: 0) {
                panePicker

                paneContent
            }
            .themedSheetBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { dismiss() }
                        .foregroundColor(textColor)
                }
            }
        }
        .sheet(isPresented: $showTopology) {
            if let topologyProvider {
                MeshTopologyView(provider: topologyProvider)
            }
        }
        .sheet(isPresented: $showBlockedPeople) {
            blockedPeopleManagementView
        }
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: scenePhase, perform: handleScenePhaseChange)
        #endif
    }

    // MARK: - Pane switching

    private var panePicker: some View {
        Picker(Strings.Settings.tabPickerLabel, selection: $selectedPane) {
            Text(Strings.Settings.tabHelp).tag(AppInfoPane.help)
            Text(Strings.Settings.tabInfo).tag(AppInfoPane.info)
            Text(Strings.Settings.tabSettings).tag(AppInfoPane.settings)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .settings:
            ScrollView { settingsContent }
        case .info:
            ScrollView { infoContent }
        case .help:
            MeshChatHelpView()
        }
    }

    // MARK: - Settings pane

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Appearance — single row: label left, theme chips right
            HStack(spacing: 12) {
                SectionHeader(Strings.appearanceTitle)
                Spacer()
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        appThemeRawValue = theme.rawValue
                    } label: {
                        Text(theme.displayNameKey)
                            .bitchatFont(size: 13, weight: selectedTheme == theme ? .semibold : .regular)
                            .foregroundColor(selectedTheme == theme ? palette.accent : secondaryTextColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTheme == theme ? palette.accent.opacity(0.15) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTheme == theme ? .isSelected : [])
                }
            }

            // Language — an in-app override so the UI language can differ
            // from the device language (takes effect on next launch).
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(verbatim: Strings.Settings.languageTitle)

                settingsCard {
                    Menu {
                        Button {
                            selectLanguage(nil)
                        } label: {
                            menuItemLabel(Strings.Settings.languageSystem, isSelected: languageOverride.isEmpty)
                        }
                        Divider()
                        ForEach(AppLanguageSettings.availableLanguages, id: \.self) { code in
                            Button {
                                selectLanguage(code)
                            } label: {
                                menuItemLabel(AppLanguageSettings.endonym(for: code), isSelected: languageOverride == code)
                            }
                        }
                    } label: {
                        HStack {
                            Text(Strings.Settings.languagePickerLabel)
                                .bitchatFont(size: 12, weight: .semibold)
                                .foregroundColor(textColor)
                            Spacer()
                            Text(languageOverride.isEmpty ? Strings.Settings.languageSystem : AppLanguageSettings.endonym(for: languageOverride))
                                .bitchatFont(size: 12)
                                .foregroundColor(palette.accent)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(secondaryTextColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                }
            }

            // Voice — same card + IRC pill as every other toggle setting.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(Strings.Voice.title)

                settingsCard {
                    settingToggle(
                        title: Text("app_info.voice.live.title"),
                        subtitle: Text("app_info.voice.live.description"),
                        isOn: Binding(
                            get: { liveVoiceEnabled },
                            set: { newValue in
                                liveVoiceEnabled = newValue
                                PTTSettings.liveVoiceEnabled = newValue
                            }
                        )
                    )
                }
            }

            // Connectivity: mesh bridge, Tor routing, relays, and proof-of-work.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(verbatim: Strings.Settings.connectivityTitle)

                settingsCard {
                    settingToggle(
                        title: Text(Strings.Settings.bridgeTitle),
                        subtitle: Text(Strings.Settings.bridgeSubtitle),
                        isOn: bridgeToggleBinding
                    )
                    // Where the bridge meets: the geohash rendezvous cell, or
                    // a hint about why there isn't one yet (no location and no
                    // bridge peer advertising a cell).
                    if bridgeService.isEnabled {
                        Text(bridgeService.activeCell.map(Strings.Settings.bridgeCell) ?? Strings.Settings.bridgeNoCell)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                    }
                }

                settingsCard {
                    settingToggle(
                        title: Text(Strings.Settings.torTitle),
                        subtitle: Text(verbatim: Strings.Settings.torSubtitle),
                        isOn: torToggleBinding
                    )
                    // Turning tor off is not a location-channels-only choice, so
                    // say what it costs while it is off rather than in the
                    // subtitle everyone skims.
                    if !locationChannelsModel.userTorEnabled {
                        Text(verbatim: Strings.Settings.torOffWarning)
                            .bitchatFont(size: 11)
                            .foregroundColor(palette.alertRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                outerProxySettingsCard

                relaySettingsCard

                settingsCard {
                    settingToggle(
                        title: Text(verbatim: Strings.Settings.proofOfWorkTitle),
                        subtitle: Text(verbatim: Strings.Settings.proofOfWorkSubtitle),
                        isOn: Binding(
                            get: { proofOfWorkEnabled },
                            set: { newValue in
                                proofOfWorkEnabled = newValue
                                NostrPoWSettings.enabled = newValue
                            }
                        )
                    )
                }

                // Location notes / dead drops (merged from main's flat
                // layout into the shared card + pill style). Turning it on
                // may need the location prompt; the permission control below
                // covers the denied path.
                settingsCard {
                    settingToggle(
                        title: Strings.Location.notes.title,
                        subtitle: Strings.Location.notes.description,
                        isOn: Binding(
                            get: { locationNotesEnabled },
                            set: { newValue in
                                locationNotesEnabled = newValue
                                LocationNotesSettings.enabled = newValue
                                if newValue {
                                    locationManager.enableLocationChannels()
                                }
                            }
                        )
                    )
                }

                // Location powers the channels list and the bridge cell, so
                // its control lives with the other connectivity settings.
                // Platform reality shapes the three states: the app may only
                // prompt while never-asked; granted/denied both flip in the
                // system permission screen.
                switch locationChannelsModel.permissionState {
                case .authorized:
                    Button(action: SystemSettings.location.open) {
                        Text("location_channels.action.remove_access")
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.alertRed)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                case .notDetermined:
                    Button(action: { locationChannelsModel.enableLocationChannels() }) {
                        Text("location_channels.action.request_permissions")
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(palette.accent.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                case .denied, .restricted:
                    settingsCard {
                        Text("location_channels.permission_denied")
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                        Button("location_channels.action.open_settings", action: SystemSettings.location.open)
                            .buttonStyle(.plain)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.accent)
                    }
                }
            }

            // Privacy: what a locked, seized, or borrowed phone gives away
            // without being unlocked.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(verbatim: Strings.Settings.privacyTitle)

                settingsCard {
                    settingToggle(
                        title: Text(verbatim: Strings.Settings.hidePreviewsTitle),
                        subtitle: Text(verbatim: Strings.Settings.hidePreviewsSubtitle),
                        isOn: Binding(
                            get: { hideMessagePreviews },
                            set: { newValue in
                                hideMessagePreviews = newValue
                                NotificationPrivacySettings.hideMessagePreviews = newValue
                            }
                        )
                    )
                }

                settingsCard {
                    Button {
                        reloadBlockedPeople()
                        showBlockedPeople = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .foregroundColor(palette.secondary)
                                .frame(width: 22)

                            Text(verbatim: BlockedPeopleStrings.title)
                                .bitchatFont(size: 12, weight: .semibold)
                                .foregroundColor(textColor)

                            Spacer()

                            Text(verbatim: blockedPeople.count.formatted())
                                .bitchatFont(size: 11)
                                .foregroundColor(secondaryTextColor)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(secondaryTextColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        Text(verbatim: "\(BlockedPeopleStrings.title), \(blockedPeople.count.formatted())")
                    )
                }
            }

            notificationSettingsSection

            // Danger zone
            if onResetIdentity != nil || onEraseData != nil {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(verbatim: Strings.Settings.dangerTitle)

                    if onResetIdentity != nil {
                        destructiveSettingsButton(
                            title: Strings.Settings.identityResetButton,
                            action: { showIdentityResetConfirmation = true }
                        )
                        .confirmationDialog(
                            Strings.Settings.identityResetButton,
                            isPresented: $showIdentityResetConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(Strings.Settings.identityResetButton, role: .destructive) {
                                performIdentityReset()
                            }
                            Button("common.cancel", role: .cancel) {}
                        } message: {
                            Text(verbatim: Strings.Settings.identityResetNote)
                        }

                        Text(Strings.Settings.identityResetNote)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if onEraseData != nil {
                        destructiveSettingsButton(
                            title: Strings.Settings.eraseDataButton,
                            action: { showDataEraseConfirmation = true }
                        )
                        .confirmationDialog(
                            Strings.Settings.eraseDataButton,
                            isPresented: $showDataEraseConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(Strings.Settings.eraseDataButton, role: .destructive) {
                                performDataErase()
                            }
                            Button("common.cancel", role: .cancel) {}
                        } message: {
                            Text(verbatim: Strings.Settings.eraseDataNote)
                        }

                        Text(Strings.Settings.eraseDataNote)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private var notificationSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(verbatim: Strings.Settings.notificationsTitle)

            settingsCard {
                if notificationAuthorizationStatus == .denied {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(Strings.Settings.notificationsDeniedTitle, systemImage: "bell.slash.fill")
                            .bitchatFont(size: 12, weight: .semibold)
                            .foregroundColor(palette.alertRed)

                        Text(verbatim: Strings.Settings.notificationsDeniedMessage)
                            .bitchatFont(size: 11)
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: SystemSettings.notifications.open) {
                            Label(Strings.Settings.notificationsDeniedOpenSettings, systemImage: "gear")
                                .bitchatFont(size: 12, weight: .semibold)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(palette.accent)
                        .padding(.top, 2)
                    }

                    Divider()
                }

                if let deadline = activeNotificationPauseUntil {
                    Text(verbatim: pausedUntilText(deadline))
                        .bitchatFont(size: 12, weight: .semibold)
                        .foregroundColor(palette.accent)

                    Button(action: resumeNotifications) {
                        Label(Strings.Settings.resumeNotifications, systemImage: "bell.fill")
                            .bitchatFont(size: 12, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(palette.accent)
                } else {
                    Menu {
                        Button(Strings.Settings.pauseOneHour) { pauseNotifications(for: 60 * 60) }
                        Button(Strings.Settings.pauseEightHours) { pauseNotifications(for: 8 * 60 * 60) }
                        Button(Strings.Settings.pauseOneDay) { pauseNotifications(for: 24 * 60 * 60) }
                        Button(Strings.Settings.pauseOneWeek) { pauseNotifications(for: 7 * 24 * 60 * 60) }
                    } label: {
                        Label(Strings.Settings.pauseAllNotifications, systemImage: "bell.slash")
                            .bitchatFont(size: 12, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(palette.accent)
                }

                Divider()

                notificationToggle(
                    topic: .directMessages,
                    title: Strings.Settings.directNotificationsTitle,
                    subtitle: Strings.Settings.directNotificationsSubtitle,
                    value: $directMessageNotifications
                )
                notificationToggle(
                    topic: .mesh,
                    title: Strings.Settings.meshNotificationsTitle,
                    subtitle: Strings.Settings.meshNotificationsSubtitle,
                    value: $meshNotifications
                )
                notificationToggle(
                    topic: .locationChannels,
                    title: Strings.Settings.locationNotificationsTitle,
                    subtitle: Strings.Settings.locationNotificationsSubtitle,
                    value: $locationNotifications
                )
                notificationToggle(
                    topic: .security,
                    title: Strings.Settings.securityNotificationsTitle,
                    subtitle: Strings.Settings.securityNotificationsSubtitle,
                    value: $securityNotifications
                )
            }
        }
    }

    private var blockedPeopleManagementView: some View {
        BlockedPeopleManagementView(
            people: $blockedPeople,
            onUnblock: { person in
                onUnblockPerson?(person)
                reloadBlockedPeople()
            }
        )
    }

    private var activeNotificationPauseUntil: Date? {
        guard let deadline = notificationPauseUntil, deadline > Date() else { return nil }
        return deadline
    }

    private func pausedUntilText(_ deadline: Date) -> String {
        let value = DateFormatter.localizedString(from: deadline, dateStyle: .short, timeStyle: .short)
        return String(format: Strings.Settings.pausedUntil, locale: .current, value)
    }

    private func pauseNotifications(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        NotificationDeliverySettings.pause(until: deadline)
        notificationPauseUntil = deadline
        scheduleNotificationPauseExpiry(for: deadline)
        NotificationService.shared.clearAllNotifications()
    }

    private func resumeNotifications() {
        cancelNotificationPauseTask()
        NotificationDeliverySettings.resume()
        notificationPauseUntil = nil
    }

    private func handleAppear() {
        reloadBlockedPeople()
        reloadCustomRelays()
        reloadNotificationSettings()
        reloadNotificationAuthorizationStatus()
    }

    private func handleDisappear() {
        cancelNotificationPauseTask()
    }

    private func reloadNotificationSettings() {
        directMessageNotifications = NotificationDeliverySettings.isEnabled(.directMessages)
        locationNotifications = NotificationDeliverySettings.isEnabled(.locationChannels)
        meshNotifications = NotificationDeliverySettings.isEnabled(.mesh)
        securityNotifications = NotificationDeliverySettings.isEnabled(.security)

        let deadline = NotificationDeliverySettings.activePauseUntil()
        notificationPauseUntil = deadline
        scheduleNotificationPauseExpiry(for: deadline)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        reloadNotificationAuthorizationStatus()
    }

    /// System authorization can change while this sheet remains presented, so
    /// refresh whenever the app becomes active after visiting System Settings.
    private func reloadNotificationAuthorizationStatus() {
        notificationAuthorizationProvider { status in
            DispatchQueue.main.async {
                notificationAuthorizationStatus = status
            }
        }
    }

    /// Keeps the pause banner accurate even when nothing else redraws the
    /// settings sheet at the deadline.
    private func scheduleNotificationPauseExpiry(for deadline: Date?) {
        cancelNotificationPauseTask()
        guard let deadline else { return }

        notificationPauseTask = Task { @MainActor in
            var currentDeadline = deadline
            while !Task.isCancelled {
                let remaining = max(0, currentDeadline.timeIntervalSinceNow)
                do {
                    try await Task<Never, Never>.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                guard let refreshedDeadline = NotificationDeliverySettings.activePauseUntil() else {
                    notificationPauseUntil = nil
                    notificationPauseTask = nil
                    return
                }
                // A system clock change or an external extension can move the
                // deadline. Keep waiting for the value currently in storage.
                notificationPauseUntil = refreshedDeadline
                currentDeadline = refreshedDeadline
            }
        }
    }

    private func cancelNotificationPauseTask() {
        notificationPauseTask?.cancel()
        notificationPauseTask = nil
    }

    private func performIdentityReset() {
        cancelNotificationPauseTask()
        showIdentityResetConfirmation = false
        onResetIdentity?()
        dismiss()
    }

    /// Clear sheet-owned copies first so a dismiss animation cannot leave
    /// erased identity or routing metadata visible for another frame.
    private func performDataErase() {
        cancelNotificationPauseTask()
        showDataEraseConfirmation = false
        showTopology = false
        blockedPeople.removeAll(keepingCapacity: false)
        customRelays.removeAll(keepingCapacity: false)
        relayInput = ""
        relayError = nil

        NotificationPrivacySettings.reset()
        hideMessagePreviews = true
        NotificationDeliverySettings.reset()
        directMessageNotifications = true
        locationNotifications = true
        meshNotifications = true
        securityNotifications = true
        notificationPauseUntil = nil

        onEraseData?()
        dismiss()
    }

    private func destructiveSettingsButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .bitchatFont(size: 12)
                .foregroundColor(palette.alertRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func notificationToggle(
        topic: NotificationTopic,
        title: String,
        subtitle: String,
        value: Binding<Bool>
    ) -> some View {
        settingToggle(
            title: Text(verbatim: title),
            subtitle: Text(verbatim: subtitle),
            isOn: Binding(
                get: { value.wrappedValue },
                set: { enabled in
                    value.wrappedValue = enabled
                    NotificationDeliverySettings.setEnabled(enabled, for: topic)
                }
            )
        )
    }

    private func reloadBlockedPeople() {
        blockedPeople = blockedPeopleProvider?() ?? []
    }

    private func selectLanguage(_ code: String?) {
        AppLanguageSettings.setOverride(code)
        languageOverride = code ?? ""
    }

    private func menuItemLabel(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var bridgeToggleBinding: Binding<Bool> {
        Binding(
            get: { bridgeService.isEnabled },
            set: { bridgeService.setEnabled($0) }
        )
    }

    /// Relay list editor. The built-in relays are four well-known hostnames, so
    /// a filter blocking four names ends internet-delivered private messages;
    /// adding one here is the only fix that does not need a new build.
    @ViewBuilder
    private var relaySettingsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Strings.Settings.relaysTitle)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(textColor)
                Text(verbatim: Strings.Settings.relaysSubtitle)
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(NostrRelayManager.builtInRelayURLs.sorted(), id: \.self) { relay in
                HStack(spacing: 6) {
                    Text(verbatim: relay)
                        .bitchatFont(size: 11)
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(verbatim: Strings.Settings.relayBuiltIn)
                        .bitchatFont(size: 10)
                        .foregroundColor(secondaryTextColor)
                }
            }

            ForEach(customRelays, id: \.self) { relay in
                HStack(spacing: 6) {
                    Text(verbatim: relay)
                        .bitchatFont(size: 11)
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        NostrRelaySettings.remove(relay)
                        reloadCustomRelays()
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(palette.alertRed)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Strings.Settings.relayRemove)
                }
            }

            if customRelays.count < NostrRelaySettings.maxCustomRelays {
                HStack(spacing: 6) {
                    TextField(Strings.Settings.relayPlaceholder, text: $relayInput)
                        .textFieldStyle(.plain)
                        .bitchatFont(size: 11)
                        .foregroundColor(textColor)
                        .autocorrectionDisabled(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit(addRelay)
                    Button(action: addRelay) {
                        Text(verbatim: Strings.Settings.relayAdd)
                            .bitchatFont(size: 11, weight: .semibold)
                            .foregroundColor(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(relayInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let relayError {
                Text(verbatim: relayError)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.alertRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The store can change from outside this view — a panic wipe clears it —
        // so follow it rather than trusting the value read at creation.
        .onReceive(NotificationCenter.default.publisher(for: NostrRelaySettings.didChangeNotification)) { _ in
            reloadCustomRelays()
        }
    }

    private func addRelay() {
        let candidate = relayInput
        switch NostrRelaySettings.add(candidate, builtIn: NostrRelayManager.builtInRelayURLs) {
        case .success:
            relayInput = ""
            relayError = nil
            reloadCustomRelays()
        case .failure(let failure):
            relayError = Strings.Settings.relayError(failure)
        }
    }

    private func reloadCustomRelays() {
        customRelays = NostrRelaySettings.customRelays()
    }

    @ViewBuilder
    private var outerProxySettingsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Strings.Settings.outerProxyTitle)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(textColor)
                Text(verbatim: Strings.Settings.outerProxySubtitle)
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker(Strings.Settings.outerProxyTitle, selection: $outerProxyDraft.mode) {
                Text(verbatim: Strings.Settings.languageSystem).tag(OuterProxyMode.systemDefault)
                Text(verbatim: Strings.Settings.proxyCustom).tag(OuterProxyMode.custom)
            }
            .pickerStyle(.segmented)

            if outerProxyDraft.mode == .systemDefault {
                Text(verbatim: systemProxyStatusText)
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(Strings.Settings.proxyType, selection: $outerProxyDraft.kind) {
                    Text(verbatim: "HTTP CONNECT").tag(OuterProxyKind.httpConnect)
                    Text(verbatim: "SOCKS5").tag(OuterProxyKind.socks5)
                }

                proxyTextField(Strings.Settings.proxyHost, text: $outerProxyDraft.host)
                proxyTextField(Strings.Settings.proxyPort, text: $outerProxyDraft.port)
                proxyTextField(Strings.Settings.proxyUsername, text: $outerProxyDraft.username)
                SecureField(Strings.Settings.proxyPassword, text: $outerProxyDraft.password)
                    .textFieldStyle(.roundedBorder)
                    .bitchatFont(size: 11)

                Text(verbatim: Strings.Settings.proxyCredentialNote)
                    .bitchatFont(size: 10)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(action: applyOuterProxySettings) {
                    Text(verbatim: Strings.Settings.proxyApply)
                        .bitchatFont(size: 11, weight: .semibold)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 8)

                if let outerProxyStatus {
                    Text(verbatim: outerProxyStatus)
                        .bitchatFont(size: 10)
                        .foregroundColor(outerProxyStatusIsError ? palette.alertRed : secondaryTextColor)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var systemProxyStatusText: String {
        #if os(macOS)
        guard let detectedSystemProxy else { return Strings.Settings.proxyNotDetected }
        return String(format: Strings.Settings.proxyDetected, locale: .current, detectedSystemProxy)
        #else
        return Strings.Settings.proxyIOSSystem
        #endif
    }

    private func proxyTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .bitchatFont(size: 11)
            .autocorrectionDisabled(true)
    }

    private func applyOuterProxySettings() {
        switch OuterProxySettings.save(outerProxyDraft) {
        case .success:
            switch OuterProxySettings.applyStored() {
            case .success:
                // In System Default mode the saved password is removed. Reload
                // the draft so it is not retained in this view's memory.
                outerProxyDraft = OuterProxySettings.loadDraft()
                #if os(macOS)
                detectedSystemProxy = OuterProxySettings.systemProxyDescription()
                #endif
                outerProxyStatus = Strings.Settings.proxyApplied
                outerProxyStatusIsError = false
                NostrRelayManager.shared.resetAllConnections()
            case .failure(let error):
                showOuterProxyError(error)
            }
        case .failure(let error):
            showOuterProxyError(error)
        }
    }

    private func showOuterProxyError(_ error: OuterProxySettingsError) {
        switch error {
        case .invalidHost, .invalidPort:
            outerProxyStatus = Strings.Settings.proxyErrorSettings
        case .incompleteCredentials:
            outerProxyStatus = Strings.Settings.proxyErrorCredentials
        case .oversizedCredentials:
            outerProxyStatus = Strings.Settings.proxyErrorCredentials
        case .passwordSaveFailed:
            outerProxyStatus = Strings.Settings.proxyErrorSave
        }
        outerProxyStatusIsError = true
    }

    private var torToggleBinding: Binding<Bool> {
        Binding(
            get: { locationChannelsModel.userTorEnabled },
            set: { locationChannelsModel.setUserTorEnabled($0) }
        )
    }

    /// The padded card every connectivity setting sits in (moved look from
    /// LocationChannelsSheet's toggle sections).
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .background(palette.secondary.opacity(0.12))
            .cornerRadius(8)
    }

    /// A title+subtitle row driving an IRC-style on/off pill — the one
    /// toggle style every setting uses.
    private func settingToggle(title: Text, subtitle: Text, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(textColor)
                subtitle
                    .bitchatFont(size: 11)
                    .foregroundColor(secondaryTextColor)
            }
        }
        .toggleStyle(IRCToggleStyle(accent: palette.accent, onLabel: Strings.Settings.toggleOn, offLabel: Strings.Settings.toggleOff))
    }

    // MARK: - Info pane

    @ViewBuilder
    private var infoContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .center, spacing: 8) {
                Text(Strings.appName)
                    .bitchatFont(size: 32, weight: .bold)
                    .foregroundColor(textColor)

                Text(Strings.tagline)
                    .bitchatFont(size: 16)
                    .foregroundColor(secondaryTextColor)

                Text(verbatim: appVersion)
                    .bitchatFont(size: 12)
                    .foregroundColor(secondaryTextColor)

                Text(Strings.aboutDescription)
                    .bitchatFont(size: 13)
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/dishangti/bitchat")!) {
                        Label {
                            Text(verbatim: "github.com/dishangti/bitchat")
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    .foregroundColor(palette.accent)

                    Label {
                        Text(verbatim: "MIT")
                    } icon: {
                        Image(systemName: "doc.plaintext")
                    }
                    .foregroundColor(secondaryTextColor)
                }
                .bitchatFont(size: 11, weight: .semibold)
                .padding(.top, 4)

                Link(destination: URL(string: "https://github.com/permissionlesstech/bitchat")!) {
                    Label {
                        Text(verbatim: "BitChat · permissionlesstech/bitchat")
                    } icon: {
                        Image(systemName: "heart.fill")
                    }
                }
                .bitchatFont(size: 11, weight: .semibold)
                .foregroundColor(palette.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)

            // Network diagnostics
            if topologyProvider != nil {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(Strings.Network.title)

                    Button {
                        showTopology = true
                    } label: {
                        HStack(spacing: 0) {
                            FeatureRow(info: Strings.Network.topology)
                            Image(systemName: "chevron.right")
                                .font(.bitchatSystem(size: 12))
                                .foregroundColor(secondaryTextColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("app_info.network.topology.hint"))
                }
            }

        }
        .padding()
    }
}

struct AppInfoFeatureInfo {
    let icon: String
    let title: Text
    let description: Text

    /// Catalog-backed strings (existing keys).
    init(icon: String, title: LocalizedStringKey, description: LocalizedStringKey) {
        self.icon = icon
        self.title = Text(title)
        self.description = Text(description)
    }
}

/// A discoverable, standard list for reviewing and reversing local blocks.
/// Rows receive presentation-only data; unblocking still resolves through the
/// app model by complete Noise fingerprint or complete Nostr public key.
private struct BlockedPeopleManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var people: [BlockedPersonRow]
    let onUnblock: @MainActor (BlockedPersonRow) -> Void

    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }
    private var secondaryTextColor: Color { palette.secondary }

    var body: some View {
        NavigationStack {
            Group {
                if people.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 36))
                            .foregroundColor(secondaryTextColor)
                        Text(verbatim: BlockedPeopleStrings.title)
                            .bitchatFont(size: 14, weight: .semibold)
                            .foregroundColor(textColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                } else {
                    List {
                        ForEach(people) { person in
                            blockedPersonRow(person)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .themedSheetBackground()
            .navigationTitle(BlockedPeopleStrings.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("app_info.done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 500, height: 520)
        #endif
    }

    private func blockedPersonRow(_ person: BlockedPersonRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: person.source == .mesh ? "antenna.radiowaves.left.and.right" : "globe")
                .foregroundColor(palette.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: person.displayName)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(verbatim: "\(sourceLabel(person.source)) • \(person.identityHint)")
                    .bitchatFont(size: 10)
                    .foregroundColor(secondaryTextColor)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(verbatim: "\(person.displayName), \(sourceLabel(person.source)), \(person.identityHint)")
            )

            Spacer()

            Button("geohash_people.action.unblock") {
                onUnblock(person)
            }
            .buttonStyle(.plain)
            .bitchatFont(size: 11, weight: .semibold)
            .foregroundColor(palette.accent)
        }
        .listRowBackground(palette.secondary.opacity(0.08))
    }

    private func sourceLabel(_ source: BlockedPersonRow.Source) -> String {
        source == .mesh ? "#mesh" : "Nostr"
    }
}

struct SectionHeader: View {
    private let title: Text
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    /// For pre-resolved strings (new keys with inline defaultValue).
    init(verbatim title: String) {
        self.title = Text(title)
    }

    var body: some View {
        title
            .bitchatFont(size: 16, weight: .bold)
            .foregroundColor(textColor)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct FeatureRow: View {
    let info: AppInfoFeatureInfo
    @ThemedPalette private var palette

    private var textColor: Color { palette.primary }

    private var secondaryTextColor: Color { palette.secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.icon)
                .font(.bitchatSystem(size: 20))
                .foregroundColor(textColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                info.title
                    .bitchatFont(size: 14, weight: .semibold)
                    .foregroundColor(textColor)

                info.description
                    .bitchatFont(size: 12)
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

#Preview("Default") {
    AppInfoView()
        .environmentObject(LocationChannelsModel())
}

#Preview("Dynamic Type XXL") {
    AppInfoView()
        .environmentObject(LocationChannelsModel())
        .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}

#Preview("Dynamic Type XS") {
    AppInfoView()
        .environmentObject(LocationChannelsModel())
        .environment(\.sizeCategory, .extraSmall)
}
