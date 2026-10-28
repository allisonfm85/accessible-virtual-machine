// BluetoothDevices.swift
// AVM — Accessible Virtual Machine
//
// Bluetooth devices for a virtual machine (2026-10-27). A Bluetooth braille
// display, game controller or other HID device goes to a machine without
// using a USB port: AVM's helper takes it from macOS (BluetoothHold.swift)
// and relays its reports to QEMU's usb-hid-bridge (AVM's QEMU patch), which
// shows the machine a USB device of the same kind, with the device's own
// report descriptor. Windows then uses the driver it would for the real
// thing: its HID braille support, which NVDA and Narrator use, its game
// controller drivers, and so on.
//
// A Bluetooth device shares root ports 5 to 8 with USB devices. It goes
// back to the Mac when the user asks, when the machine is saved or stops,
// when the device disconnects, and when the helper restarts.

import SwiftUI
import Combine
import AppKit

@MainActor
final class BluetoothDevices: ObservableObject {
    static let shared = BluetoothDevices()

    struct Attached {
        let port: Int
        weak var machine: VMManager?
        let name: String
    }

    /// Devices in a machine now, by the helper's id.
    @Published private(set) var attached: [String: Attached] = [:]

    private func portKey(_ id: String) -> String { "bluetooth:\(id)" }

    /// The kind of device, in words.
    static func kindName(_ kind: String) -> String {
        switch kind {
        case "braille": return "braille display"
        case "controller": return "game controller"
        case "keyboard": return "keyboard"
        case "pointer": return "mouse or trackpad"
        case "remote": return "remote or media keys"
        default: return "Bluetooth device"
        }
    }

    // MARK: Sending and returning

    @discardableResult
    func attach(_ device: BluetoothDeviceInfo, to machine: VMManager) async -> Bool {
        guard case .running = machine.state else {
            say("\(machine.machineName) isn't running. Start it, then send \(device.name).", tone: .failure)
            return false
        }
        guard attached[device.id] == nil else {
            say("\(device.name) is already in a virtual machine.", tone: .info)
            return true
        }
        guard let port = USBRedirectController.shared.reservePort(portKey(device.id), on: machine) else {
            say("All \(USBRedirectController.ports.count) slots for devices are in use. Next: return a USB or Bluetooth device to the Mac, then try again.", tone: .failure)
            return false
        }
        guard let socket = machine.hidBridgeSocketPath(port: port) else {
            USBRedirectController.shared.releaseReservedPort(portKey(device.id))
            say("\(machine.machineName) isn't ready for devices yet. Wait for it to finish starting.", tone: .failure)
            return false
        }
        do {
            try await machine.attachHIDBridge(port: port, socketPath: socket, descriptor: device.descriptor,
                                              vendor: device.vendor, product: device.product, name: device.name)
        } catch {
            USBRedirectController.shared.releaseReservedPort(portKey(device.id))
            AVMLog.write("Bluetooth: QEMU refused the bridge for \(device.name): \(error.localizedDescription)", category: "Bluetooth")
            say("\(machine.machineName) couldn't add \(device.name). Reason: \(error.localizedDescription)", tone: .failure)
            return false
        }
        var held = await USBHelperClient.shared.holdBluetooth(device.id, socketPath: socket)
        // The helper is waiting for its approval in Login Items (2026-10-28,
        // code review): wait, then ask again, so "approved, continuing"
        // continues this too.
        if case .failure(.notEnabled(.requiresApproval)) = held {
            say("\(device.name) goes to \(machine.machineName) once AVM's helper is allowed in Login Items.", tone: .info)
            if await USBHelperClient.shared.waitForApproval(while: { if case .running = machine.state { return true } else { return false } }) {
                held = await USBHelperClient.shared.holdBluetooth(device.id, socketPath: socket)
            }
        }
        switch held {
        case .success:
            attached[device.id] = Attached(port: port, machine: machine, name: device.name)
            AVMLog.write("Bluetooth: \(device.name) (\(device.kind)) is in \(machine.machineName) on port \(port)", category: "Bluetooth")
            say("\(device.name) is now in \(machine.machineName).", tone: .success)
            return true
        case .failure(let error):
            await machine.detachHIDBridge(port: port)
            USBRedirectController.shared.releaseReservedPort(portKey(device.id))
            AVMLog.write("Bluetooth: the helper didn't take \(device.name): \(error)", category: "Bluetooth")
            if case .notEnabled = error { return false }    // the approval is being asked for
            say("\(device.name) stayed on the Mac. Reason: \(Self.reason(error))", tone: .failure)
            return false
        }
    }

    func detach(_ id: String, quietly: Bool = false) async {
        guard let entry = attached.removeValue(forKey: id) else { return }
        await USBHelperClient.shared.releaseBluetooth(id)
        if let machine = entry.machine, case .running = machine.state {
            await machine.detachHIDBridge(port: entry.port)
        }
        USBRedirectController.shared.releaseReservedPort(portKey(id))
        AVMLog.write("Bluetooth: \(entry.name) returned to the Mac", category: "Bluetooth")
        if !quietly { say("\(entry.name) is back on the Mac.", tone: .info) }
    }

