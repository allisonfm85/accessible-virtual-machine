//
//  USBDevicePickerView.swift
//  AVM
//
//  The USB device picker sheet (increment 2a, 2026-09-12). One sheet,
//  two modes: attach lists the devices the Mac can see, detach lists
//  the devices AVM has redirected. ContentView decides whether to open
//  it at all (an empty list is spoken, never shown, the Reclaim rule).
//
//  VoiceOver: a radio group, product string as the label, vendor:product
//  and bus/address in the hint. The first device is preselected so the
//  common case (one device, one intent) is Return, then done. Preselection
//  is safe here because attaching is reversible; Reclaim's never-list
//  rule exists because trashing is not.
//
//  The action button is always enabled (house rule: a grayed button is
//  a silent riddle). With nothing selected it says so instead.
//

import SwiftUI

struct USBDevicePickerView: View {

    enum Mode {
        case attach
        case detach

        var title: String {
            switch self {
            case .attach: return "Attach USB Device"
            case .detach: return "Detach USB Device"
            }
        }

        var instruction: String {
            switch self {
            case .attach: return "Choose a device to use inside the virtual machine. The Mac stops seeing it until you detach it."
            case .detach: return "Choose a device to return to the Mac."
            }
        }

        /// The device list's name, spoken by VoiceOver (2026-10-26,
        /// accessibility audit: "Device, radio group" didn't say what for).
        var listLabel: String {
            switch self {
            case .attach: return "Device to attach"
            case .detach: return "Device to return to the Mac"
            }
        }

        var actionTitle: String {
            switch self {
            case .attach: return "Attach"
            case .detach: return "Detach"
            }
        }
    }

    let mode: Mode
    let devices: [AVMUSBDeviceIdentity]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: AVMUSBDeviceIdentity?

    /// A device's name in the list, with its ID, bus and address when
    /// another device has the same name.
    private func menuName(_ device: AVMUSBDeviceIdentity) -> String {
        guard devices.filter({ $0.displayName == device.displayName }).count > 1 else { return device.displayName }
        return "\(device.displayName), ID \(device.vidPidString), bus \(device.busNumber), address \(device.deviceAddress)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text(mode.title)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)

            Text(mode.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            // A pop-up (2026-10-27, ChoiceGroup.swift). A menu item can't
            // carry a hint, so two devices with the same name say their ID,
            // bus and address in it, to tell them apart.
            Picker(mode.listLabel, selection: $selected) {
                Text("Choose a device").tag(nil as AVMUSBDeviceIdentity?)
                ForEach(devices, id: \.description) { device in
                    Text(menuName(device)).tag(device as AVMUSBDeviceIdentity?)
                }
            }
            .choicePopUp("Opens the list of \(devices.count == 1 ? "one device" : "\(devices.count) devices"). Choose one, then \(mode.actionTitle).")

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(mode.actionTitle) {
                    guard let device = selected else {
                        Announcer.shared.announce("No device is selected. Choose one first.", tone: .info)
                        return
                    }
                    AVMLog.write("USBDevicePickerView: \(mode.actionTitle) \(device.description)", category: "USBHelper")
                    dismiss()
                    Task { @MainActor in
                        switch mode {
                        case .attach: await USBRedirectController.shared.attach(device)
                        case .detach: await USBRedirectController.shared.detach(device)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460)
        // Nothing chosen until the user chooses (2026-10-26, code audit):
        // with the first device preselected, Return could send the Mac's
        // own USB keyboard to the machine.
        .onAppear {
            selected = devices.count == 1 && mode == .detach ? devices.first : nil
        }
    }
}
