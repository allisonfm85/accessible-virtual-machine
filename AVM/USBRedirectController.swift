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
//  a vanish cleanup the helper never reported (2026-10-17).
//
//  Send gate (USB 2c, 2026-10-18): USBPlugPrompt marks a device quiet
//  in USBHelperClient while it handles an automatic send. Then attach
//  (quiet: true) logs instead of speaking, the vanish cleanup's unplug
//  line is logged, and the gate speaks one outcome itself.
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

    /// The watcher saw a device leave the Mac. If it was in Windows and
    /// still holds a port after vanishGrace, the helper never reported
    /// it (a Monarch switching modes, 2026-10-17), so AVM speaks the
    /// unplug, frees the port, and quietly tells the helper to drop it.
    func deviceVanished(_ device: AVMUSBDeviceIdentity) {
        guard let held = heldIdentity(matching: device) else { return }
        let followKey = Self.followKey(held)
        leftWindowsAt[followKey] = Date()
        leftWindowsCopy[followKey] = held
        Task { @MainActor in
            try? await Task.sleep(for: Self.vanishGrace)
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
    /// Terminal (2026-10-17). With no serial, maker and product.
    nonisolated static func followKey(_ device: AVMUSBDeviceIdentity) -> String {
        if let serial = device.serialNumber, serial.isEmpty == false {
            return "\(device.vendorID):serial:\(serial)"
        }
        return "\(device.vendorID):\(device.productID):noserial"
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

    // MARK: Attach

    /// Returns true when the helper accepted the device (the attached
    /// event comes later) or it already holds a port. quiet: log the
    /// failures instead of speaking them; the send gate speaks one
    /// outcome itself.
    @discardableResult
    func attach(_ device: AVMUSBDeviceIdentity, quiet: Bool = false) async -> Bool {
        guard let manager = VMManager.shared, case .running = manager.state else {
            say("The virtual machine is not running. Start it, then attach \(device.displayName).", tone: .failure, quiet: quiet)
            return false
        }
        if let port = portByDevice[device] {
            say("\(device.displayName) is already attached to the virtual machine on port \(port).", tone: .info, quiet: quiet)
            return true
        }
        guard let port = freePort() else {
            say("All \(USBRedirectController.ports.count) USB slots are in use. Next: detach a device, then attach \(device.displayName).", tone: .failure, quiet: quiet)
            return false
        }
        guard let socketPath = manager.usbRedirSocketPath(port: port) else {
            say("The virtual machine has no socket directory. Step: socket path. Next: wait for the VM to finish starting.", tone: .failure, quiet: quiet)
            return false
        }

        do {
            try await manager.attachUSBRedirect(port: port, socketPath: socketPath)
        } catch {
            log("QMP attach failed for \(device.description): \(error)")
            say("QEMU refused the USB redirection port. Step: QMP device add. Reason: \(error.localizedDescription). Next: check the diagnostic log.", tone: .failure, quiet: quiet)
            return false
        }

        portByDevice[device] = port
        log("port \(port) -> \(device.description)")
        switch await USBHelperClient.shared.attach(device, socketPath: socketPath) {
        case .success:
            log("helper accepted \(device.description); waiting for the attached event")
            return true
        case .failure(let error):
            // The client already spoke the failure, unless the device is
            // quiet. Take the port back so QEMU is not left listening for
            // a stream that never comes.
            log("helper refused \(device.description): \(error); removing the QEMU port")
            await releasePort(for: device, reason: "refused attach")
            return false
        }
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
            announce("\(device.displayName) is not attached to the virtual machine.", tone: .info)
            return
        }
        portByDevice[device] = nil
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
        await removeQEMUPort(port, for: device)
    }

    // MARK: Port bookkeeping

    private func freePort() -> Int? {
        let used = Set(portByDevice.values)
        return USBRedirectController.ports.first { !used.contains($0) }
    }

    /// Called for every helper-reported ending. Idempotent: a device
    /// with no port here is already handled.
    private func handleDeviceEnded(_ device: AVMUSBDeviceIdentity, state: AVMUSBDeviceState) async {
        guard portByDevice[device] != nil else { return }
        await releasePort(for: device, reason: "helper reported \(state)")
    }

    private func releasePort(for device: AVMUSBDeviceIdentity, reason: String) async {
        guard let port = portByDevice.removeValue(forKey: device) else { return }
        log("releasing port \(port) for \(device.description): \(reason)")
        await removeQEMUPort(port, for: device)
    }

    private func removeQEMUPort(_ port: Int, for device: AVMUSBDeviceIdentity) async {
        guard let manager = VMManager.shared, case .running = manager.state else {
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
