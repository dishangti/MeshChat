import BitFoundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentPeopleSheetModalPresentationState {
    var isImagePreviewPresented = false
    var isVerificationSheetPresented = false
    var legacyPrivateMediaConsentRequest: LegacyPrivateMediaConsentRequest? = nil
    var isVoiceAlertPresented = false
    var isMediaPickerPresented = false

    var hasPresentation: Bool {
        isImagePreviewPresented
            || isVerificationSheetPresented
            || legacyPrivateMediaConsentRequest != nil
            || isVoiceAlertPresented
            || isMediaPickerPresented
    }
}

struct ContentPeopleSheetView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var verificationModel: VerificationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @Environment(\.scenePhase) private var scenePhase

    @Binding var showSidebar: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?
    @State private var showVerifySheet = false
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void

    #if os(iOS)
    @Binding var showImagePicker: Bool
    @Binding var imagePickerSourceType: UIImagePickerController.SourceType
    #else
    @Binding var showMacImagePicker: Bool
    #endif

    private func modalPresentationState(
        includingVoiceAlert: Bool
    ) -> ContentPeopleSheetModalPresentationState {
        #if os(iOS)
        let isMediaPickerPresented = showImagePicker
        #else
        let isMediaPickerPresented = showMacImagePicker
        #endif

        return ContentPeopleSheetModalPresentationState(
            isImagePreviewPresented: imagePreviewURL != nil,
            isVerificationSheetPresented: showVerifySheet,
            legacyPrivateMediaConsentRequest:
                conversationUIModel.legacyPrivateMediaConsentRequest,
            isVoiceAlertPresented: includingVoiceAlert && voiceRecordingVM.showAlert,
            isMediaPickerPresented: isMediaPickerPresented
        )
    }

    private var hasModalPresentation: Bool {
        modalPresentationState(includingVoiceAlert: true).hasPresentation
    }

    /// The voice alert cannot defer to itself: its own binding must keep
    /// reporting `true` while it is the presented modal.
    private var hasModalPresentationBesidesVoiceAlert: Bool {
        modalPresentationState(includingVoiceAlert: false).hasPresentation
    }

    private var bluetoothAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && appChromeModel.showBluetoothAlert
                    && !hasModalPresentation
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasModalPresentation else {
                    return
                }
                appChromeModel.dismissBluetoothAlert()
            }
        )
    }

    /// Voice recording happens inside this sheet, so its error alert must
    /// present from here as well: the root copy defers whenever this sheet
    /// is up, exactly like the Bluetooth alert above. Presenting from the
    /// root instead would force-dismiss the sheet and end the conversation.
    private var voiceAlertBinding: Binding<Bool> {
        Binding(
            get: {
                scenePhase == .active
                    && voiceRecordingVM.showAlert
                    && !hasModalPresentationBesidesVoiceAlert
            },
            set: { isPresented in
                guard !isPresented,
                      scenePhase == .active,
                      !hasModalPresentationBesidesVoiceAlert else {
                    return
                }
                voiceRecordingVM.showAlert = false
            }
        )
    }

    var body: some View {
        let legacyConsentRequest = conversationUIModel.legacyPrivateMediaConsentRequest
        NavigationStack {
            Group {
                if privateConversationModel.selectedPeerID != nil {
                    #if os(iOS)
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        isTextFieldFocused: isTextFieldFocused,
                        voiceRecordingVM: voiceRecordingVM,
                        autocompleteDebounceTimer: $autocompleteDebounceTimer,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        showImagePicker: $showImagePicker,
                        imagePickerSourceType: $imagePickerSourceType
                    )
                    #else
                    ContentPrivateChatSheetView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet,
                        messageText: $messageText,
                        selectedMessageSender: $selectedMessageSender,
                        selectedMessageSenderID: $selectedMessageSenderID,
                        imagePreviewURL: $imagePreviewURL,
                        windowCountPublic: $windowCountPublic,
                        windowCountPrivate: $windowCountPrivate,
                        isAtBottomPrivate: $isAtBottomPrivate,
                        isTextFieldFocused: isTextFieldFocused,
                        voiceRecordingVM: voiceRecordingVM,
                        autocompleteDebounceTimer: $autocompleteDebounceTimer,
                        headerHeight: headerHeight,
                        onSendMessage: onSendMessage,
                        showMacImagePicker: $showMacImagePicker
                    )
                    #endif
                } else {
                    ContentPeopleListView(
                        showSidebar: $showSidebar,
                        showVerifySheet: $showVerifySheet
                    )
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { appChromeModel.showingFingerprintFor != nil && (showSidebar || privateConversationModel.selectedPeerID != nil) },
                set: { isPresented in
                    if !isPresented {
                        appChromeModel.clearFingerprint()
                    }
                }
            )) {
                if let peerID = appChromeModel.showingFingerprintFor {
                    FingerprintView(peerID: peerID)
                        .environmentObject(verificationModel)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: {
                    appChromeModel.showingNicknameFor != nil
                        && (showSidebar || privateConversationModel.selectedPeerID != nil)
                },
                set: { isPresented in
                    if !isPresented {
                        appChromeModel.clearNicknameEditor()
                    }
                }
            )) {
                if let peerID = appChromeModel.showingNicknameFor {
                    LocalNicknameSheetView(peerID: peerID)
                        .environmentObject(verificationModel)
                }
            }
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .sheet(isPresented: $showVerifySheet) {
            VerificationSheetView(isPresented: $showVerifySheet)
                .environmentObject(verificationModel)
        }
        .confirmationDialog(
            AppLanguageSettings.localized(
                 "content.private_media.legacy_warning.title",
                defaultValue: "Send without end-to-end encryption?",
                comment: "Title warning before sending private media to an older client in a clear signed envelope"
            ),
            isPresented: Binding(
                get: { legacyConsentRequest != nil },
                set: { isPresented in
                    if !isPresented, let requestID = legacyConsentRequest?.id {
                        conversationUIModel.resolveLegacyPrivateMediaConsent(
                            requestID: requestID,
                            approved: false
                        )
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(
                AppLanguageSettings.localized(
                     "content.private_media.legacy_warning.send",
                    defaultValue: "Send Visible File",
                    comment: "Destructive confirmation action for one legacy clear private-media send"
                ),
                role: .destructive
            ) {
                if let requestID = legacyConsentRequest?.id {
                    conversationUIModel.resolveLegacyPrivateMediaConsent(
                        requestID: requestID,
                        approved: true
                    )
                }
            }
            Button("common.cancel", role: .cancel) {
                if let requestID = legacyConsentRequest?.id {
                    conversationUIModel.resolveLegacyPrivateMediaConsent(
                        requestID: requestID,
                        approved: false
                    )
                }
            }
        } message: {
            if let request = legacyConsentRequest {
                Text(
                    String(
                        format: AppLanguageSettings.localized(
                             "content.private_media.legacy_warning.message",
                            defaultValue: "%@'s client does not advertise encrypted private media. This file will be signed but not end-to-end encrypted, so mesh relays can see it. Send this file anyway?",
                            comment: "Warning explaining the confidentiality loss for one legacy private-media send; parameter is the peer name"
                        ),
                        locale: .current,
                        request.peerName
                    )
                )
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { showImagePicker && (showSidebar || privateConversationModel.selectedPeerID != nil) },
            set: { newValue in
                if !newValue {
                    showImagePicker = false
                }
            }
        )) {
            ImagePickerView(sourceType: imagePickerSourceType) { image in
                showImagePicker = false
                conversationUIModel.processSelectedImage(image)
            }
            .ignoresSafeArea()
        }
        #endif
        #if os(macOS)
        .sheet(isPresented: $showMacImagePicker) {
            MacImagePickerView { url in
                showMacImagePicker = false
                conversationUIModel.processSelectedImage(from: url)
            }
        }
        #endif
        .alert("content.alert.recording_error.title", isPresented: voiceAlertBinding, actions: {
            Button("common.ok", role: .cancel) {}
            if voiceRecordingVM.state == .permissionDenied {
                Button("location_channels.action.open_settings") {
                    SystemSettings.microphone.open()
                }
            }
        }, message: {
            Text(voiceRecordingVM.state.alertMessage)
        })
        .alert(
            "content.alert.bluetooth_required.title",
            isPresented: bluetoothAlertBinding
        ) {
            Button("content.alert.bluetooth_required.settings") {
                SystemSettings.bluetooth.open()
            }
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(appChromeModel.bluetoothAlertMessage)
        }
    }
}

private struct ContentPeopleListView: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel
    @EnvironmentObject private var conversationUIModel: ConversationUIModel
    @EnvironmentObject private var locationChannelsModel: LocationChannelsModel
    @EnvironmentObject private var peerListModel: PeerListModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(peopleSheetTitle)
                        .bitchatFont(size: 18)
                        .foregroundColor(palette.primary)
                    Spacer()
                    if case .mesh = locationChannelsModel.selectedChannel {
                        Button(action: { showVerifySheet = true }) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.bitchatSystem(size: 14))
                        }
                        .buttonStyle(.plain)
                        // .help maps to the accessibility *hint* on iOS, so the
                        // button still needs a spoken name.
                        .accessibilityLabel(
                            AppLanguageSettings.localized("verification.qr.title", comment: "Accessibility label for the global QR screen")
                        )
                        .help(
                            AppLanguageSettings.localized("verification.scan.prompt_friend", comment: "Help text for the global QR scanner")
                        )
                    }
                    SheetCloseButton {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            dismiss()
                            showSidebar = false
                            showVerifySheet = false
                            privateConversationModel.endConversation()
                        }
                    }
                }

                // The mesh sheet titles its sections inline (#mesh / across
                // the bridge / groups) — no subtitle or count up here.
                // Location channels keep their geohash subtitle.
                if case .location(let channel) = locationChannelsModel.selectedChannel {
                    Text(verbatim: "#\(channel.geohash.lowercased())")
                        .bitchatFont(size: 12)
                        .foregroundColor(palette.locationAccent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .themedSurface()

            ScrollView {
                // spacing 0: every section supplies its own rhythm (header
                // top 12 / bottom 4, rows vertical 4), so inter-child spacing
                // here would make the first section's gap read differently.
                VStack(alignment: .leading, spacing: 0) {
                    if case .location = locationChannelsModel.selectedChannel {
                        GeohashPeopleList(
                            onTapPerson: {
                                showSidebar = true
                            }
                        )
                    } else {
                        PeopleSectionHeader(
                            icon: "antenna.radiowaves.left.and.right",
                            iconColor: palette.accentBlue,
                            title: "#mesh"
                        )
                        MeshPeerList(
                            onTapPeer: { peerID in
                                peerListModel.startConversation(with: peerID)
                                showSidebar = true
                            },
                            onRemoveFriend: { peerID in
                                peerListModel.removeFriend(peerID: peerID)
                            },
                            onShowFingerprint: { peerID in
                                appChromeModel.showFingerprint(for: peerID)
                            },
                            onAddFriend: { peerID in
                                _ = peerListModel.addFriend(peerID: peerID)
                            },
                            onSetNickname: { peerID in
                                appChromeModel.showNicknameEditor(for: peerID)
                            },
                            onToggleBlock: { peer in
                                if peer.isBlocked {
                                    conversationUIModel.unblock(peerID: peer.peerID, displayName: peer.displayName)
                                } else {
                                    conversationUIModel.block(peerID: peer.peerID, displayName: peer.displayName)
                                }
                            }
                        )
                        // People in this area but beyond radio range, and
                        // private groups: one sheet for the whole room.
                        BridgePeopleList()
                        GroupChatList(
                            groups: peerListModel.groupRows,
                            onTapGroup: { peerID in
                                peerListModel.startConversation(with: peerID)
                                showSidebar = true
                            }
                        )
                    }
                }
                .padding(.top, 4)
                // Full width even when every row is narrow (empty mesh, no
                // groups): without this the VStack hugs its widest child and
                // the ScrollView centers it — headers and empty states
                // floated mid-screen on iPhone.
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(peerListModel.renderID)
            }
        }
    }
}

