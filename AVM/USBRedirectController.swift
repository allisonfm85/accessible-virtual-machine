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
//  returned, failed, unplugged). This file speaks only what the client
//  cannot know: VM not running, nothing attached, no port free, and
//  QMP failures with their step and next action.
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

    func attach(_ device: AVMUSBDeviceIdentity) async {
        guard let manager = VMManager.shared, case .running = manager.state else {
            announce("The virtual machine is not running. Start it, then attach \(device.displayName).", tone: .failure)
            return
        }
        if let port = portByDevice[device] {
            announce("\(device.displayName) is already attached to the virtual machine on port \(port).", tone: .info)
            return
        }
        guard let port = freePort() else {
            announce("All \(USBRedirectController.ports.count) USB slots are in use. Next: detach a device, then attach \(device.displayName).", tone: .failure)
            return
        }
        guard let socketPath = manager.usbRedirSocketPath(port: port) else {
            announce("The virtual machine has no socket directory. Step: socket path. Next: wait for the VM to finish starting.", tone: .failure)
            return
        }

        do {
            try await manager.attachUSBRedirect(port: port, socketPath: socketPath)
        } catch {
            log("QMP attach failed for \(device.description): \(error)")
            announce("QEMU refused the USB redirection port. Step: QMP device add. Reason: \(error.localizedDescription). Next: check the diagnostic log.", tone: .failure)
            return
        }

        portByDevice[device] = port
        log("port \(port) -> \(device.description)")
        switch await USBHelperClient.shared.attach(device, socketPath: socketPath) {
        case .success:
            log("helper accepted \(device.description); waiting for the attached event")
        case .failure(let error):
            // The client already spoke the failure. Take the port back
            // so QEMU is not left listening for a stream that never comes.
            log("helper refused \(device.description): \(error); removing the QEMU port")
            await releasePort(for: device, reason: "refused attach")
        }
    }

    // MARK: Detach

    func detach(_ device: AVMUSBDeviceIdentity) async {
        guard let port = portByDevice[device] else {
            announce("\(device.displayName) is not attached to the virtual machine.", tone: .info)
            return
        }
        portByDevice[device] = nil

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
