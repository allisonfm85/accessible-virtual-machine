//
//  USBRedirectDebug.swift
//  AVM
//
//  DEBUG BUILDS ONLY. The driver behind the Debug menu's "USB Helper:
//  Attach ATR2100x" and "Detach ATR2100x" actions: the first AVM-side
//  caller of the helper's real attach path (increment 1b, 2026-09-12).
//  Nothing here ships. Increment 2 replaces this with the device
//  picker and the announcement layer.
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
//  Every outcome is spoken through USBHelperClient's state handling
//  or here; every failure names its step.
//

#if DEBUG

import Foundation

@MainActor
enum USBRedirectDebug {

    /// The Audio-Technica ATR2100x-USB, the test device of record.
    static let testVendorID: UInt16 = 0x0909
    static let testProductID: UInt16 = 0x004d
    static let testVidPid = "0909:004d"

    /// First free root port on the qemu-xhci p2=8,p3=8 map (handoff 48).
    static let port = 5

    /// The device this instrument handed to the helper, if any.
    private(set) static var current: AVMUSBDeviceIdentity?

    static func attachTestDevice() async {
        guard let manager = VMManager.shared, case .running = manager.state else {
            announce("The virtual machine is not running. Start it, then attach.", tone: .failure)
            return
        }
        if let held = current {
            announce("\(held.displayName) is already attached through the helper. Detach it first.", tone: .info)
            return
        }

        let seen = USBDeviceEnumerator.all()
        log("enumerated \(seen.count) USB devices")
        for d in seen {
            log("  \(d.description)")
        }
        let matches = seen.filter { $0.vendorID == testVendorID && $0.productID == testProductID }
        guard let device = matches.first else {
            announce("No device with ID \(testVidPid) is plugged in. Next: plug in the ATR2100x and try again.", tone: .failure)
            return
        }
        if matches.count > 1 {
            log("more than one \(testVidPid) present; using the first: \(device.description)")
        }

        guard let socketPath = manager.usbRedirSocketPath(port: port) else {
            announce("The virtual machine has no socket directory. Step: socket path. Next: wait for the VM to finish starting.", tone: .failure)
            return
        }

        do {
            try await manager.attachUSBRedirect(port: port, socketPath: socketPath)
        } catch {
            log("QMP attach failed: \(error)")
            announce("QEMU refused the USB redirection port. Step: QMP device add. Reason: \(error.localizedDescription). Next: check the diagnostic log.", tone: .failure)
            return
        }

        current = device
        switch await USBHelperClient.shared.attach(device, socketPath: socketPath) {
        case .success:
            log("helper accepted \(device.description); waiting for the attached event")
        case .failure(let error):
            // The client already spoke the failure. Take the port back
            // so QEMU is not left listening for a stream that never comes.
            log("helper refused \(device.description): \(error); removing the QEMU port")
            current = nil
            do {
                try await manager.detachUSBRedirect(port: port)
            } catch {
                log("QMP cleanup after refused attach failed: \(error)")
            }
        }
    }

    static func detachTestDevice() async {
        guard let device = current else {
            announce("Nothing is attached through the helper.", tone: .info)
            return
        }
        current = nil

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

        guard let manager = VMManager.shared else {
            log("no VMManager at detach; QEMU port not removed")
            return
        }
        do {
            try await manager.detachUSBRedirect(port: port)
            log("QEMU port \(port) removed")
        } catch {
            log("QMP detach failed: \(error)")
            announce("The USB redirection port could not be removed from QEMU. Step: QMP device delete. Reason: \(error.localizedDescription). Next: restart the virtual machine before the next attach.", tone: .failure)
        }
    }

    // MARK: Plumbing

    private static func announce(_ message: String, tone: Announcer.Tone) {
        Announcer.shared.announce(message, tone: tone)
    }

    private static func log(_ message: String) {
        AVMLog.write("USBRedirectDebug: \(message)", category: "USBHelper")
    }
}

#endif