    /// Every device, or every one in `machine`: before a save, or a helper
    /// restart.
    func detachAll(from machine: VMManager? = nil) async {
        for (id, entry) in attached where machine == nil || entry.machine === machine {
            await detach(id)
        }
    }

    // MARK: Things that end a hold

    /// The helper let a device go: it disconnected, or the machine closed
    /// its side.
    func helperLetGo(_ id: String, detail: String?) {
        USBHelperClient.shared.forgetBluetooth(id)
        guard let entry = attached.removeValue(forKey: id) else { return }
        guard let machine = entry.machine, case .running = machine.state else {
            USBRedirectController.shared.releaseReservedPort(portKey(id))
            return
        }
        // The port is free once the bridge device is gone (2026-10-28, code
        // review): freed first, the next send could take it meanwhile.
        Task {
            await machine.detachHIDBridge(port: entry.port)
            USBRedirectController.shared.releaseReservedPort(portKey(id))
        }
        say("\(entry.name) went back to the Mac\(detail.map { ": \($0)" } ?? ""). Send it again from Bluetooth Devices when it's back.", tone: .info)
    }

    /// The machine stopped: QEMU is gone, and the helper lets go when its
    /// socket closes. Nothing to say; the machine's stop is said already.
    func machineStopped(_ machine: VMManager) {
        for (id, entry) in attached where entry.machine === machine || entry.machine == nil {
            attached[id] = nil
            USBRedirectController.shared.releaseReservedPort(portKey(id))
            Task { await USBHelperClient.shared.releaseBluetooth(id) }
        }
    }

    /// The helper went away (it crashed or was restarted): it let go of
    /// everything, so the machines' bridge devices go too.
    func helperLost() {
        let lost = attached
        attached = [:]
        for (id, entry) in lost {
            if let machine = entry.machine, case .running = machine.state {
                Task {
                    await machine.detachHIDBridge(port: entry.port)
                    USBRedirectController.shared.releaseReservedPort(portKey(id))
                }
            } else {
                USBRedirectController.shared.releaseReservedPort(portKey(id))
            }
        }
        if !lost.isEmpty {
            say("Bluetooth devices went back to the Mac: AVM's helper stopped. Send them again from Bluetooth Devices.", tone: .info)
        }
    }

    private static func reason(_ error: USBHelperError) -> String {
        if case .helper(_, let detail) = error, !detail.isEmpty { return detail }
        return "\(error)"
    }

    private func say(_ message: String, tone: Announcer.Tone) {
        Announcer.shared.announce(message, tone: tone)
    }
}

// MARK: - The Bluetooth Devices window

struct BluetoothDevicesView: View {
    let machine: VMManager

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var bluetooth = BluetoothDevices.shared
    @State private var devices: [BluetoothDeviceInfo] = []
    @State private var looking = true
    @State private var busy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bluetooth Devices")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text("Send a Bluetooth braille display, game controller or other device to \(machine.machineName), without a USB port. While it's there, your Mac doesn't use it. A keyboard is better chosen as Keyboard for Windows in Settings.")
                .fixedSize(horizontal: false, vertical: true)

            if looking {
                Text("Looking for Bluetooth devices…")
            } else if devices.isEmpty {
                Text("No Bluetooth devices are connected. Turn the device on, or press a key on it to wake it, then choose Look Again.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(devices) { device in
                    row(device)
                }
            }

            HStack {
                Button("Look Again") { Task { await look() } }
                    .accessibilityHint("Lists the Bluetooth devices connected to your Mac now")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
        .task { await look() }
    }

    private func row(_ device: BluetoothDeviceInfo) -> some View {
        let inMachine = bluetooth.attached[device.id] != nil
        let kind = BluetoothDevices.kindName(device.kind)
        return HStack {
            Text("\(device.name), \(kind). \(inMachine ? "In \(machine.machineName)" : "On the Mac").")
            Spacer()
            if inMachine {
                Button("Return to Mac") { run(device.id) { await bluetooth.detach(device.id) } }
                    .accessibilityLabel("Return \(device.name) to the Mac")
            } else {
                Button("Send to \(machine.machineName)") { run(device.id) { await bluetooth.attach(device, to: machine) } }
                    .accessibilityLabel("Send \(device.name) to \(machine.machineName)")
                    .accessibilityHint("Your Mac stops using it while it's there.")
            }
        }
        .disabled(busy != nil)
    }

    private func run(_ id: String, _ work: @escaping () async -> Void) {
        busy = id
        Task {
            await work()
            busy = nil
        }
    }

    private func look() async {
        looking = true
        switch await USBHelperClient.shared.listBluetoothDevices() {
        case .success(let list):
            devices = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Announcer.shared.announce(list.isEmpty ? "No Bluetooth devices are connected." : "\(list.count) Bluetooth \(list.count == 1 ? "device" : "devices") found.", tone: .info)
        case .failure(let error):
            devices = []
            if case .notEnabled = error { break }
            Announcer.shared.announce("AVM couldn't list Bluetooth devices. Reason: \(error)", tone: .failure)
        }
        looking = false
    }
}
