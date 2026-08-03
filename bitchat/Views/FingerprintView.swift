//
// FingerprintView.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import SwiftUI
import BitFoundation

struct FingerprintView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    let peerID: PeerID
    @Environment(\.dismiss) var dismiss
    @ThemedPalette private var palette
    @State private var aliasDraft: String = ""
    @State private var didLoadAlias = false
    @State private var aliasSaveFeedback: AliasSaveFeedback?

    private var textColor: Color { palette.primary }

    private enum Strings {
        static let title: LocalizedStringKey = "fingerprint.title"
        static let theirFingerprint: LocalizedStringKey = "fingerprint.their_label"
        static let handshakePending: LocalizedStringKey = "fingerprint.handshake_pending"
        static let yourFingerprint: LocalizedStringKey = "fingerprint.your_label"
        static let copy: LocalizedStringKey = "common.copy"
        static let verifiedBadge: LocalizedStringKey = "fingerprint.badge.verified"
        static let notVerifiedBadge: LocalizedStringKey = "fingerprint.badge.not_verified"
        static let verifiedMessage: LocalizedStringKey = "fingerprint.message.verified"
        static var localAlias: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.label",
            defaultValue: "Local Nickname",
            comment: "Label for a device-local nickname field"
            )
        }
        static var localAliasPlaceholder: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.placeholder",
            defaultValue: "Nickname on this device",
            comment: "Placeholder for a device-local nickname field"
            )
        }
        static var localAliasHint: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.hint",
            defaultValue: "Saved only on this device. This person will not see it.",
            comment: "Privacy explanation under a local nickname field"
            )
        }
        static let localAliasSaved: LocalizedStringKey = "fingerprint.local_alias.saved"
        static let localAliasInvalid: LocalizedStringKey = "fingerprint.local_alias.invalid"
        static let save: LocalizedStringKey = "save"
        static func verifyHint(_ nickname: String) -> String {
            String(
                format: AppLanguageSettings.localized("fingerprint.message.verify_hint", comment: "Instruction to compare fingerprints with a named peer"),
                locale: .current,
                nickname
            )
        }
        static let markVerified: LocalizedStringKey = "fingerprint.action.mark_verified"
        static let removeVerification: LocalizedStringKey = "fingerprint.action.remove_verification"
        static let vouchedBadge: LocalizedStringKey = "fingerprint.badge.vouched"
        static func vouchedBy(_ count: Int) -> String {
            String(
                format: AppLanguageSettings.localized("fingerprint.message.vouched_by", comment: "How many people the user verified have vouched for this peer"),
                locale: .current,
                count
            )
        }
    }
    
    var body: some View {
        let fingerprintState = verificationModel.fingerprintPresentation(for: peerID)

        VStack(spacing: 20) {
            // Header
            HStack {
                Text(Strings.title)
                    .bitchatFont(size: 16, weight: .bold)
                    .foregroundColor(textColor)
                
                Spacer()
                
                SheetCloseButton { dismiss() }
                    .foregroundColor(textColor)
            }
            .padding()
            
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: fingerprintState.identityLockState.icon)
                        .font(.bitchatSystem(size: 20))
                        .foregroundColor(fingerprintState.identityLockState.color)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fingerprintState.peerNickname)
                            .bitchatFont(size: 18, weight: .semibold)
                            .foregroundColor(textColor)
                        
                        Text(verbatim: fingerprintState.identityLockState.accessibilityDescription)
                            .bitchatFont(size: 12)
                            .foregroundColor(textColor.opacity(0.7))
                    }
                    
                    Spacer()
                }
                .padding()
                .background(palette.secondary.opacity(0.1))
                .cornerRadius(8)

                if fingerprintState.canEditLocalAlias {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: Strings.localAlias)
                            .bitchatFont(size: 12, weight: .bold)
                            .foregroundColor(textColor.opacity(0.7))

                        HStack(spacing: 8) {
                            TextField(Strings.localAliasPlaceholder, text: $aliasDraft)
                                .bitchatFont(size: 14)
                                .foregroundColor(textColor)
                                .padding(10)
                                .background(palette.secondary.opacity(0.1))
                                .cornerRadius(8)
                                .onSubmit { commitAlias(showFeedback: true) }
                                .onChange(of: aliasDraft) { _ in
                                    aliasSaveFeedback = nil
                                }

                            Button(Strings.save) {
                                commitAlias(showFeedback: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!aliasHasChanges(in: fingerprintState))
                        }

                        Text(verbatim: Strings.localAliasHint)
                            .bitchatFont(size: 11)
                            .foregroundColor(textColor.opacity(0.6))

                        if let aliasSaveFeedback {
                            Label(
                                aliasSaveFeedback == .saved
                                    ? Strings.localAliasSaved
                                    : Strings.localAliasInvalid,
                                systemImage: aliasSaveFeedback == .saved
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.circle.fill"
                            )
                            .bitchatFont(size: 11, weight: .medium)
                            .foregroundColor(aliasSaveFeedback == .saved ? .green : .orange)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                
                // Their fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.theirFingerprint)
                        .bitchatFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    if let fingerprint = fingerprintState.theirFingerprint {
                        Text(formatFingerprint(fingerprint))
                            .bitchatFont(size: 14)
                            .foregroundColor(textColor)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(palette.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .contextMenu {
                                Button(Strings.copy) {
                                    #if os(iOS)
                                    UIPasteboard.general.string = fingerprint
                                    #else
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(fingerprint, forType: .string)
                                    #endif
                                }
                            }
                    } else {
                        Text(Strings.handshakePending)
                            .bitchatFont(size: 14)
                            .foregroundColor(Color.orange)
                            .padding()
                    }
                }

                // My fingerprint
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.yourFingerprint)
                        .bitchatFont(size: 12, weight: .bold)
                        .foregroundColor(textColor.opacity(0.7))
                    
                    Text(formatFingerprint(fingerprintState.myFingerprint))
                        .bitchatFont(size: 14)
                        .foregroundColor(textColor)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(palette.secondary.opacity(0.1))
                        .cornerRadius(8)
                        .contextMenu {
                            Button(Strings.copy) {
                                #if os(iOS)
                                UIPasteboard.general.string = fingerprintState.myFingerprint
                                #else
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fingerprintState.myFingerprint, forType: .string)
                                #endif
                            }
                        }
                }
                
                // Vouched (transitively verified) status is suppressed while
                // conflicting identity data is active, so positive trust
                // signals never compete with the suspicious-data state.
                if fingerprintState.isVouched && !fingerprintState.isVerified {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal")
                                .font(.bitchatSystem(size: 14))
                                .foregroundColor(.teal)
                            Text(Strings.vouchedBadge)
                                .bitchatFont(size: 14, weight: .bold)
                                .foregroundColor(.teal)
                        }
                        .frame(maxWidth: .infinity)

                        Text(Strings.vouchedBy(fingerprintState.voucherCount))
                            .bitchatFont(size: 12)
                            .foregroundColor(textColor.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        if !fingerprintState.voucherNames.isEmpty {
                            Text(fingerprintState.voucherNames.joined(separator: ", "))
                                .bitchatFont(size: 12)
                                .foregroundColor(textColor.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                }

                // Verification status
                if fingerprintState.showsVerificationStatus {
                    VStack(spacing: 12) {
                        Text(verbatim: fingerprintState.identityLockState.accessibilityDescription)
                            .bitchatFont(size: 14, weight: .bold)
                            .foregroundColor(fingerprintState.identityLockState.color)
                            .frame(maxWidth: .infinity)
                        
                        Group {
                            if fingerprintState.identityLockState
                                == .identityMismatch {
                                Text("meshchat.help.verification.description")
                            } else if fingerprintState.isVerified {
                                Text(Strings.verifiedMessage)
                            } else {
                                Text(Strings.verifyHint(fingerprintState.peerNickname))
                            }
                        }
                            .bitchatFont(size: 12)
                            .foregroundColor(textColor.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                        
                        if fingerprintState.canToggleVerification {
                            if !fingerprintState.isVerified {
                                Button(action: {
                                    verificationModel.verifyFingerprint(for: peerID)
                                    dismiss()
                                }) {
                                    Text(Strings.markVerified)
                                        .bitchatFont(size: 14, weight: .bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.green)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            } else {
                                Button(action: {
                                    verificationModel.unverifyFingerprint(for: peerID)
                                    dismiss()
                                }) {
                                    Text(Strings.removeVerification)
                                        .bitchatFont(size: 14, weight: .bold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 10)
                                        .background(Color.red)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    .padding(.top)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: 500) // Constrain max width for better readability
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedSheetBackground()
        .onAppear {
            syncAliasDraft(from: fingerprintState, force: true)
        }
        .onChange(of: fingerprintState.theirFingerprint) { _ in
            // Fingerprint can arrive after the sheet opens; load (or reload)
            // the saved alias then, otherwise an empty draft looks like a clear.
            syncAliasDraft(from: fingerprintState, force: false)
        }
        .onDisappear {
            commitAlias(showFeedback: false)
        }
    }

    /// Populate `aliasDraft` from the persisted petname once we know the
    /// fingerprint. `force` reloads even if we already loaded (onAppear).
    private func syncAliasDraft(from state: FingerprintPresentationState, force: Bool) {
        guard state.canEditLocalAlias else { return }
        if didLoadAlias && !force { return }
        aliasDraft = state.localPetname ?? ""
        didLoadAlias = true
    }

    private func aliasHasChanges(in state: FingerprintPresentationState) -> Bool {
        guard didLoadAlias else { return false }
        return aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            != (state.localPetname ?? "")
    }

    private func commitAlias(showFeedback: Bool) {
        let fingerprintState = verificationModel.fingerprintPresentation(for: peerID)
        guard fingerprintState.canEditLocalAlias else { return }
        // Don't treat "never loaded a draft" as an intentional clear.
        guard didLoadAlias else { return }
        let current = fingerprintState.localPetname ?? ""
        let draft = aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft != current else { return }
        let saved = verificationModel.setLocalPetname(
            draft.isEmpty ? nil : draft,
            for: peerID
        )
        if showFeedback {
            aliasSaveFeedback = saved ? .saved : .invalid
        }
    }
    
    private func formatFingerprint(_ fingerprint: String) -> String {
        // Convert to uppercase and format into 4 lines (4 groups of 4 on each line)
        let uppercased = fingerprint.uppercased()
        var formatted = ""
        
        for (index, char) in uppercased.enumerated() {
            // Add space every 4 characters (but not at the start)
            if index > 0 && index % 4 == 0 {
                // Add newline after every 16 characters (4 groups of 4)
                if index % 16 == 0 {
                    formatted += "\n"
                } else {
                    formatted += " "
                }
            }
            formatted += String(char)
        }
        
        return formatted
    }
}

private extension FingerprintView {
    enum AliasSaveFeedback {
        case saved
        case invalid
    }
}

/// A focused local-nickname editor available for every known mesh identity,
/// regardless of friend or verification state.
struct LocalNicknameSheetView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @Environment(\.dismiss) private var dismiss
    @ThemedPalette private var palette

    let peerID: PeerID

    @State private var draft = ""
    @State private var didLoad = false
    @State private var feedback: Feedback?

    private enum Feedback {
        case saved
        case invalid
    }

    private enum Strings {
        static let title: LocalizedStringKey = "fingerprint.local_alias.label"
        static var placeholder: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.placeholder",
            defaultValue: "Nickname on this device",
            comment: "Placeholder for a device-local nickname field"
            )
        }
        static var hint: String {
            AppLanguageSettings.localized(
             "fingerprint.local_alias.hint",
            defaultValue: "Saved only on this device. This person will not see it.",
            comment: "Privacy explanation under a local nickname field"
            )
        }
        static let save: LocalizedStringKey = "save"
        static let saved: LocalizedStringKey = "fingerprint.local_alias.saved"
        static let invalid: LocalizedStringKey = "fingerprint.local_alias.invalid"
    }

    var body: some View {
        let state = verificationModel.fingerprintPresentation(for: peerID)

        VStack(spacing: 20) {
            HStack {
                Text(Strings.title)
                    .bitchatFont(size: 16, weight: .bold)
                Spacer()
                SheetCloseButton { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: state.peerNickname)
                    .bitchatFont(size: 18, weight: .semibold)

                TextField(Strings.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                    .onSubmit(save)
                    .onChange(of: draft) { _ in feedback = nil }
                    .accessibilityIdentifier("local-nickname-field")

                Text(verbatim: Strings.hint)
                    .bitchatFont(size: 11)
                    .foregroundColor(palette.secondary)

                if let feedback {
                    Label(
                        feedback == .saved ? Strings.saved : Strings.invalid,
                        systemImage: feedback == .saved
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .bitchatFont(size: 11, weight: .medium)
                    .foregroundColor(feedback == .saved ? .green : .orange)
                }
            }

            Button(Strings.save, action: save)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!hasChanges(from: state))

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 460, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .themedSheetBackground()
        .onAppear { load(from: state) }
        .onChange(of: state.theirFingerprint) { _ in load(from: state) }
    }

    private func load(from state: FingerprintPresentationState) {
        guard state.canEditLocalAlias, !didLoad else { return }
        draft = state.localPetname ?? ""
        didLoad = true
    }

    private func hasChanges(from state: FingerprintPresentationState) -> Bool {
        didLoad && draft.trimmingCharacters(in: .whitespacesAndNewlines)
            != (state.localPetname ?? "")
    }

    private func save() {
        guard didLoad else { return }
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = verificationModel.setLocalPetname(
            normalized.isEmpty ? nil : normalized,
            for: peerID
        )
        feedback = saved ? .saved : .invalid
    }
}