private extension ContentPeopleListView {
    var peopleSheetTitle: String {
        AppLanguageSettings.localized("content.header.people", comment: "Title for the people list sheet")
    }

}

private struct ContentPrivateChatSheetView: View {
    @EnvironmentObject private var privateConversationModel: PrivateConversationModel

    @State private var pendingFriendAddition: FriendAdditionTarget?

    @Binding var showSidebar: Bool
    @Binding var showVerifySheet: Bool
    @Binding var messageText: String
    @Binding var selectedMessageSender: String?
    @Binding var selectedMessageSenderID: PeerID?
    @Binding var imagePreviewURL: URL?
    @Binding var windowCountPublic: Int
    @Binding var windowCountPrivate: [PeerID: Int]
    @Binding var isAtBottomPrivate: Bool
    var isTextFieldFocused: FocusState<Bool>.Binding
    @ObservedObject var voiceRecordingVM: VoiceRecordingViewModel
    @Binding var autocompleteDebounceTimer: Timer?
    @Environment(\.appTheme) private var theme
    @ThemedPalette private var palette

    let headerHeight: CGFloat
    let onSendMessage: () -> Void

    #if os(iOS)
    @Binding var showImagePicker: Bool
    @Binding var imagePickerSourceType: UIImagePickerController.SourceType
    #else
    @Binding var showMacImagePicker: Bool
    #endif

