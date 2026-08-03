import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Placeholder view to display the user's verification QR payload as text.
struct MyQRView: View {
    let qrString: String
    @Environment(\.colorScheme) var colorScheme
    @ThemedPalette private var palette
    // Palette-tinted so the box follows the theme (green under matrix)
    // instead of a fixed gray band over the glass gradient.
    private var boxColor: Color { palette.secondary.opacity(0.1) }

    private enum Strings {
        static let title: LocalizedStringKey = "verification.my_qr.title"
        static let accessibilityLabel = String(localized: "verification.my_qr.accessibility_label", comment: "Accessibility label describing the verification QR code")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(Strings.title)
                .bitchatFont(size: 16, weight: .bold)

            VStack(spacing: 10) {
                QRCodeImage(data: qrString, size: 240)
                    .accessibilityLabel(Strings.accessibilityLabel)

                // Non-scrolling, fully visible URL (wraps across lines)
                Text(qrString)
                    .bitchatFont(size: 11)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(boxColor)
                    .cornerRadius(8)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(boxColor)
            .cornerRadius(8)
        }
        .padding()
    }
}

// Render a QR code image for a given string using CoreImage
struct QRCodeImage: View {
    let data: String
    let size: CGFloat
    @ThemedPalette private var palette

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    private enum Strings {
        static let unavailable: LocalizedStringKey = "verification.my_qr.unavailable"
    }

    var body: some View {
        Group {
            if let image = generateImage() {
                ImageWrapper(image: image)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(Strings.unavailable)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    )
            }
        }
    }

    private func generateImage() -> CGImage? {
        let inputData = Data(data.utf8)
        filter.message = inputData
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(1, Int(size / 32))
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(transformed, from: transformed.extent)
    }
}

// Platform-specific wrapper to display CGImage in SwiftUI
struct ImageWrapper: View {
    let image: CGImage
    var body: some View {
        #if os(iOS)
        let ui = UIImage(cgImage: image)
        return Image(uiImage: ui)
            .interpolation(.none)
            .resizable()
        #else
        let ns = NSImage(cgImage: image, size: .zero)
        return Image(nsImage: ns)
            .interpolation(.none)
            .resizable()
        #endif
    }
}

