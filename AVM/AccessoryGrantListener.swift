//
//  AccessoryGrantListener.swift
//  AVM
//
//  DEBUG ONLY. The first step of the Claim USB Accessory test
//  (Handoff 66, 2026-11-17). Released AVM never compiles this file.
//
//  macOS 27 lets the user hand a USB device to an app through the
//  Virtual Machine Accessories menu in the menu bar. The app has to be
//  registered as a listener to receive it. Accessory Probe showed that
//  once a drive is granted, macOS's own drive driver lets go, and an
//  ordinary process from the same app can claim it with libusb, without
//  root. QEMU is started by AVM, so it should count as that process.
//
//  This file only registers and reports. It logs every grant and every
//  device taken back or unplugged, and speaks "AVM received [name]." It
//  never opens a device. The test then asks QEMU directly, over the
//  diagnostic QMP socket, to take the granted device with usb-host.
//
//  The empty matching list means every USB device can be granted to AVM.
//  Narrowing that is an open question in Handoff 66.
//

#if DEBUG
import AccessoryAccess
import AppKit
import Foundation
import IOKit

@available(macOS 27.0, *)
nonisolated final class AccessoryGrantListener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {

    static let shared = AccessoryGrantListener()

    /// Granted devices by registry ID, held for as long as macOS lets AVM
    /// keep them. Touched only on the main actor.
    private var granted: [UInt64: AAUSBAccessory] = [:]

    private override init() { super.init() }

    /// Called once at launch from AVMAppDelegate.
    @MainActor
    static func start() {
        log("registering for every USB device")
        AAUSBAccessoryManager.shared.registerListener(shared, matchingCriteria: []) { list, error in
            let names = list.map { describe($0) }
            let ids = list.map { $0.registryID }
            Task { @MainActor in
                if let error {
                    log("registering failed: \(error)")
                    return
                }
                log("registered; devices already granted: \(names.count)")
                for (id, accessory) in zip(ids, list) { shared.granted[id] = accessory }
                for name in names { log("already granted: \(name)") }
            }
        }
    }

    // MARK: AAUSBAccessoryListener

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        let line = Self.describe(usbAccessory)
        let name = Self.productName(usbAccessory)
        Task { @MainActor in
            self.granted[id] = usbAccessory
            Self.log("granted to AVM: \(line)")
            Announcer.shared.announce("AVM received \(name).", tone: .info)
        }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        Task { @MainActor in
            self.granted[id] = nil
            Self.log("taken back or unplugged: registry \(id)")
        }
    }

    // MARK: Describing a device

    /// The product name from the I/O Registry, or "a USB device".
    static func productName(_ accessory: AAUSBAccessory) -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IORegistryEntryIDMatching(accessory.registryID))
        guard service != 0 else { return "a USB device" }
        defer { IOObjectRelease(service) }
        for key in ["USB Product Name", "kUSBProductString"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, !value.isEmpty {
                return value
            }
        }
        return "a USB device"
    }

    /// Name, vendor and product IDs, interface classes and registry ID,
    /// for the log. The IDs are what the usb-host test command needs.
    static func describe(_ accessory: AAUSBAccessory) -> String {
        let d = [UInt8](accessory.deviceDescriptorData)
        var ids = "IDs unknown"
        if d.count >= 12 {
            let vid = UInt16(d[8]) | UInt16(d[9]) << 8
            let pid = UInt16(d[10]) | UInt16(d[11]) << 8
            ids = String(format: "%04x:%04x", vid, pid)
        }
        var classes: [Int] = []
        if let config = accessory.configurationDescriptorData {
            let b = [UInt8](config)
            var i = 0
            while i + 1 < b.count {
                let length = Int(b[i])
                if length == 0 { break }
                if b[i + 1] == 4, i + 5 < b.count { classes.append(Int(b[i + 5])) }
                i += length
            }
        }
        let interfaces = classes.isEmpty
            ? "interfaces unknown"
            : "interface classes " + classes.map(String.init).joined(separator: ", ")
        return "\(productName(accessory)) (\(ids); \(interfaces); registry \(accessory.registryID))"
    }

    @MainActor
    private static func log(_ message: String) {
        AVMLog.write("AccessoryGrantListener: \(message)", category: "USBHelper")
    }
}
#endif