    var body: some View {
        VStack(spacing: 0) {
            if let headerState = privateConversationModel.selectedHeaderState {
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            privateConversationModel.endConversation()
                        }
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.bitchatSystem(size: 12))
                            .foregroundColor(palette.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AppLanguageSettings.localized("content.accessibility.back_to_main_chat", comment: "Accessibility label for returning to main chat")
                    )

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        ContentPrivateHeaderInfoButton(
                            headerState: headerState,
                            headerHeight: headerHeight
                        )

                        if headerState.supportsFriendAction {
                            Button(action: {
                                if headerState.isFavorite {
                                    privateConversationModel.removeFriendForSelectedConversation()
                                } else {
                                    pendingFriendAddition = FriendAdditionTarget(
                                        peerID: headerState.headerPeerID,
                                        displayName: headerState.displayName
                                    )
                                }
                            }) {
                                Image(
                                    systemName: headerState.isFavorite
                                        ? "star.fill"
                                        : "person.badge.plus"
                                )
                                    .font(.bitchatSystem(size: 14))
                                    .foregroundColor(headerState.isFavorite ? Color.yellow : palette.primary)
                                    // Same visual box + 44pt hit target as SheetCloseButton.
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle().inset(by: -6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                headerState.isFavorite
                                ? AppLanguageSettings.localized("content.accessibility.remove_favorite", comment: "Accessibility label to remove a favorite")
                                : AppLanguageSettings.localized("content.accessibility.add_favorite", comment: "Accessibility label to add a favorite")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Spacer(minLength: 0)

                    SheetCloseButton {
                        withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                            privateConversationModel.endConversation()
                            showSidebar = true
                        }
                    }
                }
                // minHeight so scaled text at accessibility sizes grows the
                // bar instead of clipping inside it.
                .frame(minHeight: headerHeight)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .modifier(PrivateHeaderChrome())
            }

            MessageListView(
                privatePeer: privateConversationModel.selectedPeerID,
                isAtBottom: $isAtBottomPrivate,
                messageText: $messageText,
                selectedMessageSender: $selectedMessageSender,
                selectedMessageSenderID: $selectedMessageSenderID,
                imagePreviewURL: $imagePreviewURL,
                windowCountPublic: $windowCountPublic,
                windowCountPrivate: $windowCountPrivate,
                showSidebar: $showSidebar,
                isTextFieldFocused: isTextFieldFocused
            )
            .themedSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Swipe-right-to-leave lives on the message list only. On the
            // whole sheet it preempted the composer's press-and-hold mic
            // gesture (a high-priority ancestor drag cancels child gestures
            // within milliseconds — same starvation as the image-reveal bug).
            .highPriorityGesture(swipeToLeaveGesture)

            if !theme.usesGlassChrome {
                Divider()
            }

            PrivateConversationPrivacyCaption(
                peerID: privateConversationModel.selectedPeerID,
                encryptionStatus: privateConversationModel
                    .selectedHeaderState?
                    .encryptionStatus
            )

            #if os(iOS)
            ContentComposerView(
                messageText: $messageText,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                onSendMessage: onSendMessage,
                showImagePicker: $showImagePicker,
                imagePickerSourceType: $imagePickerSourceType
            )
            #else
            ContentComposerView(
                messageText: $messageText,
                isTextFieldFocused: isTextFieldFocused,
                voiceRecordingVM: voiceRecordingVM,
                autocompleteDebounceTimer: $autocompleteDebounceTimer,
                onSendMessage: onSendMessage,
                showMacImagePicker: $showMacImagePicker
            )
            #endif
        }
        .themedSheetBackground()
        .foregroundColor(palette.primary)
        .sheet(
            item: $pendingFriendAddition,
            onDismiss: { pendingFriendAddition = nil }
        ) { target in
            FriendAdditionSheetView(target: target) { localNickname in
                privateConversationModel.addFriend(
                    peerID: target.peerID,
                    localNickname: localNickname
                )
            }
        }
    }

    private var swipeToLeaveGesture: some Gesture {
        DragGesture(minimumDistance: 25, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                guard horizontal > 80, vertical < 60 else { return }
                withAnimation(.easeInOut(duration: TransportConfig.uiAnimationMediumSeconds)) {
                    showSidebar = true
                    privateConversationModel.endConversation()
                }
            }
    }

}

