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
// when the device disconnects, and when the helper restarts. One that
// disconnected goes back to the machine by itself when it reconnects, in
// the same run of the machine (2026-10-29).

import SwiftUI
import Combine
import AppKit
import IOKit

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

    /// A send whose bridge is in QEMU, or being added, while its hold has
    /// still to land (2026-10-29, seventh audit). A save or restore point
    /// gives devices back by what's recorded here, and a bridge in QEMU
    /// from before its hold (an XPC round trip, or the whole wait for the
    /// helper's approval) went into the saved state, which then couldn't
    /// load. hasDevices counts these, and detachAll takes them back.
    private struct InFlight {
        let port: Int
        weak var machine: VMManager?
        let name: String
        var bridge: Bridge = .adding
        var takenBack: TakenBack?
    }
    /// Where the send's bridge device is. Whoever turns inQEMU into
    /// leaving removes it, so attach and detachAll never both do.
    private enum Bridge { case adding, inQEMU, leaving }
    /// Why a send under way was taken back before its hold landed.
    private enum TakenBack { case save, restorePoint, helperRestart }
    /// Sends under way, by the helper's id.
    private var inFlight: [String: InFlight] = [:]
    /// Devices macOS refused the helper for want of Input Monitoring though
    /// their descriptor showed no keys (2026-10-29): asked for next time.
    private var needsInputMonitoring: Set<String> = []

    @discardableResult
    func attach(_ device: BluetoothDeviceInfo, to machine: VMManager) async -> Bool {
        // Not into a machine being saved (2026-10-29, sixth audit): its save
        // gives its devices back first, and one sent meanwhile went into a
        // saved state that couldn't carry on.
        if machine.isSaving {
            say("\(machine.machineName) is being saved, so \(device.name) stays on the Mac.", tone: .info)
            return false
        }
        guard case .running = machine.state else {
            if case .paused = machine.state {
                say("\(machine.machineName) is paused. Resume it, then send \(device.name).", tone: .failure)
            } else {
                say("\(machine.machineName) isn't running. Start it, then send \(device.name).", tone: .failure)
            }
            return false
        }
        guard attached[device.id] == nil else {
            say("\(device.name) is already in a virtual machine.", tone: .info)
            return true
        }
        // One send at a time per device (2026-10-28, fifth audit): a second
        // Send while the first waited for the helper's approval reserved a
        // second port, and its failure freed the first's reservation while
        // that bridge device stayed in QEMU, so every later attach failed.
        guard !sending.contains(device.id) else {
            say("\(device.name) is being sent already.", tone: .info)
            return false
        }
        sending.insert(device.id)
        defer { sending.remove(device.id) }
        // Sent now, by hand or on its return: nothing left to wait for.
        awaitingReturn[device.id] = nil
        // Input Monitoring first, for a device with keys (2026-10-29, the
        // user's Mantis): macOS lets the helper open one only when AVM is
        // allowed there (InputMonitoring.swift). Asked for, and waited on,
        // before the bridge goes into QEMU, so nothing waits in the machine
        // meanwhile. Once the wait is over the helper decides.
        if HIDReportDescriptor.hasKeyboard(device.descriptor) || needsInputMonitoring.contains(device.id),
           !InputMonitoring.isAllowed {
            let outcome = await InputMonitoring.ask(
                title: "AVM needs Input Monitoring to send \(device.name)",
                why: "\(device.name) has keys, and macOS lets AVM's helper take a device with keys only when AVM is allowed under Input Monitoring.",
                then: "AVM sends \(device.name) to \(machine.machineName) as soon as it's allowed.",
                while: {
                    if machine.isSaving { return false }
                    if case .running = machine.state { return true }
                    return false
                })
            if outcome == .notNow {
                say("\(device.name) stayed on the Mac. Send it again when you're ready to allow AVM under Input Monitoring.", tone: .info)
                return false
            }
            if machine.isSaving {
                say("\(machine.machineName) is being saved, so \(device.name) stays on the Mac.", tone: .info)
                return false
            }
            guard case .running = machine.state else {
                if case .paused = machine.state {
                    say("\(machine.machineName) is paused. Resume it, then send \(device.name) again from Bluetooth Devices.", tone: .info)
                } else {
                    say("\(device.name) stayed on the Mac: \(machine.machineName) stopped.", tone: .info)
                }
                return false
            }
        }
        guard let port = USBRedirectController.shared.reservePort(portKey(device.id), on: machine) else {
            say("All \(USBRedirectController.ports.count) slots for devices are in use. Next: return a USB or Bluetooth device to the Mac, then try again.", tone: .failure)
            return false
        }
        guard let socket = machine.hidBridgeSocketPath(port: port) else {
            USBRedirectController.shared.releaseReservedPort(portKey(device.id), port: port)
            say("\(machine.machineName) isn't ready for devices yet. Wait for it to finish starting.", tone: .failure)
            return false
        }
        // Recorded before QEMU adds the bridge (2026-10-29, seventh audit),
        // so a save begun from here on takes it back (detachAll).
        inFlight[device.id] = InFlight(port: port, machine: machine, name: device.name)
        defer { inFlight[device.id] = nil }
        do {
            try await machine.attachHIDBridge(port: port, socketPath: socket, descriptor: device.descriptor,
                                              vendor: device.vendor, product: device.product, name: device.name)
        } catch {
            USBRedirectController.shared.releaseReservedPort(portKey(device.id), port: port)
            AVMLog.write("Bluetooth: QEMU refused the bridge for \(device.name): \(error.localizedDescription)", category: "Bluetooth")
            // A save begun meanwhile is the reason to give (seventh audit).
            if let why = inFlight[device.id]?.takenBack {
                say(takenBackLine(device, machine, why), tone: .info)
                return false
            }
            say("\(machine.machineName) couldn't add \(device.name). Reason: \(error.localizedDescription)", tone: .failure)
            return false
        }
        inFlight[device.id]?.bridge = .inQEMU
        // Taken back while QEMU added it (2026-10-29, seventh audit): out
        // again before any hold, and nothing recorded.
        if let why = inFlight[device.id]?.takenBack {
            await removeBridgeIfOurs(device.id, port: port, from: machine)
            AVMLog.write("Bluetooth: \(device.name) was taken back from \(machine.machineName) while its bridge was added", category: "Bluetooth")
            say(takenBackLine(device, machine, why), tone: .info)
            return false
        }
        var held = await USBHelperClient.shared.holdBluetooth(device.id, socketPath: socket, peerPID: machine.qemuPID)
        // The helper is waiting for its approval in Login Items (2026-10-28,
        // code review): wait, then ask again, so "approved, continuing"
        // continues this too.
        // Why the wait ended short of the approval (2026-10-29, seventh
        // audit), to say so afterwards: every end was "wasn't allowed in
        // time, or M stopped", for a pause too, and a restore point was over
        // (it takes a second) before the wait noticed it.
        enum WaitEnd { case paused, saving(TakenBack), stopped, notApproved }
        var waitEnded: WaitEnd?
        func cantTakeIt() -> WaitEnd? {
            // Taken back by a save already, or one begun that will (seventh
            // audit): this send's bridge is in QEMU, and would be in the save.
            if let why = inFlight[device.id]?.takenBack { return .saving(why) }
            if machine.isSaving { return .saving(machine.savingTask != nil ? .save : .restorePoint) }
            if case .paused = machine.state { return .paused }
            if case .running = machine.state { return nil }
            return .stopped
        }
        if case .failure(.notEnabled(.requiresApproval)) = held {
            say("\(device.name) goes to \(machine.machineName) once AVM's helper is allowed in Login Items.", tone: .info)
            let approved = await USBHelperClient.shared.waitForApproval(while: {
                waitEnded = cantTakeIt()
                return waitEnded == nil
            })
            // Only for a machine still running (2026-10-28): one that
            // stopped during the wait has no socket to hold against.
            if approved { waitEnded = cantTakeIt() } else if waitEnded == nil { waitEnded = .notApproved }
            if approved, waitEnded == nil {
                held = await USBHelperClient.shared.holdBluetooth(device.id, socketPath: socket, peerPID: machine.qemuPID)
            }
        }
        switch held {
        case .success:
            // A save begun meanwhile (2026-10-29, seventh audit): its detachAll
            // took the bridge back already, or is about to look and must find
            // no hold to keep. The hold goes straight back, nothing is
            // recorded, and the bridge goes too if it's still this send's.
            if inFlight[device.id]?.takenBack != nil || machine.isSaving {
                let why = inFlight[device.id]?.takenBack ?? (machine.savingTask != nil ? TakenBack.save : .restorePoint)
                inFlight[device.id]?.takenBack = why
                await USBHelperClient.shared.releaseBluetooth(device.id)
                await removeBridgeIfOurs(device.id, port: port, from: machine)
                AVMLog.write("Bluetooth: the hold on \(device.name) landed while \(machine.machineName) was being saved; released again", category: "Bluetooth")
                say(takenBackLine(device, machine, why), tone: .info)
                return false
            }
            attached[device.id] = Attached(port: port, machine: machine, name: device.name)
            AVMLog.write("Bluetooth: \(device.name) (\(device.kind)) is in \(machine.machineName) on port \(port)", category: "Bluetooth")
            say("\(device.name) is now in \(machine.machineName).", tone: .success)
            return true
        case .failure(let error):
            // As known before this cleanup (seventh audit): a save that begins
            // during it changes nothing about why the hold failed.
            let taken = inFlight[device.id]?.takenBack
            await removeBridgeIfOurs(device.id, port: port, from: machine)
            AVMLog.write("Bluetooth: the helper didn't take \(device.name): \(error)", category: "Bluetooth")
            if let taken {
                say(takenBackLine(device, machine, taken), tone: .info)
                return false
            }
            // Said here too when the approval wait ended without a send
            // (2026-10-28, fourth audit): the promise above was the last word.
            // With the reason it ended (seventh audit).
            if case .notEnabled = error {
                switch waitEnded {
                case .saving(let why)?:
                    say(takenBackLine(device, machine, why), tone: .info)
                case .paused?:
                    say("\(machine.machineName) is paused. Resume it, then send \(device.name) again from Bluetooth Devices.", tone: .info)
                case .stopped?:
                    say("\(device.name) stayed on the Mac: \(machine.machineName) stopped before AVM's helper was allowed.", tone: .info)
                case .notApproved?:
                    say("\(device.name) stayed on the Mac: AVM's helper wasn't allowed in time. Allow AVM in Login Items, then send it again from Bluetooth Devices.", tone: .info)
                case nil:
                    if machine.isSaving {
                        say("\(machine.machineName) is being saved, so \(device.name) stays on the Mac.", tone: .info)
                    }
                }
                return false
            }
            // The client has said the helper isn't starting, and what to do
            // (2026-10-29); a second line would cut that one off.
            if case .notStarting = error { return false }
            // Refused for want of Input Monitoring (2026-10-29): keys the
            // descriptor didn't show, or Input Monitoring turned off since.
            // The next send asks for it. Allowed already, the code is said.
            if case .helper(_, let detail) = error, InputMonitoring.refusedHelper(detail) {
                if !InputMonitoring.isAllowed {
                    needsInputMonitoring.insert(device.id)
                    say("\(device.name) stayed on the Mac: macOS lets AVM's helper take it only when AVM is allowed under Input Monitoring. Send it again, and AVM asks for it.", tone: .failure)
                    return false
                }
                AVMLog.write("Bluetooth: AVM is allowed under Input Monitoring, and macOS still refused the helper \(device.name)", category: "Bluetooth")
            }
            // Not "stayed on the Mac" for a machine's keyboard for Windows,
            // which the helper has already (2026-10-29, sixth audit).
            let reason = Self.reason(error)
            say(reason.contains("keyboard for Windows") ? "\(device.name) wasn't sent. \(reason)" : "\(device.name) stayed on the Mac. Reason: \(reason)", tone: .failure)
            return false
        }
    }

    func detach(_ id: String, quietly: Bool = false) async {
        guard let entry = attached.removeValue(forKey: id) else { return }
        await USBHelperClient.shared.releaseBluetooth(id)
        if let machine = entry.machine, Self.takesQMP(machine) {
            await machine.detachHIDBridge(port: entry.port)
        }
        USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
        AVMLog.write("Bluetooth: \(entry.name) returned to the Mac", category: "Bluetooth")
        if !quietly { say("\(entry.name) is back on the Mac.", tone: .info) }
    }

    /// True when a Bluetooth device is in `machine`, or on its way in
    /// (2026-10-29, seventh audit: see detachAll).
    func hasDevices(in machine: VMManager) -> Bool {
        attached.values.contains { $0.machine === machine }
            || inFlight.values.contains { $0.machine === machine && $0.takenBack == nil }
    }

    /// Every device, or every one in `machine`: before a save, or a helper
    /// restart.
    func detachAll(from machine: VMManager? = nil) async {
        for (id, entry) in attached where machine == nil || entry.machine === machine {
            await detach(id)
        }
        // Sends under way too (2026-10-29, seventh audit): a bridge in QEMU
        // from before its hold went into the saved state, which then
        // couldn't load. The send sees takenBack, releases its hold if that
        // lands, and says why. A bridge still being added, or already on its
        // way out, is the send's own to remove: this waits for it, so the
        // save's snapshot comes after.
        let why: TakenBack = machine == nil ? .helperRestart : (machine?.savingTask != nil ? .save : .restorePoint)
        for (id, flight) in inFlight where machine == nil || flight.machine === machine {
            if inFlight[id]?.takenBack == nil { inFlight[id]?.takenBack = why }
            if inFlight[id]?.bridge == .inQEMU {
                inFlight[id]?.bridge = .leaving
                if let holder = flight.machine, Self.takesQMP(holder) {
                    await holder.detachHIDBridge(port: flight.port)
                }
                USBRedirectController.shared.releaseReservedPort(portKey(id), port: flight.port)
                AVMLog.write("Bluetooth: \(flight.name)'s send was taken back (\(why)); its bridge is out of QEMU", category: "Bluetooth")
                continue
            }
            let waitStarted = Date()
            while inFlight[id] != nil, Date().timeIntervalSince(waitStarted) < 15 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if inFlight[id] != nil {
                AVMLog.write("Bluetooth: \(flight.name)'s send still has its bridge after 15 seconds; not waiting longer", category: "Bluetooth")
            }
        }
    }

    /// Removes a send's bridge device and frees its port, unless
    /// detachAll is doing so, or has (2026-10-29, seventh audit).
    private func removeBridgeIfOurs(_ id: String, port: Int, from machine: VMManager) async {
        guard inFlight[id]?.bridge == .inQEMU else { return }
        inFlight[id]?.bridge = .leaving
        if Self.takesQMP(machine) {
            await machine.detachHIDBridge(port: port)
        }
        USBRedirectController.shared.releaseReservedPort(portKey(id), port: port)
    }

    /// What to say for a send taken back before its hold landed
    /// (2026-10-29, seventh audit).
    private func takenBackLine(_ device: BluetoothDeviceInfo, _ machine: VMManager, _ why: TakenBack) -> String {
        switch why {
        case .save:
            return "\(device.name) stayed on the Mac: \(machine.machineName) was being saved. Send it again from Bluetooth Devices after its next Start."
        case .restorePoint:
            return "\(device.name) stayed on the Mac: \(machine.machineName) was taking a restore point. Send it again from Bluetooth Devices."
        case .helperRestart:
            return "\(device.name) stayed on the Mac: AVM's helper was restarted. Send it again from Bluetooth Devices."
        }
    }

    /// Devices whose send is under way (fifth audit).
    private var sending: Set<String> = []

    // MARK: Things that end a hold

    /// The helper let a device go: it disconnected, or the machine closed
    /// its side.
    func helperLetGo(_ id: String, detail: String?) {
        USBHelperClient.shared.forgetBluetooth(id)
        guard let entry = attached.removeValue(forKey: id) else { return }
        guard let machine = entry.machine, Self.takesQMP(machine) else {
            USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
            say("\(entry.name) went back to the Mac\(detail.map { ": \($0)" } ?? "").", tone: .info)
            return
        }
        // The port is free once the bridge device is gone (2026-10-28, code
        // review): freed first, the next send could take it meanwhile.
        Task {
            await machine.detachHIDBridge(port: entry.port)
            USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
        }
        // Disconnected, it comes back by itself (2026-10-29): see below.
        if detail == "it disconnected", case .running = machine.state, !machine.isSaving {
            awaitingReturn[id] = AwaitingReturn(machine: machine, run: machine.qemuPID, name: entry.name)
            watchForReturns()
            AVMLog.write("Bluetooth: \(entry.name) disconnected; it goes back to \(machine.machineName) when it reconnects", category: "Bluetooth")
            say("\(entry.name) disconnected, so it's on the Mac for now. It goes back to \(machine.machineName) when it reconnects.", tone: .info)
            return
        }
        say("\(entry.name) went back to the Mac\(detail.map { ": \($0)" } ?? ""). Send it again from Bluetooth Devices when it's back.", tone: .info)
    }

    // MARK: Coming back after a disconnect (2026-10-29)

    /// Devices that disconnected while in a machine, by the helper's id: a
    /// braille display asleep, out of range or flat. Each goes back to its
    /// machine when macOS sees it again, in the same run of that machine
    /// (its QEMU process), while it's running. A USB device already follows
    /// the user's choice back (USBPlugPrompt); a Bluetooth one had to be
    /// sent again by hand every time it slept, and braille displays sleep.
    struct AwaitingReturn {
        weak var machine: VMManager?
        let run: Int
        let name: String
    }
    /// Shown in Return Devices to Mac, where Keep on Mac ends the wait.
    @Published private(set) var awaitingReturn: [String: AwaitingReturn] = [:]

    /// The devices waiting to go back to `machine`, by name.
    func waiting(for machine: VMManager) -> [(id: String, name: String)] {
        awaitingReturn.filter { $0.value.machine === machine && stillWanted($0.value) != nil }
            .map { (id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Stays on the Mac when it reconnects.
    func keepOnMac(_ id: String) {
        guard let waiting = awaitingReturn.removeValue(forKey: id) else { return }
        AVMLog.write("Bluetooth: \(waiting.name) stays on the Mac when it reconnects (Keep on Mac)", category: "Bluetooth")
        say("\(waiting.name) stays on the Mac when it reconnects.", tone: .info)
    }
    private var arrivals: BluetoothArrivals?
    private var checkingReturns = false
    private var checkAgain = false

    private func watchForReturns() {
        if arrivals == nil {
            arrivals = BluetoothArrivals { [weak self] in self?.checkForReturns() }
            if arrivals == nil {
                AVMLog.write("Bluetooth: couldn't watch for devices reconnecting; a disconnected device is sent again by hand", category: "Bluetooth")
            }
        }
        // Back already, before the watch began.
        checkForReturns()
    }

    /// Still wanted: its machine is in the same run, running, not saving.
    private func stillWanted(_ waiting: AwaitingReturn) -> VMManager? {
        guard let machine = waiting.machine, machine.qemuPID == waiting.run, !machine.isSaving,
              case .running = machine.state else { return nil }
        return machine
    }

    /// Looks for the devices waiting to go back, a few times while a newly
    /// connected one publishes itself, and sends each one found. One look
    /// at a time; an arrival during it asks for another.
    private func checkForReturns() {
        guard !checkingReturns else { checkAgain = true; return }
        checkingReturns = true
        Task {
            defer { checkingReturns = false }
            repeat {
                checkAgain = false
                for delay in [2, 3, 5] {
                    try? await Task.sleep(for: .seconds(delay))
                    awaitingReturn = awaitingReturn.filter { stillWanted($0.value) != nil }
                    guard !awaitingReturn.isEmpty else { return }
                    guard case .success(let present) = await USBHelperClient.shared.listBluetoothDevices() else { break }
                    for device in present {
                        guard let waiting = awaitingReturn.removeValue(forKey: device.id),
                              let machine = stillWanted(waiting) else { continue }
                        AVMLog.write("Bluetooth: \(waiting.name) reconnected; sending it back to \(machine.machineName)", category: "Bluetooth")
                        await attach(device, to: machine)
                    }
                    if awaitingReturn.isEmpty { return }
                }
            } while checkAgain
        }
    }

    /// A machine whose bridge devices can be removed over QMP: running, or
    /// paused (2026-10-28, fourth audit: skipping a paused machine left
    /// the device in QEMU while its port was freed, and every later send to
    /// that port failed). QEMU removes a USB device with the vCPUs stopped.
    private static func takesQMP(_ machine: VMManager) -> Bool {
        machine.state == .running || machine.state == .paused
    }

    /// The machine stopped: QEMU is gone, and the helper lets go when its
    /// socket closes. Nothing to say; the machine's stop is said already.
    func machineStopped(_ machine: VMManager) {
        for (id, entry) in attached where entry.machine === machine || entry.machine == nil {
            attached[id] = nil
            USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
            Task { await USBHelperClient.shared.releaseBluetooth(id) }
        }
    }

    /// The helper went away (it crashed or was restarted): it let go of
    /// everything, so the machines' bridge devices go too.
    func helperLost() {
        let lost = attached
        attached = [:]
        for (id, entry) in lost {
            if let machine = entry.machine, Self.takesQMP(machine) {
                Task {
                    await machine.detachHIDBridge(port: entry.port)
                    USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
                }
            } else {
                USBRedirectController.shared.releaseReservedPort(portKey(id), port: entry.port)
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

// MARK: - Bluetooth devices appearing (2026-10-29)

/// Says when a Bluetooth HID device appears in macOS's registry, for a
/// disconnected device to go back to its machine. Only the registry is
/// watched, nothing is opened, so it needs no permission. As
/// USBHotPlugWatcher: on the main run loop, the iterator drained to arm it,
/// the devices there already passed over.
final class BluetoothArrivals {
    private let port: IONotificationPortRef
    private var iterator: io_iterator_t = 0
    private let arrived: () -> Void

    init?(arrived: @escaping () -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.arrived = arrived
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), { refcon, iterator in
            guard let refcon else { return }
            let watch = Unmanaged<BluetoothArrivals>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.drain(iterator, tell: true) }
        }, refcon, &iterator)
        guard kr == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return nil
        }
        drain(iterator, tell: false)
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        IONotificationPortDestroy(port)
    }

    private func drain(_ iterator: io_iterator_t, tell: Bool) {
        var bluetooth = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let transport = IORegistryEntryCreateCFProperty(service, "Transport" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? ""
            if transport.lowercased().contains("bluetooth") { bluetooth = true }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        if tell, bluetooth { arrived() }
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
    /// Why the list couldn't be read, in place of "No Bluetooth devices"
    /// (2026-10-29: a helper that wasn't starting read as no devices).
    @State private var problem: String?

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
            } else if let problem {
                Text(problem)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .disabled(looking)
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
        // The machine it's in, which may not be this window's (2026-10-28,
        // fourth audit: a device in A read "In B" from B's window).
        let holder = bluetooth.attached[device.id]?.machine?.machineName ?? machine.machineName
        return HStack {
            Text("\(device.name), \(kind). \(inMachine ? "In \(holder)" : "On the Mac").")
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
        problem = nil
        switch await USBHelperClient.shared.listBluetoothDevices() {
        case .success(let list):
            devices = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Announcer.shared.announce(list.isEmpty ? "No Bluetooth devices are connected." : "\(list.count) Bluetooth \(list.count == 1 ? "device" : "devices") found.", tone: .info)
        case .failure(let error):
            devices = []
            // The approval dialog and the client's own line are spoken
            // already; the window shows them (2026-10-29).
            switch error {
            case .notEnabled(.requiresApproval):
                problem = "AVM's helper is waiting for your approval. In System Settings, under General, then Login Items and Extensions, allow AVM in the background, then choose Look Again."
            case .notEnabled:
                problem = "AVM's helper couldn't be set up. Choose Look Again to try again."
            case .notStarting:
                problem = "AVM's helper isn't starting. In System Settings, under General, then Login Items and Extensions, turn AVM off and on again under Allow in the Background, then quit and reopen AVM."
            default:
                problem = "AVM couldn't list Bluetooth devices. Reason: \(error)."
                Announcer.shared.announce("AVM couldn't list Bluetooth devices. Reason: \(error)", tone: .failure)
            }
        }
        looking = false
    }
}
