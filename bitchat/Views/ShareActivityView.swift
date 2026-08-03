//
// ShareActivityView.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

import SwiftUI

/// Hosts the system share UI after an optional OpSec confirmation (#1497).
struct ShareActivityView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(iOS)
        ShareActivityController(items: [text])
            .ignoresSafeArea()
        #elseif os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                ShareLink(item: text) {
                    Label(
                        AppLanguageSettings.localized("channel.share.action", defaultValue: "Share Channel", comment: "Button that opens the system share sheet for a location channel invite"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                Button(AppLanguageSettings.localized("common.done", defaultValue: "Done", comment: "Dismisses a sheet")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 360)
        #endif
    }
}

#if os(iOS)
import UIKit

private struct ShareActivityController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