/// Chrome for the private-chat header. Matrix keeps its orange privacy wash
/// over an opaque themed surface. Glass gets the same floating panel as the
/// main header instead: an orange wash over the backdrop gradient reads as a
/// muddy gray-beige band, and the DM signature is already carried by the
/// orange lock, caption, and composer accents.
private struct PrivateHeaderChrome: ViewModifier {
    @Environment(\.appTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.usesGlassChrome {
            content.themedChromePanel(edge: .top)
        } else {
            // Orange tint before themedSurface so it layers in front of the
            // opaque themed background rather than behind it.
            content
                .background(Color.orange.opacity(0.06))
                .themedSurface()
        }
    }
}

private struct ContentPrivateHeaderInfoButton: View {
    @EnvironmentObject private var appChromeModel: AppChromeModel
    @ThemedPalette private var palette

    let headerState: PrivateConversationHeaderState
    let headerHeight: CGFloat

    var body: some View {
        Button(action: {
            // A group has no single fingerprint to show.
            guard !headerState.isGroupConversation else { return }
            appChromeModel.showFingerprint(for: headerState.headerPeerID)
        }) {
            HStack(spacing: 6) {
                if headerState.isGroupConversation {
                    Image(systemName: "person.3.fill")
                        .font(.bitchatSystem(size: 14))
                        .foregroundColor(palette.primary)
                        .accessibilityLabel(AppLanguageSettings.localized("content.accessibility.group_chat", comment: "Accessibility label for the group chat indicator"))
                } else {
                    switch headerState.availability {
                    case .bluetoothConnected:
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(AppLanguageSettings.localized("content.accessibility.connected_mesh", comment: "Accessibility label for mesh-connected peer indicator"))
                    case .meshReachable:
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.primary)
                            .accessibilityLabel(AppLanguageSettings.localized("content.accessibility.reachable_mesh", comment: "Accessibility label for mesh-reachable peer indicator"))
                    case .nostrAvailable:
                        Image(systemName: "globe")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(.purple)
                            .accessibilityLabel(AppLanguageSettings.localized("content.accessibility.available_nostr", comment: "Accessibility label for Nostr-available peer indicator"))
                    case .offline:
                        // Slashed variant of the connected glyph — offline as
                        // the negation of connected, no text label (a leading
                        // one read as part of the name: "sin conexión bob").
                        // VoiceOver still says it.
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.bitchatSystem(size: 14))
                            .foregroundColor(palette.secondary)
                            .accessibilityLabel(AppLanguageSettings.localized("mesh_peers.state.offline", comment: "State label for a peer that is not currently reachable"))
                    }
                }

                Text(headerState.displayName)
                    .bitchatFont(size: 16, weight: .medium)
                    .foregroundColor(palette.primary)
                    // Middle truncation keeps the identity suffix visible on
                    // long nicknames instead of wrapping into the fixed-height
                    // header.
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let identityLockState = headerState.identityLockState {
                    Image(systemName: identityLockState.icon)
                        .font(.bitchatSystem(size: 14))
                        .offset(y: -1)
                        .foregroundColor(identityLockState.color)
                        .accessibilityLabel(identityLockState.accessibilityDescription)
                }

            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(contentPrivateHeaderAccessibilityLabel(for: headerState))
        .accessibilityHint(
            headerState.isGroupConversation
            ? ""
            : AppLanguageSettings.localized("content.accessibility.view_fingerprint_hint", comment: "Accessibility hint for viewing encryption fingerprint")
        )
        .frame(minHeight: headerHeight)
    }
}

func contentPrivateHeaderAccessibilityLabel(
    for headerState: PrivateConversationHeaderState
) -> String {
    let base = String(
        format: AppLanguageSettings.localized(
             "content.accessibility.private_chat_header",
            defaultValue: "Private Chat with %@",
            comment: "Accessibility label describing the private chat header"
        ),
        locale: .current,
        headerState.displayName
    )
    guard let identityLockState = headerState.identityLockState else {
        return base
    }
    return [base, identityLockState.accessibilityDescription]
        .joined(separator: ", ")
}
