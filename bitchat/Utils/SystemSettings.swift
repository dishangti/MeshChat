//
// SystemSettings.swift
// bitchat
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SystemSettings {
    case bluetooth
    case location
    case microphone
    case notifications

    #if os(macOS)
    private var macURLStrings: [String] {
        switch self {
        case .bluetooth:
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]
        case .location:
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"]
        case .microphone:
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
        case .notifications:
            [
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                "x-apple.systempreferences:"
            ]
        }
    }
    #endif

    func open() {
        #if os(iOS)
        let urlString: String
        switch self {
        case .notifications:
            urlString = UIApplication.openNotificationSettingsURLString
        case .bluetooth, .location, .microphone:
            urlString = UIApplication.openSettingsURLString
        }
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        for urlString in macURLStrings {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return
            }
        }
        #endif
    }
}
