//
//  USBRedirectController.swift
//  AVM
//
//  The user-facing owner of USB redirection (increment 2a, 2026-09-12).
//  Replaces the Debug-only USBRedirectDebug driver. Holds the map from
//  redirected device to QEMU root port, allocates ports 5 through 8
//  (the hot-add reserve on the qemu-xhci p2=8,p3=8 map, handoff 48),
//  and runs the two orderings that were live-proven in increment 1b:
//
//  Attach order: QEMU first, helper second. AVM adds the usbredir
//  chardev and the usb-redir device over QMP so QEMU is listening on
//  the stream socket before the root helper dials it.
//
//  Detach order: helper first, QEMU second. The helper releases the
//  device back to macOS (about two seconds), then AVM removes the
//  usb-redir device and the chardev so the same port can be used
//  again without restarting the VM.
//
//  Port release on surprises: USBHelperClient reports every device
//  ending (released, failed, yanked) through deviceEnded. If that
//  device still holds a port here, the port is taken back from QEMU
//  when the VM is running, or simply forgotten when it is not (QEMU is
//  gone, so there is nothing to remove; VMManager's own cleanup deletes
//  the socket files). The ordinary detach path removes the map entry
//  before calling the helper, so the released event it triggers finds
//  nothing to do. Every QEMU cleanup here is idempotent by that rule.
//
//  Speech: USBHelperClient owns the device announcements (attached,
//  returned, failed, unplugged). This file speaks what the client
//  cannot know: VM not running, nothing attached, no port free, QMP
//  failures with their step and next action, and "was unplugged" after
//  a vanish cleanup the helper never reported (2026-10-17). A vanish
//  is cancelled when the device comes back at the same address while
//  the helper holds it (deviceReturned, 2026-10-24).
//
//  Send gate (USB 2c, 2026-10-18): USBPlugPrompt marks a device quiet
//  in USBHelperClient while it handles an automatic send. Then attach
//  (quiet: true) logs instead of speaking, the vanish cleanup's unplug
//  line is logged, and the gate speaks one outcome itself.
//
//  USB drives (2026-10-25): macOS 27 won't let AVM's helper open a USB
//  storage device, since a launchd daemon has no responsible app for
//  the Removable Volumes permission. Apple has a code-level support
//  request. Until that's solved, storageBlocked stops every send of a
//  drive: here for the menu, and in USBPlugPrompt before a send gate
//  opens. refuseStorage speaks why.
//

import Combine
import Foundation

@MainActor
final class USBRedirectController: ObservableObject {
    static let shared = USBRedirectController()

    /// Root ports reserved for hot-added usb-redir devices.
    static let ports = 5...8

    /// Devices holding a QEMU port: pending or attached.
    @Published private(set) var portByDevice: [AVMUSBDeviceIdentity: Int] = [:]

    /// Devices AVM is handing back to the Mac right now, by
    /// USBPlugPrompt.deviceKey, and when each recent hand-back finished.
    private var handingBack: Set<String> = []
    private var handedBackAt: [String: Date] = [:]
    /// How long after a hand-back its re-arrivals count as coming home.
    static let handBackSettle: TimeInterval = 5

    /// True while AVM is handing this device back to the Mac, or within
    /// handBackSettle seconds after. macOS can drop and re-add a device
    /// several times while it comes home (log, 2026-10-12); the watcher
    /// asks nothing about those arrivals.
    func isBeingHandedBack(_ device: AVMUSBDeviceIdentity) -> Bool {
        let key = USBPlugPrompt.deviceKey(device)
        if handingBack.contains(key) { return true }
        guard let finished = handedBackAt[key] else { return false }
        if Date().timeIntervalSince(finished) < Self.handBackSettle { return true }
        handedBackAt[key] = nil
        return false
    }

    /// How long the helper gets to report a vanished device itself.
    /// It reported the mic's unplug within milliseconds (2026-10-12).
    static let vanishGrace: Duration = .seconds(2)

