// SPDX-License-Identifier: MIT

import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The adaptive MeshChat shell.  It intentionally depends only on the feature
/// models assembled by `AppRuntime`; transport, identity, storage, and protocol
/// state remain outside the view hierarchy.
struct MeshChatRootView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var sharedContentImportModel: SharedContentImportModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @EnvironmentObject private var publicChatModel: PublicChatModel
    @EnvironmentObject private var privateInboxModel: PrivateInboxModel
    @EnvironmentObject private var boardAlertsModel: BoardAlertsModel
    @EnvironmentObject private var routeModel: AppRouteModel

    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ThemedPalette private var palette

    @StateObject private var voiceRecordingVM = VoiceRecordingViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isConversationPresented = false

    @State private var messageText = ""
    @State private var drafts: [String: String] = [:]
    @State private var activeDraftKey = "mesh"
    @State private var selectedMessageSender: String?
    @State private var selectedMessageSenderID: PeerID?
    @State private var imagePreviewURL: URL?
    @State private var windowCountPublic = TransportConfig.uiWindowInitialCountPublic
    @State private var windowCountPrivate: [PeerID: Int] = [:]
    @State private var isAtBottomPublic = true
    @State private var isAtBottomPrivate = true
    @State private var autocompleteDebounceTimer: Timer?
    @State private var showVerification = false
    @State private var pendingShareGeohash: String?
    @State private var showSharePrecisionWarning = false
    @State private var activeSharePayload: ChannelSharePayload?

    @FocusState private var isTextFieldFocused: Bool

    #if os(iOS)
    @State private var showImagePicker = false
    @State private var imagePickerSourceType: UIImagePickerController.SourceType = .photoLibrary
    #else
    @State private var showMacImagePicker = false
    #endif

    private var selectedPrivatePeerID: PeerID? {
        privateConversationModel.selectedPeerID
    }

    private var sharedContentDestination: SharedContentDestination {
        SharedContentDestination.resolve(
            selectedPrivatePeerID: selectedPrivatePeerID,
            privateDisplayName: privateConversationModel.selectedHeaderState?.displayName,
            activeChannel: locationChannelsModel.selectedChannel,
            includesPrivateConversation: isConversationPresented
        )
    }

    private var currentDraftKey: String {
        if let peerID = selectedPrivatePeerID {
            return "dm:\(peerID.id)"
        }
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            return "mesh"
        case .location(let channel):
            return "geo:\(channel.geohash.lowercased())"
        }
    }

    private var conversationColumnVisibility: NavigationSplitViewVisibility {
        #if os(iOS)
        horizontalSizeClass == .compact ? .detailOnly : .all
        #else
        .all
        #endif
    }

    private var usesCompactNavigation: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var legacyShowSidebarBinding: Binding<Bool> {
        Binding(
            get: {
                usesCompactNavigation
                    ? !isConversationPresented
                    : columnVisibility != .detailOnly
            },
            set: { requested in
                // MessageListView historically sets this after opening a DM.
                // Keep that action in the conversation after the navigation
                // stack was reversed to make Home the compact root.
                if requested, selectedPrivatePeerID != nil {
                    revealConversation()
                } else if requested {
                    showHome()
                } else {
                    isConversationPresented = true
                    columnVisibility = .detailOnly
                }
            }
        )
    }

    private var hasBlockingPresentation: Bool {
        appChromeModel.isAppInfoPresented
            || appChromeModel.showingFingerprintFor != nil
            || appChromeModel.showingNicknameFor != nil
            || appChromeModel.isLocationChannelsSheetPresented
            || appChromeModel.isNoticesSheetPresented
            || appChromeModel.showScreenshotPrivacyWarning
            || showVerification
            || imagePreviewURL != nil
            || activeSharePayload != nil
            || showSharePrecisionWarning
            || conversationUIModel.legacyPrivateMediaConsentRequest != nil
            || sharedContentImportModel.offer != nil
            || isMediaPickerPresented
    }

    private var isMediaPickerPresented: Bool {
        #if os(iOS)
        showImagePicker
        #else
        showMacImagePicker
        #endif
    }

    private var bluetoothAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && appChromeModel.showBluetoothAlert
                    && !hasBlockingPresentation
                    && !voiceRecordingVM.showAlert
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasBlockingPresentation else { return }
                Task { @MainActor in
                    appChromeModel.dismissBluetoothAlert()
                }
            }
        )
    }

    private var voiceAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && voiceRecordingVM.showAlert
                    && !hasBlockingPresentation
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasBlockingPresentation else { return }
                Task { @MainActor in
                    voiceRecordingVM.showAlert = false
                }
            }
        )
    }

    var body: some View {
        navigationShell
            .background(ThemedRootBackground())
            .foregroundColor(palette.primary)
            #if os(macOS)
            .frame(minWidth: 760, minHeight: 520)
            #endif
            .onAppear(perform: configureOnAppear)
            .onChange(of: colorScheme) { newValue in
                conversationUIModel.setCurrentColorScheme(newValue)
            }
            .onChange(of: appTheme) { newValue in
                conversationUIModel.setCurrentTheme(newValue)
            }
            .onChange(of: horizontalSizeClass) { _ in
                reconcileColumnVisibilityForSizeClass()
            }
            .onChange(of: selectedPrivatePeerID) { newValue in
                switchDraftContext()
                if newValue != nil {
                    revealConversation()
                }
                sharedContentImportModel.updateDestination(sharedContentDestination)
                updateVisibleConversation()
            }
            .onChange(of: isConversationPresented) { isPresented in
                if !isPresented {
                    clearPrivateSelectionForHome()
                }
                updateVisibleConversation()
            }
            .onChange(of: locationChannelsModel.selectedChannel) { _ in
                if selectedPrivatePeerID == nil {
                    switchDraftContext()
                }
                sharedContentImportModel.updateDestination(sharedContentDestination)
                updateVisibleConversation()
            }
            .onChange(of: routeModel.pendingURLRoute) { route in
                if let route {
                    handleURLRoute(route)
                }
            }
            .sheet(isPresented: $appChromeModel.isAppInfoPresented) {
                AppInfoView(
                    topologyProvider: { appChromeModel.meshTopologyDisplayModel() },
                    onResetIdentity: performIdentityReset,
                    onEraseData: performDataErase,
                    blockedPeopleProvider: { appChromeModel.blockedPeople() },
                    onUnblockPerson: { appChromeModel.unblock($0) }
                )
                .environmentObject(locationChannelsModel)
            }
            .sheet(isPresented: $appChromeModel.isLocationChannelsSheetPresented) {
                LocationChannelsSheet(
                    isPresented: $appChromeModel.isLocationChannelsSheetPresented,
                    onOpenChannel: openChannel
                )
                    .environmentObject(locationChannelsModel)
                    .environmentObject(peerListModel)
            }
            .sheet(
                isPresented: $appChromeModel.isNoticesSheetPresented,
                onDismiss: { appChromeModel.noticesSheetPrefersGeoTab = false }
            ) {
                NoticesView(
                    senderNickname: appChromeModel.nickname,
                    board: appChromeModel.boardManager,
                    initialTab: initialNoticesTab
                )
                .environmentObject(locationChannelsModel)
            }
            .sheet(isPresented: Binding(
                get: { appChromeModel.showingFingerprintFor != nil },
                set: { isPresented in
                    if !isPresented { appChromeModel.clearFingerprint() }
                }
            )) {
                if let peerID = appChromeModel.showingFingerprintFor {
                    FingerprintView(peerID: peerID)
                        .environmentObject(verificationModel)
                }
            }
            .sheet(isPresented: Binding(
                get: { appChromeModel.showingNicknameFor != nil },
                set: { isPresented in
                    if !isPresented { appChromeModel.clearNicknameEditor() }
                }
            )) {
                if let peerID = appChromeModel.showingNicknameFor {
                    LocalNicknameSheetView(peerID: peerID)
                        .environmentObject(verificationModel)
                }
            }
            .sheet(isPresented: $showVerification) {
                VerificationSheetView(isPresented: $showVerification)
                    .environmentObject(verificationModel)
            }
            .sheet(isPresented: Binding(
                get: { imagePreviewURL != nil },
                set: { isPresented in
                    if !isPresented { imagePreviewURL = nil }
                }
            )) {
                if let imagePreviewURL {
                    ImagePreviewView(url: imagePreviewURL)
                }
            }
            .sheet(item: $activeSharePayload) { payload in
                ShareActivityView(text: payload.text)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showImagePicker) {
                ImagePickerView(sourceType: imagePickerSourceType) { image in
                    showImagePicker = false
                    conversationUIModel.processSelectedImage(image)
                }
                .ignoresSafeArea()
            }
            #else
            .sheet(isPresented: $showMacImagePicker) {
                MacImagePickerView { url in
                    showMacImagePicker = false
                    conversationUIModel.processSelectedImage(from: url)
                }
            }
            #endif
            .confirmationDialog(
                AppLanguageSettings.localized(
                     "content.private_media.legacy_warning.title",
                    defaultValue: "Send without end-to-end encryption?",
                    comment: "Title warning before sending private media to an older client in a clear signed envelope"
                ),
                isPresented: legacyMediaConsentBinding,
                titleVisibility: .visible
            ) {
                Button(
                    AppLanguageSettings.localized(
                         "content.private_media.legacy_warning.send",
                        defaultValue: "Send Visible File",
                        comment: "Destructive confirmation action for one legacy clear private-media send"
                    ),
                    role: .destructive,
                    action: approveLegacyMediaSend
                )
                Button("common.cancel", role: .cancel, action: rejectLegacyMediaSend)
            } message: {
                if let request = conversationUIModel.legacyPrivateMediaConsentRequest {
                    Text(legacyMediaWarning(for: request))
                }
            }
            .confirmationDialog(
                AppLanguageSettings.localized(
                     "channel.share.precision_warning.title",
                    defaultValue: "Share a Precise Location Channel?",
                    comment: "Title of the confirmation before sharing a neighborhood-or-finer geohash invite"
                ),
                isPresented: $showSharePrecisionWarning,
                titleVisibility: .visible
            ) {
                Button(
                    AppLanguageSettings.localized(
                         "channel.share.precision_warning.confirm",
                        defaultValue: "Share Anyway",
                        comment: "Confirms sharing a fine-precision location channel after the OpSec warning"
                    ),
                    action: confirmPreciseChannelShare
                )
                Button("common.cancel", role: .cancel) {
                    pendingShareGeohash = nil
                }
            } message: {
                Text(
                    AppLanguageSettings.localized(
                         "channel.share.precision_warning.message",
                        defaultValue: "This channel covers a small area. An invite sent over SMS or iMessage is visible to the carrier and both handsets — it discloses interest in that place, not only that someone uses MeshChat.",
                        comment: "Body of the confirmation before sharing a fine-precision geohash invite"
                    )
                )
            }
            .alert("content.alert.recording_error.title", isPresented: voiceAlertBinding) {
                Button("common.ok", role: .cancel) {}
                if voiceRecordingVM.state == .permissionDenied {
                    Button("location_channels.action.open_settings") {
                        SystemSettings.microphone.open()
                    }
                }
            } message: {
                Text(voiceRecordingVM.state.alertMessage)
            }
            .alert("content.alert.bluetooth_required.title", isPresented: bluetoothAlertBinding) {
                Button("content.alert.bluetooth_required.settings") {
                    SystemSettings.bluetooth.open()
                }
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(appChromeModel.bluetoothAlertMessage)
            }
            .alert("content.alert.screenshot.title", isPresented: $appChromeModel.showScreenshotPrivacyWarning) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text("content.alert.screenshot.message")
            }
            .alert(
                AppLanguageSettings.localized(
                     "share_import.review.title",
                    comment: "Title for reviewing content received from the share extension"
                ),
                isPresented: Binding(
                    get: { sharedContentImportModel.offer != nil },
                    set: { _ in }
                ),
                presenting: sharedContentImportModel.offer
            ) { _ in
                Button("common.cancel", role: .cancel) {
                    sharedContentImportModel.cancel(destination: sharedContentDestination)
                }
                Button("share_import.review.use_in_composer") {
                    guard let importedText = sharedContentImportModel.confirm(
                        destination: sharedContentDestination
                    ) else { return }
                    messageText = importedText
                    drafts[activeDraftKey] = importedText
                    isTextFieldFocused = true
                }
            } message: { offer in
                let format = AppLanguageSettings.localized(
                     "share_import.review.message",
                    comment: "Explains that shared content will replace the named destination's composer and will not be sent automatically"
                )
                Text(String(format: format, offer.destination.displayName) + "\n\n" + offer.payload.preview)
            }
            .onDisappear {
                drafts[activeDraftKey] = messageText
                autocompleteDebounceTimer?.invalidate()
                appChromeModel.setPanicPreparation(nil)
            }
    }

    @ViewBuilder
    private var navigationShell: some View {
        #if os(iOS)
        if usesCompactNavigation {
            NavigationStack {
                sidebarContent
                    .navigationDestination(isPresented: $isConversationPresented) {
                        conversationDetail
                            .navigationBarTitleDisplayMode(.inline)
                    }
            }
        } else {
            splitNavigationShell
        }
        #else
        splitNavigationShell
        #endif
    }

    private var splitNavigationShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 400)
        } detail: {
            if isConversationPresented {
                conversationDetail
            } else {
                homeDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var homeDetail: some View {
        MeshChatHomeView(
            onOpenMesh: { openChannel(.mesh) },
            onOpenLocations: { appChromeModel.isLocationChannelsSheetPresented = true },
            onOpenVerification: { showVerification = true }
        )
    }

    private var sidebarContent: some View {
        MeshChatSidebarView(
            activePeerID: selectedPrivatePeerID,
            showsConversationSelection: isConversationPresented,
            onOpenChannel: openChannel,
            onOpenPeer: openPeer,
            onOpenLocations: { appChromeModel.isLocationChannelsSheetPresented = true },
            onOpenNotices: presentNotices,
            onOpenAppInfo: { appChromeModel.presentAppInfo(pane: .help) },
            onOpenSettings: { appChromeModel.presentAppInfo(pane: .settings) },
            onOpenVerification: { showVerification = true },
            onPanic: performPanicWipe,
            onDeleteActiveRecent: showHome
        )
    }

    private var conversationDetail: some View {
        VStack(spacing: 0) {
            MeshChatConversationHeader(
                onOpenHome: showHome,
                onOpenLocations: { appChromeModel.isLocationChannelsSheetPresented = true },
                onOpenNotices: presentNotices,
                onOpenSettings: { appChromeModel.presentAppInfo(pane: .settings) },
                onOpenVerification: { showVerification = true },
                onShareChannel: requestChannelShare
            )

            Divider()

            MessageListView(
                privatePeer: selectedPrivatePeerID,
                isAtBottom: selectedPrivatePeerID == nil ? $isAtBottomPublic : $isAtBottomPrivate,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: legacyShowSidebarBinding,
                isTextFieldFocused: $isTextFieldFocused
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedPrivatePeerID != nil {
                privateConversationPrivacyCaption
            }

            composer
        }
        .background(palette.background)
    }

    @ViewBuilder
    private var composer: some View {
        #if os(iOS)
        ContentComposerView(
            messageText: $messageText,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            onSendMessage: sendMessage,
            showImagePicker: $showImagePicker,
            imagePickerSourceType: $imagePickerSourceType
        )
        #else
        ContentComposerView(
            messageText: $messageText,
            isTextFieldFocused: $isTextFieldFocused,
            voiceRecordingVM: voiceRecordingVM,
            autocompleteDebounceTimer: $autocompleteDebounceTimer,
            onSendMessage: sendMessage,
            showMacImagePicker: $showMacImagePicker
        )
        #endif
    }

    private var privateConversationPrivacyCaption: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text(privateConversationPrivacyText)
                .font(.caption.weight(.medium))
                .lineLimit(2)
        }
        .foregroundStyle(Color.orange)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.07))
        .accessibilityElement(children: .combine)
    }

    private var privateConversationPrivacyText: String {
        if selectedPrivatePeerID?.isGroup == true {
            return AppLanguageSettings.localized(
                 "content.private.caption_group",
                comment: "Caption above the group chat composer noting messages are encrypted to group members"
            )
        }

        let noiseSecured: Bool = {
            switch privateConversationModel.selectedHeaderState?.encryptionStatus {
            case .noiseSecured, .noiseVerified:
                return true
            default:
                return false
            }
        }()
        if selectedPrivatePeerID?.isGeoDM == true || noiseSecured {
            return AppLanguageSettings.localized(
                 "content.private.caption_encrypted",
                comment: "Caption above the private chat composer once the session is end-to-end encrypted"
            )
        }
        return AppLanguageSettings.localized(
             "content.private.caption",
            comment: "Caption above the private chat composer before encryption is established"
        )
    }

    private var initialNoticesTab: NoticesView.Tab {
        if appChromeModel.noticesSheetPrefersGeoTab { return .geo }
        if case .location = locationChannelsModel.selectedChannel { return .geo }
        return .mesh
    }

    private var legacyMediaConsentBinding: Binding<Bool> {
        Binding(
            get: { conversationUIModel.legacyPrivateMediaConsentRequest != nil },
            set: { isPresented in
                if !isPresented { rejectLegacyMediaSend() }
            }
        )
    }

    private func configureOnAppear() {
        conversationUIModel.setCurrentColorScheme(colorScheme)
        conversationUIModel.setCurrentTheme(appTheme)
        voiceRecordingVM.sessionProvider = { [weak conversationUIModel] in
            conversationUIModel?.makeVoiceCaptureSession() ?? VoiceNoteCaptureSession()
        }
        appChromeModel.setPanicPreparation { [weak voiceRecordingVM] in
            voiceRecordingVM?.panicWipe()
        }
        activeDraftKey = currentDraftKey
        messageText = drafts[activeDraftKey, default: ""]
        sharedContentImportModel.updateDestination(sharedContentDestination)
        reconcileColumnVisibilityForSizeClass()
        updateVisibleConversation()
        if let route = routeModel.pendingURLRoute {
            handleURLRoute(route)
        }

        #if os(macOS)
        DispatchQueue.main.async {
            isTextFieldFocused = true
        }
        #endif
    }

    private func reconcileColumnVisibilityForSizeClass() {
        #if os(iOS)
        columnVisibility = horizontalSizeClass == .compact ? .detailOnly : .all
        #else
        columnVisibility = .all
        #endif
    }

    private func showHome() {
        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
            isConversationPresented = false
            clearPrivateSelectionForHome()
            if !usesCompactNavigation {
                columnVisibility = .all
            }
        }
    }

    /// Removes view-owned transient content that does not live in the chat
    /// model, runs the security wipe, and makes Home the only visible route.
    private func performPanicWipe() {
        prepareForDestructiveChange()
        appChromeModel.panicClearAllData()
        finishDataEraseUI()
    }

    private func performDataErase() {
        prepareForDestructiveChange()
        appChromeModel.eraseAllData()
        finishDataEraseUI()
    }

    private func performIdentityReset() {
        appChromeModel.resetIdentity()
    }

    private func prepareForDestructiveChange() {
        showVerification = false
        pendingShareGeohash = nil
        showSharePrecisionWarning = false
        activeSharePayload = nil
        imagePreviewURL = nil
        selectedMessageSender = nil
        selectedMessageSenderID = nil
        routeModel.clearPendingRoute()
        autocompleteDebounceTimer?.invalidate()
        autocompleteDebounceTimer = nil
        conversationUIModel.dismissAutocomplete()
        isTextFieldFocused = false
        #if os(iOS)
        showImagePicker = false
        #else
        showMacImagePicker = false
        #endif
    }

    private func finishDataEraseUI() {
        showHome()

        messageText = ""
        drafts.removeAll(keepingCapacity: false)
        activeDraftKey = "mesh"
        windowCountPublic = TransportConfig.uiWindowInitialCountPublic
        windowCountPrivate.removeAll(keepingCapacity: false)
    }

    /// Home is a real route, not a hidden private conversation. This also
    /// handles an interactive NavigationStack pop on iPhone.
    private func clearPrivateSelectionForHome() {
        if selectedPrivatePeerID != nil {
            privateConversationModel.endConversation()
            switchDraftContext()
        }
        sharedContentImportModel.updateDestination(sharedContentDestination)
    }

    private func switchDraftContext() {
        let nextKey = currentDraftKey
        guard nextKey != activeDraftKey else { return }
        drafts[activeDraftKey] = messageText
        activeDraftKey = nextKey
        messageText = drafts[nextKey, default: ""]
        conversationUIModel.dismissAutocomplete()
    }

    private func openChannel(_ channel: ChannelID) {
        privateConversationModel.endConversation()
        locationChannelsModel.select(channel)
        revealConversation()
    }

    private func openPeer(_ peerID: PeerID) {
        if privateConversationModel.selectedPeerID != peerID {
            privateConversationModel.openConversation(for: peerID)
        }
        revealConversation()
    }

    private func revealConversation() {
        isConversationPresented = true
        if !usesCompactNavigation {
            columnVisibility = conversationColumnVisibility
        }
    }

    private func updateVisibleConversation() {
        guard isConversationPresented else {
            routeModel.setVisibleConversation(nil)
            return
        }
        if let peerID = selectedPrivatePeerID {
            routeModel.setVisibleConversation(.direct(peerID))
            return
        }
        switch locationChannelsModel.selectedChannel {
        case .mesh:
            routeModel.setVisibleConversation(.mesh)
        case .location(let channel):
            routeModel.setVisibleConversation(.geohash(channel.geohash.lowercased()))
        }
    }

    private func handleURLRoute(_ route: ChatURLRoute) {
        routeModel.consume(route)

        switch route {
        case .share:
            break
        case .geohash(let geohash):
            privateConversationModel.endConversation()
            locationChannelsModel.openLocationChannel(for: geohash)
            revealConversation()
        case .user(let peerID):
            guard !conversationUIModel.isSelfSender(peerID: peerID, displayName: nil) else { return }
            openPeer(peerID)
        case .verification(let payload):
            showVerification = true
            _ = verificationModel.verifyScannedPayload(payload)
        }
    }

    private func sendMessage() {
        guard let trimmed = messageText.trimmedOrNilIfEmpty else { return }
        messageText = ""
        drafts[activeDraftKey] = ""
        DispatchQueue.main.async {
            conversationUIModel.sendMessage(trimmed)
        }
    }

    private func presentNotices() {
        var scopes: Set<String> = [""]
        if case .location(let channel) = locationChannelsModel.selectedChannel {
            scopes.insert(channel.geohash)
        } else if let building = locationChannelsModel.currentBuildingGeohash {
            scopes.insert(building)
        }
        boardAlertsModel.markSeen(forScopes: scopes)
        appChromeModel.presentNotices()
    }

    private func requestChannelShare(_ geohash: String) {
        if ChannelShare.shouldWarn(forGeohash: geohash) {
            pendingShareGeohash = geohash
            showSharePrecisionWarning = true
        } else {
            activeSharePayload = ChannelSharePayload(
                text: ChannelShare.payload(forGeohash: geohash)
            )
        }
    }

    private func confirmPreciseChannelShare() {
        if let pendingShareGeohash {
            activeSharePayload = ChannelSharePayload(
                text: ChannelShare.payload(forGeohash: pendingShareGeohash)
            )
        }
        pendingShareGeohash = nil
    }

    private func approveLegacyMediaSend() {
        guard let requestID = conversationUIModel.legacyPrivateMediaConsentRequest?.id else { return }
        conversationUIModel.resolveLegacyPrivateMediaConsent(
            requestID: requestID,
            approved: true
        )
    }

    private func rejectLegacyMediaSend() {
        guard let requestID = conversationUIModel.legacyPrivateMediaConsentRequest?.id else { return }
        conversationUIModel.resolveLegacyPrivateMediaConsent(
            requestID: requestID,
            approved: false
        )
    }

    private func legacyMediaWarning(for request: LegacyPrivateMediaConsentRequest) -> String {
        String(
            format: AppLanguageSettings.localized(
                 "content.private_media.legacy_warning.message",
                defaultValue: "%@'s client does not advertise encrypted private media. This file will be signed but not end-to-end encrypted, so mesh relays can see it. Send this file anyway?",
                comment: "Warning explaining the confidentiality loss for one legacy private-media send; parameter is the peer name"
            ),
            locale: .current,
            request.peerName
        )
    }
}
