import CoreBluetooth
import Foundation

struct ChatBluetoothAlertUpdate: Equatable {
    let isPresented: Bool
    let message: String?
}

enum ChatBluetoothAlertPolicy {
    static func update(for state: CBManagerState) -> ChatBluetoothAlertUpdate {
        switch state {
        case .poweredOff:
            // Bluetooth only provides the nearby mesh transport. Internet
            // messaging remains available, so this must not block the app or
            // claim that Bluetooth is required.
            ChatBluetoothAlertUpdate(isPresented: false, message: "")
        case .unauthorized:
            ChatBluetoothAlertUpdate(
                isPresented: true,
                message: AppLanguageSettings.localized("content.alert.bluetooth_required.permission", comment: "Message shown when Bluetooth permission is missing")
            )
        case .unsupported:
            ChatBluetoothAlertUpdate(
                isPresented: true,
                message: AppLanguageSettings.localized("content.alert.bluetooth_required.unsupported", comment: "Message shown when the device lacks Bluetooth support")
            )
        case .poweredOn:
            ChatBluetoothAlertUpdate(isPresented: false, message: "")
        case .unknown, .resetting:
            ChatBluetoothAlertUpdate(isPresented: false, message: nil)
        @unknown default:
            ChatBluetoothAlertUpdate(isPresented: false, message: nil)
        }
    }
}
