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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text(mode.title)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)

            Text(mode.instruction)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Device", selection: $selected) {
                ForEach(devices, id: \.description) { device in
                    Text(device.displayName)
                        .accessibilityHint("ID \(device.vidPidString), bus \(device.busNumber), address \(device.deviceAddress).")
                        .tag(device as AVMUSBDeviceIdentity?)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

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
        .onAppear {
            selected = devices.first
        }
    }
}