    /// One token per device whose vanishGrace is running. A device that
    /// comes back at the same address loses its token (deviceReturned),
    /// and a newer vanish replaces it, so only the latest one can clean up.
    private var vanishToken: [AVMUSBDeviceIdentity: UUID] = [:]

    /// The watcher saw a device leave the Mac. If it was in Windows and
    /// still holds a port after vanishGrace, the helper never reported
    /// it (a Monarch switching modes, 2026-10-17), so AVM speaks the
    /// unplug, frees the port, and quietly tells the helper to drop it.
    func deviceVanished(_ device: AVMUSBDeviceIdentity) {
        guard let held = heldIdentity(matching: device) else { return }
        // Only a device that actually reached Windows can follow back.
        // A device also holds a port while its attach is still being
        // tried (thumb drive, 2026-10-18).
        if USBHelperClient.shared.reachedWindows(held) {
            let followKey = Self.followKey(held)
            leftWindowsAt[followKey] = Date()
            leftWindowsCopy[followKey] = held
        } else {
            log("vanished \(held.description): it never reached Windows, so it won't follow back")
        }
        let token = UUID()
        vanishToken[held] = token
        Task { @MainActor in
            try? await Task.sleep(for: Self.vanishGrace)
            guard self.vanishToken[held] == token else {
                self.log("vanished \(held.description): it came back, or vanished again; this cleanup stands down")
                return
            }
            self.vanishToken[held] = nil
            guard self.portByDevice[held] != nil else {
                self.log("vanished \(held.description): the helper reported it; nothing to clean up")
                return
            }
            self.log("vanished \(held.description): no helper report after \(Self.vanishGrace); cleaning up")
            USBHelperClient.shared.forget(held)
            if USBHelperClient.shared.isQuiet(held) {
                self.log("vanished \(held.description): the send gate is handling it; unplug not spoken")
            } else {
                self.announce("\(held.displayName) was unplugged.", tone: .info)
            }
            await self.releasePort(for: held, reason: "vanished with no helper report")
            _ = await USBHelperClient.shared.detach(held, quiet: true)
        }
    }

    /// The watcher saw a device arrive at an address it still holds a
    /// port under. After a vanish, that means macOS dropped and re-added
    /// the device while the helper kept hold of it. libusb does this when
    /// it takes a device from a Mac driver: the Monarch in its file
    /// transfer mode (1c71:d100), 2026-10-24. The device is still in
    /// Windows, so the pending cleanup is cancelled, and so is the
    /// follow-through record, since it never left.
    func deviceReturned(_ device: AVMUSBDeviceIdentity) {
        guard let held = heldIdentity(matching: device),
              vanishToken.removeValue(forKey: held) != nil else { return }
        clearFollowThrough(held)
        log("returned \(held.description): back at the same address while the helper holds it; vanish cleanup cancelled")
    }

    // MARK: Follow-through

    /// How soon a device must come back to follow the user's choice to
    /// Windows without being asked. A minute, so people with dexterity
    /// needs or who need extra time aren't pressured (Allison,
    /// 2026-10-18). A replug at about 10.9 seconds missed the first
    /// 10 second window.
    static let followWindow: TimeInterval = 60

    /// When each device last left Windows, and the identity it held a
    /// port under, by followKey.
    private var leftWindowsAt: [String: Date] = [:]
    private var leftWindowsCopy: [String: AVMUSBDeviceIdentity] = [:]

    /// The same physical device across mode changes: maker and serial.
    /// A Monarch is 1c71:d100 for file transfer and 1c71:d110 in Braille
    /// Terminal (2026-10-17). With no serial, or one that isn't this
    /// unit's (2026-10-28, third audit: some makers put "0000" or
    /// "1234567890" on every unit, so a webcam and a headset from one of
    /// them shared a key and followed each other's choices), maker and
    /// product as well.
    nonisolated static func followKey(_ device: AVMUSBDeviceIdentity) -> String {
        let serial = device.serialNumber ?? ""
        if serial.isEmpty == false, isPlaceholderSerial(serial) == false {
            return "\(device.vendorID):serial:\(serial)"
        }
        return "\(device.vendorID):\(device.productID):\(serial.isEmpty ? "noserial" : serial)"
    }

