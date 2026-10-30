// MachineDevicesView.swift
// AVM — Accessible Virtual Machine
//
// Return Devices to Mac (2026-10-29, the user's request): one window with
// every device a machine has from the Mac, each with its own button to
// give it back. Before it, a USB device came back through Detach USB
// Device (straight away when there was one, so there was nothing to read
// first), a Bluetooth one only from inside Bluetooth Devices, and a
// Bluetooth device waiting to reconnect was nowhere at all. The keyboard
// for Windows is listed too, with where to change it: it belongs to the
// machine in Settings, not for one session.
//
// Return All to Mac gives back everything here; each device's own line is
// spoken as it comes back, as from the other windows. Opens for a running
// or paused machine (QEMU lets devices go with its vCPUs stopped).

import SwiftUI

struct MachineDevicesView: View {
    let machine: VMManager

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var usb = USBRedirectController.shared
    @ObservedObject private var bluetooth = BluetoothDevices.shared
    @State private var busy = false

    private var usbDevices: [AVMUSBDeviceIdentity] { usb.devices(for: machine) }
    private var bluetoothDevices: [(id: String, name: String)] {
        bluetooth.attached.filter { $0.value.machine === machine }
            .map { (id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var waiting: [(id: String, name: String)] { bluetooth.waiting(for: machine) }
    private var keyboard: String? {
        WindowsKeyboard.shared.keyboardID != nil && WindowsKeyboard.shared.target === machine
            ? WindowsKeyboard.shared.keyboardName : nil
    }
    private var returnable: Int { usbDevices.count + bluetoothDevices.count + waiting.count }

    /// Anything to list, for the menu and the dashboard to say so instead.
    static func hasDevices(_ machine: VMManager) -> Bool {
        !USBRedirectController.shared.devices(for: machine).isEmpty
            || BluetoothDevices.shared.attached.values.contains { $0.machine === machine }
            || !BluetoothDevices.shared.waiting(for: machine).isEmpty
            || (WindowsKeyboard.shared.keyboardID != nil && WindowsKeyboard.shared.target === machine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Devices in \(machine.machineName)")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text("Your Mac doesn't use these while they're in \(machine.machineName). Return one to give it back to your Mac.")
                .fixedSize(horizontal: false, vertical: true)

            if returnable == 0 && keyboard == nil {
                Text("No devices are in \(machine.machineName) now.")
            }

            if !usbDevices.isEmpty {
                section("USB devices")
                ForEach(usbDevices, id: \.self) { device in
                    HStack {
                        Text("\(device.displayName), USB.")
                        Spacer()
                        Button("Return to Mac") { run { await usb.detach(device) } }
                            .accessibilityLabel("Return \(device.displayName) to the Mac")
                    }
                }
            }

            if !bluetoothDevices.isEmpty {
                section("Bluetooth devices")
                ForEach(bluetoothDevices, id: \.id) { device in
                    HStack {
                        Text("\(device.name), Bluetooth.")
                        Spacer()
                        Button("Return to Mac") { run { await bluetooth.detach(device.id) } }
                            .accessibilityLabel("Return \(device.name) to the Mac")
                    }
                }
            }

            if !waiting.isEmpty {
                section("Waiting to reconnect")
                ForEach(waiting, id: \.id) { device in
                    HStack {
                        Text("\(device.name), Bluetooth. It disconnected, and goes back to \(machine.machineName) when it reconnects.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Keep on Mac") { bluetooth.keepOnMac(device.id) }
                            .accessibilityLabel("Keep \(device.name) on the Mac when it reconnects")
                    }
                }
            }

            if let keyboard {
                section("Keyboard for Windows")
                Text("\(keyboard) types only in \(machine.machineName) while it runs. To keep it on the Mac, choose None under Keyboard for Windows in the machine's Settings.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Return All to Mac") { run { await returnAll() } }
                    .accessibilityHint("Gives back every USB and Bluetooth device in \(machine.machineName)")
                    .disabled(returnable == 0)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(busy)
        .padding(24)
        .frame(minWidth: 480)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }

    private func returnAll() async {
        AVMLog.write("Return Devices to Mac: returning \(returnable) from \(machine.machineName)", category: "USBHelper")
        for device in usbDevices { await usb.detach(device) }
        for device in bluetoothDevices { await bluetooth.detach(device.id) }
        for device in waiting { bluetooth.keepOnMac(device.id) }
    }
}