/// Friend QR scanner with an always-available paste fallback on every platform.
struct QRScanView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @Environment(\.scenePhase) private var scenePhase
    @ThemedPalette private var palette
    var isActive: Bool = true
    var onCandidate: ((FriendVerificationCandidate) -> Void)? = nil
    @State private var input = ""
    @State private var cameraUnavailable = false

    private enum Strings {
        static let pastePrompt: LocalizedStringKey = "verification.scan.paste_prompt"
        static let validate: LocalizedStringKey = "verification.scan.validate"
        static let cameraUnavailable = String(
            localized: "verification.scan.camera_unavailable",
            defaultValue: "Camera unavailable — paste a QR below.",
            comment: "Shown over the scanner preview when no camera is available or permission was denied"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                CameraScannerView(
                    isActive: isActive && scenePhase == .active,
                    onUnavailable: { cameraUnavailable = true }
                ) { code in
                    handleScannedCode(code)
                }
                if cameraUnavailable {
                    Text(Strings.cameraUnavailable)
                        .bitchatFont(size: 13, weight: .medium)
                        .foregroundColor(palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(Strings.pastePrompt)
                .bitchatFont(size: 14, weight: .medium)
            TextEditor(text: $input)
                .bitchatFont(size: 12)
                .autocorrectionDisabled(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .frame(minHeight: 72, maxHeight: 100)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(palette.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(palette.secondary.opacity(0.25), lineWidth: 1)
                }
                .accessibilityIdentifier("friend-qr-paste-editor")
            Button(Strings.validate) {
                handleScannedCode(input)
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
    }

    private func handleScannedCode(_ rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        switch verificationModel.verifyScannedPayload(code) {
        case .candidate(let candidate):
            input = ""
            onCandidate?(candidate)
        case .rejected:
            break
        }
    }
}

#if os(iOS)
struct CameraScannerView: UIViewRepresentable {
    typealias UIViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.updateCallbacks(
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: CameraScannerCoordinator) {
        coordinator.tearDown(detaching: uiView.videoPreviewLayer)
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#elseif os(macOS)
struct CameraScannerView: NSViewRepresentable {
    typealias NSViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        context.coordinator.updateCallbacks(
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: CameraScannerCoordinator) {
        coordinator.tearDown(detaching: nsView.videoPreviewLayer)
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: NSView {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            videoPreviewLayer.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.addSublayer(videoPreviewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            videoPreviewLayer.frame = bounds
        }
    }
}
#endif

struct CameraScannerLifecycleState {
    private(set) var generation: UInt64 = 0
    private(set) var desiredActive = false
    private(set) var permissionGranted = false
    private(set) var isTornDown = true
    private(set) var codeDeliveryClaimed = false

    mutating func beginSetup() -> UInt64 {
        generation &+= 1
        desiredActive = false
        permissionGranted = false
        isTornDown = false
        codeDeliveryClaimed = false
        return generation
    }

    mutating func setPermissionGranted(_ granted: Bool, for generation: UInt64) -> Bool {
        guard self.generation == generation, !isTornDown else { return false }
        permissionGranted = granted
        return true
    }

    mutating func setActive(_ active: Bool) -> UInt64? {
        guard !isTornDown else { return nil }
        if active && !desiredActive {
            codeDeliveryClaimed = false
        }
        desiredActive = active
        return generation
    }

    mutating func claimCodeDelivery() -> UInt64? {
        guard !isTornDown,
              permissionGranted,
              desiredActive,
              !codeDeliveryClaimed else { return nil }
        codeDeliveryClaimed = true
        return generation
    }

    func canDeliverClaimedCode(for generation: UInt64) -> Bool {
        self.generation == generation
            && !isTornDown
            && permissionGranted
            && desiredActive
            && codeDeliveryClaimed
    }

    mutating func tearDown() -> Bool {
        guard !isTornDown else { return false }
        generation &+= 1
        desiredActive = false
        permissionGranted = false
        isTornDown = true
        codeDeliveryClaimed = false
        return true
    }
}

final class CameraScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private var onCode: ((String) -> Void)?
    private var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "chat.meshchat.qr-camera-session")
    private let metadataQueue = DispatchQueue(label: "chat.meshchat.qr-camera-metadata")
    private let lifecycleLock = NSLock()
    private var lifecycle = CameraScannerLifecycleState()
    private var didConfigureSession = false

    private func withLifecycleState<T>(
        _ body: (inout CameraScannerLifecycleState) -> T
    ) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body(&lifecycle)
    }

    private func lifecycleSnapshot() -> CameraScannerLifecycleState {
        withLifecycleState { $0 }
    }

    func setup(
        previewLayer: AVCaptureVideoPreviewLayer,
        onCode: @escaping (String) -> Void,
        onUnavailable: (() -> Void)? = nil
    ) {
        let generation = withLifecycleState { $0.beginSetup() }
        updateCallbacks(onCode: onCode, onUnavailable: onUnavailable)
        previewLayer.session = session

        // Check authorization before creating AVCaptureDeviceInput so tests and
        // cold launches do not trigger a TCC prompt just by constructing input.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if withLifecycleState({ $0.setPermissionGranted(true, for: generation) }) {
                prepareSession(for: generation)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let accepted = self.withLifecycleState {
                        $0.setPermissionGranted(granted, for: generation)
                    }
                    guard accepted else { return }
                    if granted {
                        self.prepareSession(for: generation)
                    } else {
                        self.reportUnavailable(for: generation)
                    }
                }
            }
        default:
            reportUnavailable(for: generation)
        }
    }

    func updateCallbacks(
        onCode: @escaping (String) -> Void,
        onUnavailable: (() -> Void)?
    ) {
        self.onCode = onCode
        self.onUnavailable = onUnavailable
    }

    private func prepareSession(for generation: UInt64) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let state = self.lifecycleSnapshot()
            guard state.generation == generation,
                  !state.isTornDown,
                  state.permissionGranted else { return }
            guard self.configureSessionIfNeeded() else {
                self.reportUnavailable(for: generation)
                return
            }
            self.reconcileSession(for: generation)
        }
    }

    @discardableResult
    private func configureSessionIfNeeded() -> Bool {
        guard !didConfigureSession else { return true }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.commitConfiguration()
            return false
        }
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()
        didConfigureSession = true
        return true
    }

    private func reportUnavailable(for generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let state = self.lifecycleSnapshot()
            guard state.generation == generation, !state.isTornDown else { return }
            self.onUnavailable?()
        }
    }

    func setActive(_ active: Bool) {
        let generation = withLifecycleState { $0.setActive(active) }
        guard let generation else { return }
        sessionQueue.async { [weak self] in
            self?.reconcileSession(for: generation)
        }
    }

    private func reconcileSession(for generation: UInt64) {
        let state = lifecycleSnapshot()
        guard state.generation == generation else { return }
        guard !state.isTornDown,
              state.permissionGranted,
              didConfigureSession else {
            if session.isRunning { session.stopRunning() }
            return
        }
        if state.desiredActive {
            if !session.isRunning { session.startRunning() }
        } else if session.isRunning {
            session.stopRunning()
        }
    }

    func tearDown(detaching previewLayer: AVCaptureVideoPreviewLayer) {
        let shouldTearDown = withLifecycleState { $0.tearDown() }
        guard shouldTearDown else { return }
        onCode = nil
        onUnavailable = nil
        let session = self.session
        sessionQueue.async {
            for output in session.outputs {
                if let metadataOutput = output as? AVCaptureMetadataOutput {
                    metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
                }
            }
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async {
                guard previewLayer.session === session else { return }
                previewLayer.session = nil
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for obj in metadataObjects {
            guard let m = obj as? AVMetadataMachineReadableCodeObject,
                  m.type == .qr,
                  let str = m.stringValue else { continue }
            let code = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { continue }
            guard let generation = withLifecycleState({ $0.claimCodeDelivery() }) else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let shouldDeliver = self.withLifecycleState {
                    $0.canDeliverClaimedCode(for: generation)
                }
                guard shouldDeliver else { return }
                self.onCode?(code)
            }
            return
        }
    }
}