    /// A serial a maker gives every unit rather than this one: too short
    /// to tell units apart, one character repeated, a counting sequence,
    /// or a word standing in for a serial. Mistaking a real serial for one
    /// costs only the follow-through across a mode change; the reverse
    /// conflates two devices.
    nonisolated static func isPlaceholderSerial(_ serial: String) -> Bool {
        let s = serial.trimmingCharacters(in: .whitespaces).lowercased()
        if s.count < 4 || Set(s).count == 1 { return true }
        let placeholders: Set<String> = ["0123456789", "1234567890", "123456789", "12345678", "1234567", "123456",
                                         "12345", "1234", "0123456789abcdef", "abcdef", "default", "serial",
                                         "none", "null", "n/a", "unknown", "serial number", "xxxxxxxx"]
        return placeholders.contains(s)
    }

    /// True when this device left Windows less than followWindow seconds
    /// ago. Takes the record, and quietly clears the vanished copy if
    /// it still holds a port, so the return is not also announced as an
    /// unplug.
    func takeFollowThrough(_ device: AVMUSBDeviceIdentity) -> Bool {
        let key = Self.followKey(device)
        let stale = leftWindowsCopy.removeValue(forKey: key)
        guard let left = leftWindowsAt.removeValue(forKey: key),
              Date().timeIntervalSince(left) < Self.followWindow else { return false }
        if let stale, portByDevice[stale] != nil {
            Task { @MainActor in
                USBHelperClient.shared.forget(stale)
                await self.releasePort(for: stale, reason: "came back as a new device; followed to Windows")
                _ = await USBHelperClient.shared.detach(stale, quiet: true)
            }
        }
        return true
    }

    /// Drops this device's follow-through record. The send gate calls it
    /// when it finishes, so its own bounces never count as leaving Windows.
    /// The watch ended (the machine stopped, 2026-10-28, deep audit): no
    /// device follows "the user's choice" into the next machine.
    func clearAllFollowThrough() {
        leftWindowsAt.removeAll()
        leftWindowsCopy.removeAll()
    }

    func clearFollowThrough(_ device: AVMUSBDeviceIdentity) {
        let key = Self.followKey(device)
        leftWindowsAt[key] = nil
        leftWindowsCopy[key] = nil
    }

    // MARK: Send gate helpers (USB 2c)

    /// True when this physical device, under any address, holds a port
    /// and the helper reports it attached.
    func isInWindows(_ device: AVMUSBDeviceIdentity) -> Bool {
        let key = Self.followKey(device)
        return portByDevice.keys.contains {
            Self.followKey($0) == key && USBHelperClient.shared.attachedDevices.contains($0)
        }
    }

    /// Quietly frees every port held for this physical device under an
    /// address other than the one given. The send gate calls it before
    /// a retry, since a bouncing device leaves old addresses behind.
    func releaseStale(_ device: AVMUSBDeviceIdentity) async {
        let key = Self.followKey(device)
        let stale = portByDevice.keys.filter { Self.followKey($0) == key && $0 != device }
        for held in stale {
            USBHelperClient.shared.forget(held)
            await releasePort(for: held, reason: "an old address of a device the send gate is resending")
            _ = await USBHelperClient.shared.detach(held, quiet: true)
        }
    }

    /// The identity this controller holds a port for that is the same
    /// device: vendor, product, bus, and address.
    private func heldIdentity(matching device: AVMUSBDeviceIdentity) -> AVMUSBDeviceIdentity? {
        portByDevice.keys.first {
            $0.vendorID == device.vendorID && $0.productID == device.productID
                && $0.busNumber == device.busNumber && $0.deviceAddress == device.deviceAddress
        }
    }

    private init() {
        USBHelperClient.shared.deviceEnded = { [weak self] device, state in
            Task { @MainActor in
                await self?.handleDeviceEnded(device, state: state)
            }
        }
    }

    /// Devices currently redirected, in port order.
    var redirectedDevices: [AVMUSBDeviceIdentity] {
        portByDevice.sorted { $0.value < $1.value }.map { $0.key }
    }

    /// Which machine each device went to (2026-10-27, several machines at
    /// once). Ports 5-8 are per machine: each QEMU has its own.
    private var machineByDevice: [AVMUSBDeviceIdentity: WeakManager] = [:]
    private struct WeakManager { weak var manager: VMManager? }

    /// The devices sent to one machine.
    func devices(for manager: VMManager) -> [AVMUSBDeviceIdentity] {
        redirectedDevices.filter { machineByDevice[$0]?.manager === manager }
    }

    /// The machine a device went to, if it's still running.
    func machine(for device: AVMUSBDeviceIdentity) -> VMManager? {
        machineByDevice[device]?.manager
    }

    // MARK: Attach

    /// Returns true when the helper accepted the device (the attached
    /// event comes later) or it already holds a port. quiet: log the
    /// failures instead of speaking them; the send gate speaks one
    /// outcome itself.
    /// `machine`: the machine to send it to; the current one (in front)
    /// if nil.
    @discardableResult
    func attach(_ device: AVMUSBDeviceIdentity, to machine: VMManager? = nil, quiet: Bool = false) async -> Bool {
        guard let manager = machine ?? VMManager.shared, case .running = manager.state else {
            say("The virtual machine is not running. Start it, then attach \(device.displayName).", tone: .failure, quiet: quiet)
            return false
        }
        if refusesStorage(device) { return false }
        if let port = portByDevice[device] {
            let name = machineByDevice[device]?.manager?.machineName ?? "the virtual machine"
            say("\(device.displayName) is already attached to \(name) on port \(port).", tone: .info, quiet: quiet)
            return true
        }
        guard let port = freePort(on: manager) else {
            say("All \(USBRedirectController.ports.count) USB slots are in use. Next: detach a device, then attach \(device.displayName).", tone: .failure, quiet: quiet)
            return false
        }
        guard let socketPath = manager.usbRedirSocketPath(port: port) else {
            say("The virtual machine has no socket directory. Step: socket path. Next: wait for the VM to finish starting.", tone: .failure, quiet: quiet)
            return false
        }

        // RESERVED BEFORE THE AWAIT (2026-10-25, code audit): the port used
        // to be recorded only after QEMU answered, so two attaches running at
        // once (the picker and a plug-in send) could both pick the same free
        // port, and the second removed the first one's socket and chardev.
        portByDevice[device] = port
        machineByDevice[device] = WeakManager(manager: manager)
        do {
            try await manager.attachUSBRedirect(port: port, socketPath: socketPath)
        } catch {
            portByDevice[device] = nil
            machineByDevice[device] = nil
            log("QMP attach failed for \(device.description): \(error)")
            say("QEMU refused the USB redirection port. Step: QMP device add. Reason: \(error.localizedDescription). Next: check the diagnostic log.", tone: .failure, quiet: quiet)
            return false
        }
        log("port \(port) -> \(device.description)")
        switch await USBHelperClient.shared.attach(device, socketPath: socketPath, peerPID: manager.qemuPID) {
        case .success:
            log("helper accepted \(device.description); waiting for the attached event")
            return true
        case .failure(let error):
            // The client already spoke the failure, unless the device is
            // quiet. Take the port back so QEMU is not left listening for
            // a stream that never comes.
            log("helper refused \(device.description): \(error); removing the QEMU port")
            await releasePort(for: device, reason: "refused attach")
            // A failed grab can make macOS drop and re-add the device
            // (thumb drive, 2026-10-18). For a manual attach, treat that
            // return like a hand-back, so it isn't asked about as a new
            // plug-in. The send gate tracks its own bounces.
            if quiet == false {
                handedBackAt[USBPlugPrompt.deviceKey(device)] = Date()
            }
            // Asked for the helper's approval (USBHelperClient.waitForApproval):
            // sent once it's approved, if still plugged in. The send gate
            // waits in its own way.
            if quiet == false, case .notEnabled(.requiresApproval) = error {
                log("waiting for the USB helper's approval to send \(device.description)")
                Task { @MainActor [weak manager] in
                    guard await USBHelperClient.shared.waitForApproval(while: { USBHotPlugWatcher.shared.isPresent(device) != false }) else {
                        self.log("no approval for \(device.description); not sent")
                        return
                    }
                    guard let manager, case .running = manager.state, USBHotPlugWatcher.shared.isPresent(device) != false else { return }
                    self.log("helper approved; sending \(device.description) now")
                    await self.attach(device, to: manager)
                }
            }
            return false
        }
    }