/// Global identity QR sheet. Contact, nickname, and verification actions are
/// independent so none of them silently upgrades another state.
struct VerificationSheetView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @Binding var isPresented: Bool
    @State private var mode: Mode = .myQR
    @State private var friendNickname = ""
    @State private var loadedCandidateID: String?
    @State private var nicknameFeedback: NicknameFeedback?
    @State private var friendAddFailed = false
    @ThemedPalette private var palette

    private var accentColor: Color { palette.accent }
    private var boxColor: Color { palette.secondary.opacity(0.1) }

    private enum Mode {
        case scan
        case myQR
    }

    private enum NicknameFeedback {
        case saved
        case invalid
        case persistenceFailed
    }

    private enum Strings {
        static let localNickname = String(
            localized: "fingerprint.local_alias.label",
            defaultValue: "Local Nickname",
            comment: "Label for a device-local nickname field"
        )
        static let localNicknamePlaceholder = String(
            localized: "fingerprint.local_alias.placeholder",
            defaultValue: "Nickname on this device",
            comment: "Placeholder for a device-local nickname field"
        )
        static let localNicknameHint = String(
            localized: "fingerprint.local_alias.hint",
            defaultValue: "Saved only on this device. This person will not see it.",
            comment: "Privacy explanation under a local nickname field"
        )
        static let invalidNickname: LocalizedStringKey = "fingerprint.local_alias.invalid"
        static let nicknameSaved: LocalizedStringKey = "fingerprint.local_alias.saved"
        static let save: LocalizedStringKey = "save"
        static let addFriend: LocalizedStringKey = "friends.action.add"
        static let friendAdded: LocalizedStringKey = "verification.friend.added"
        static let friendAddFailed: LocalizedStringKey = "verification.scan.status.persistence_failed"
        static let verifyEncryption: LocalizedStringKey = "fingerprint.action.mark_verified"
        static let done: LocalizedStringKey = "common.done"
        static let tryAgain: LocalizedStringKey = "common.try_again"

        static func verifying(_ name: String) -> String {
            String(
                format: String(
                    localized: "verification.scan.status.requested",
                    comment: "Progress text while verifying a friend's encryption identity"
                ),
                locale: .current,
                name
            )
        }

        static func verified(_ name: String) -> String {
            String(
                format: String(
                    localized: "verification.scan.status.verified",
                    defaultValue: "%@'s encryption identity is verified.",
                    comment: "Success text after a signed encryption verification response"
                ),
                locale: .current,
                name
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top header (always at top)
            HStack {
                if mode == .scan,
                   verificationModel.friendVerificationState != .idle {
                    Button(action: resetAndScan) {
                        Image(systemName: "chevron.left")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("verification.scan.prompt_friend")
                }
                Text("verification.qr.title")
                    .bitchatFont(size: 14, weight: .bold)
                    .foregroundColor(accentColor)
                Spacer()
                SheetCloseButton { isPresented = false }
                    .foregroundColor(accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            Picker("", selection: $mode) {
                Text("verification.tabs.my_qr")
                    .tag(Mode.myQR)
                Text("verification.tabs.scan")
                    .tag(Mode.scan)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("verification.qr.title")
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollView {
                sheetContent
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .themedSheetBackground()
        .onAppear {
            syncCandidate(verificationModel.friendCandidate)
        }
        .onChange(of: verificationModel.friendCandidate?.id) { _ in
            syncCandidate(verificationModel.friendCandidate)
        }
        .onDisappear {
            verificationModel.resetFriendVerificationFlow()
            friendNickname = ""
            loadedCandidateID = nil
            nicknameFeedback = nil
            friendAddFailed = false
            mode = .myQR
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if mode == .myQR {
            // Bitchat verification QR timestamps are valid for five minutes.
            // Re-evaluate well inside that window so a sheet left open never
            // keeps presenting an expired, otherwise correctly signed code.
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                MyQRView(qrString: verificationModel.myQRString())
            }
        } else {
            scanFlowContent
        }
    }

    private var scanFlowContent: some View {
        ZStack(alignment: .top) {
            scannerContent
                .opacity(showsScanner ? 1 : 0)
                .allowsHitTesting(showsScanner)
                .accessibilityHidden(!showsScanner)

            switch verificationModel.friendVerificationState {
            case .idle:
                EmptyView()
            case .ready:
                if let candidate = verificationModel.friendCandidate {
                    confirmationContent(candidate: candidate)
                }
            case .verifying:
                progressContent
            case .verified(_, let displayName):
                successContent(displayName: displayName)
            case .failed(let failure):
                failureContent(failure)
            }
        }
    }

    private var showsScanner: Bool {
        verificationModel.friendVerificationState == .idle
            || (verificationModel.friendVerificationState == .ready
                && verificationModel.friendCandidate == nil)
    }

    private var scannerContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("verification.scan.prompt_friend")
                .bitchatFont(size: 16, weight: .bold)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .foregroundColor(accentColor)
            QRScanView(
                isActive: mode == .scan && verificationModel.friendVerificationState == .idle,
                onCandidate: { syncCandidate($0) }
            )
            .environmentObject(verificationModel)
            .frame(minHeight: 390)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(boxColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func confirmationContent(candidate: FriendVerificationCandidate) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 52, weight: .medium))
                .foregroundColor(accentColor)
                .accessibilityHidden(true)

            Text(verbatim: candidate.claimedNickname)
                .bitchatFont(size: 22, weight: .bold)
                .multilineTextAlignment(.center)

            Text(verbatim: fingerprintSummary(candidate.fingerprint))
                .bitchatFont(size: 12)
                .foregroundColor(palette.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: Strings.localNickname)
                    .bitchatFont(size: 12, weight: .semibold)
                    .foregroundColor(palette.secondary)

                TextField(Strings.localNicknamePlaceholder, text: $friendNickname)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .onSubmit { saveLocalNickname(candidate) }
                    .accessibilityIdentifier("friend-nickname-field")

                Text(verbatim: Strings.localNicknameHint)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)

                if let nicknameFeedback {
                    Label(
                        nicknameFeedbackText(nicknameFeedback),
                        systemImage: nicknameFeedback == .saved
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                        .bitchatFont(size: 11, weight: .medium)
                        .foregroundColor(nicknameFeedback == .saved ? .green : .orange)
                }

                Button(Strings.save) {
                    saveLocalNickname(candidate)
                }
                .buttonStyle(.bordered)
                .disabled(!nicknameHasChanges(candidate))
            }

            if verificationModel.isFriend(candidate) {
                Label(Strings.friendAdded, systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundColor(.green)
                    .bitchatFont(size: 13, weight: .semibold)
            } else {
                Button {
                    addFriend(candidate)
                } label: {
                    Label(Strings.addFriend, systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("confirm-add-friend")
            }

            if friendAddFailed {
                Label(Strings.friendAddFailed, systemImage: "exclamationmark.circle.fill")
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(.orange)
            }

            Button(action: startVerification) {
                Label(Strings.verifyEncryption, systemImage: "checkmark.shield")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("verify-encryption")
        }
        .padding(24)
        .background(boxColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progressContent: some View {
        statusContent(
            icon: nil,
            title: Strings.verifying(candidateDisplayName),
            color: accentColor,
            showsProgress: true
        )
    }

    private func successContent(displayName: String) -> some View {
        VStack(spacing: 18) {
            statusContent(
                icon: "checkmark.circle.fill",
                title: Strings.verified(displayName),
                color: .green,
                showsProgress: false
            )
            if let candidate = verificationModel.friendCandidate,
               !verificationModel.isFriend(candidate) {
                Button {
                    addFriend(candidate)
                } label: {
                    Label(Strings.addFriend, systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if friendAddFailed {
                Label(Strings.friendAddFailed, systemImage: "exclamationmark.circle.fill")
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(.orange)
            }
            Button(Strings.done) { isPresented = false }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func failureContent(_ failure: FriendVerificationFailure) -> some View {
        VStack(spacing: 18) {
            statusContent(
                icon: isIdentityMismatch(failure)
                    ? "lock.fill"
                    : "exclamationmark.triangle.fill",
                title: failureMessage(failure),
                color: isIdentityMismatch(failure)
                    ? IdentityLockState.identityMismatch.color
                    : .orange,
                showsProgress: false
            )
            Button(Strings.tryAgain) { resetAndScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func statusContent(
        icon: String?,
        title: String,
        color: Color,
        showsProgress: Bool
    ) -> some View {
        VStack(spacing: 18) {
            if showsProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(color)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundColor(color)
                    .accessibilityHidden(true)
            }
            Text(verbatim: title)
                .bitchatFont(size: 16, weight: .semibold)
                .multilineTextAlignment(.center)
                .foregroundColor(palette.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(24)
        .background(boxColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var candidateDisplayName: String {
        let local = friendNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !local.isEmpty { return local }
        return verificationModel.friendCandidate?.claimedNickname ?? ""
    }

    private func syncCandidate(_ candidate: FriendVerificationCandidate?) {
        guard let candidate, loadedCandidateID != candidate.id else { return }
        loadedCandidateID = candidate.id
        friendNickname = candidate.existingLocalPetname ?? ""
        nicknameFeedback = nil
        friendAddFailed = false
        mode = .scan
    }

    private func startVerification() {
        _ = verificationModel.startEncryptionVerification()
    }

    private func addFriend(_ candidate: FriendVerificationCandidate) {
        friendAddFailed = !verificationModel.addFriendFromCandidate()
    }

    private func saveLocalNickname(_ candidate: FriendVerificationCandidate) {
        let normalized = friendNickname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmedOrNilIfEmpty
        if let normalized, InputValidator.validateNickname(normalized) == nil {
            nicknameFeedback = .invalid
            return
        }
        let saved = verificationModel.setLocalPetname(
            normalized,
            for: candidate
        )
        nicknameFeedback = saved ? .saved : .persistenceFailed
    }

    private func nicknameFeedbackText(
        _ feedback: NicknameFeedback
    ) -> LocalizedStringKey {
        switch feedback {
        case .saved:
            return Strings.nicknameSaved
        case .invalid:
            return Strings.invalidNickname
        case .persistenceFailed:
            return Strings.friendAddFailed
        }
    }

    private func nicknameHasChanges(_ candidate: FriendVerificationCandidate) -> Bool {
        friendNickname.trimmingCharacters(in: .whitespacesAndNewlines)
            != (candidate.existingLocalPetname ?? "")
    }

    private func fingerprintSummary(_ fingerprint: String) -> String {
        let normalized = fingerprint.uppercased()
        guard normalized.count > 16 else { return normalized }
        return "\(normalized.prefix(8))…\(normalized.suffix(8))"
    }

    private func resetAndScan() {
        verificationModel.resetFriendVerificationFlow()
        friendNickname = ""
        loadedCandidateID = nil
        nicknameFeedback = nil
        friendAddFailed = false
        mode = .scan
    }

    private func failureMessage(_ failure: FriendVerificationFailure) -> String {
        switch failure {
        case .invalidPayload, .invalidResponse:
            return String(localized: "verification.scan.status.invalid")
        case .expiredPayload:
            return String(localized: "verification.scan.status.expired")
        case .invalidLocalPetname:
            return String(localized: "fingerprint.local_alias.invalid")
        case .selfIdentity:
            return String(localized: "verification.scan.status.self")
        case .blocked:
            return String(localized: "verification.scan.status.blocked")
        case .signingKeyMismatch, .activeSessionMismatch:
            return String(localized: "verification.scan.status.identity_mismatch")
        case .peerNotFound, .peerUnavailable:
            return String(localized: "verification.scan.status.no_peer")
        case .persistenceRejected:
            return String(localized: "verification.scan.status.persistence_failed")
        case .timedOut:
            return String(localized: "verification.scan.status.timed_out")
        }
    }

    private func isIdentityMismatch(
        _ failure: FriendVerificationFailure
    ) -> Bool {
        switch failure {
        case .signingKeyMismatch, .activeSessionMismatch:
            return true
        default:
            return false
        }
    }
}