    // MARK: Restart USB Helper (2026-10-27)

    /// Returns every device to the Mac, restarts the root helper, and says
    /// how it went. For a device that stays on the Mac when it shouldn't,
    /// from the dashboard or the Virtual Machine menu.
    private(set) var restartingHelper = false

    func restartHelper() async {
        guard !restartingHelper else { return }
        restartingHelper = true
        defer { restartingHelper = false }
        let held = redirectedDevices
        announce(held.isEmpty && BluetoothDevices.shared.attached.isEmpty ? "Restarting AVM's USB helper." : "Returning devices to the Mac and restarting AVM's USB helper.", tone: .info)
        for device in held { await detach(device) }
        await BluetoothDevices.shared.detachAll()
        switch await USBHelperClient.shared.restartHelper() {
        case .success:
            announce("AVM's USB helper restarted. Plug the device in again, or choose Attach USB Device.", tone: .success)
        case .failure(.notEnabled):
            break   // the client has asked for its approval
        case .failure(let error):
            log("restart failed: \(error)")
            announce("AVM's USB helper didn't restart. Reason: \(error). Next: quit and reopen AVM, or restart your Mac.", tone: .failure)
        }
    }

    // MARK: USB drives

    /// Set to false once Apple lets AVM capture USB storage. See the
    /// header.
    static let storageBlocked = true

    /// True, after speaking why, when device is a USB drive and drives
    /// are blocked. Reads the device's interfaces fresh.
    func refusesStorage(_ device: AVMUSBDeviceIdentity) -> Bool {
        guard Self.storageBlocked, USBDeviceEnumerator.hasStorageInterface(device) else { return false }
        refuseStorage(device)
        return true
    }

    /// Speaks why a USB drive stays on the Mac. Always spoken, never
    /// quiet, since no send gate is ever open for a drive.
    func refuseStorage(_ device: AVMUSBDeviceIdentity) {
        log("\(device.description) is a USB drive; not sent (macOS 27 blocks USB storage)")
        announce("\(device.displayName) stays on the Mac. macOS doesn't let AVM send USB drives to Windows yet.", tone: .info)
    }

    private func say(_ message: String, tone: Announcer.Tone, quiet: Bool) {
        if quiet {
            log("not spoken (send gate): \(message)")
        } else {
            announce(message, tone: tone)
        }
    }

    // MARK: Detach

    func detach(_ device: AVMUSBDeviceIdentity) async {
        guard let port = portByDevice[device] else {
            announce("\(device.displayName) is not attached to a virtual machine.", tone: .info)
            return
        }
        portByDevice[device] = nil
        let machine = machineByDevice.removeValue(forKey: device)?.manager
        let key = USBPlugPrompt.deviceKey(device)
        handingBack.insert(key)

        // Helper first. Its reply arrives after the device is back with
        // macOS; the released event is spoken by USBHelperClient.
        switch await USBHelperClient.shared.detach(device) {
        case .success:
            log("helper released \(device.description)")
        case .failure(let error):
            // Already spoken by the client. Still take the QEMU port
            // back; a stale usb-redir device would block the next attach.
            log("helper detach failed: \(error); removing the QEMU port anyway")
        }
        handingBack.remove(key)
        handedBackAt[key] = Date()
        await removeQEMUPort(port, for: device, on: machine)
    }

    // MARK: Port bookkeeping

    private func freePort(on manager: VMManager) -> Int? {
        let used = Set(portByDevice.filter { machineByDevice[$0.key]?.manager === manager }.values)
            .union(reserved.values.filter { $0.machine.manager === manager }.map(\.port))
        return USBRedirectController.ports.first { !used.contains($0) }
    }

    /// Ports held by something other than a USB device: a Bluetooth device
    /// (BluetoothDevices.swift, 2026-10-27), which shares ports 5 to 8.
    private var reserved: [String: (port: Int, machine: WeakManager)] = [:]

    func reservePort(_ key: String, on manager: VMManager) -> Int? {
        guard let port = freePort(on: manager) else { return nil }
        reserved[key] = (port, WeakManager(manager: manager))
        return port
    }

    func releaseReservedPort(_ key: String) {
        reserved[key] = nil
    }

    /// Only when the reservation is still this send's (2026-10-28, second
    /// review): released after a wait, a key could belong to a newer send.
    func releaseReservedPort(_ key: String, port: Int) {
        guard reserved[key]?.port == port else { return }
        reserved[key] = nil
    }

    /// AVM's helper stopped (2026-10-26, code audit): the kernel has given
    /// every device it held back to the Mac, so their ports go, and the
    /// next plug-in attaches afresh instead of "already attached".
    func helperLost() {
        let devices = Array(portByDevice.keys)
        guard !devices.isEmpty else { return }
        Task { @MainActor in
            for device in devices {
                await releasePort(for: device, reason: "the helper stopped")
            }
            Announcer.shared.announce("USB devices sent to the virtual machine are back on the Mac: AVM's helper stopped. Plug them in again to send them.", tone: .failure)
        }
    }

    /// Called for every helper-reported ending. Idempotent: a device
    /// with no port here is already handled.
    private func handleDeviceEnded(_ device: AVMUSBDeviceIdentity, state: AVMUSBDeviceState) async {
        guard portByDevice[device] != nil else { return }
        await releasePort(for: device, reason: "helper reported \(state)")
    }

    private func releasePort(for device: AVMUSBDeviceIdentity, reason: String) async {
        guard let port = portByDevice.removeValue(forKey: device) else { return }
        let machine = machineByDevice.removeValue(forKey: device)?.manager
        log("releasing port \(port) for \(device.description): \(reason)")
        await removeQEMUPort(port, for: device, on: machine)
    }

    /// The device's own machine's port. A machine that's gone took its
    /// ports with it: never the current machine's port of the same number
    /// (2026-10-27, code audit), which belongs to another device.
    private func removeQEMUPort(_ port: Int, for device: AVMUSBDeviceIdentity, on machine: VMManager?) async {
        guard let manager = machine, case .running = manager.state else {
            log("VM not running; port \(port) forgotten without QMP")
            return
        }
        do {
            try await manager.detachUSBRedirect(port: port)
            log("QEMU port \(port) removed")
        } catch {
            log("QMP detach of port \(port) failed: \(error)")
            announce("The USB redirection port for \(device.displayName) could not be removed from QEMU. Step: QMP device delete. Reason: \(error.localizedDescription). Next: restart the virtual machine before the next attach.", tone: .failure)
        }
    }

    // MARK: Plumbing

    private func announce(_ message: String, tone: Announcer.Tone) {
        Announcer.shared.announce(message, tone: tone)
    }

    private func log(_ message: String) {
        AVMLog.write("USBRedirectController: \(message)", category: "USBHelper")
    }
}
