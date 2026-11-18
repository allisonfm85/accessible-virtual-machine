//
//  AccessoryGrantListener.swift
//  AVM
//
//  DEBUG ONLY. The Claim USB Accessory test (Handoffs 66 to 68).
//  Released AVM never compiles this file.
//
//  macOS 27 lets the user hand a USB device to an app through the
//  Virtual Machine Accessories menu in the menu bar. The app has to be
//  registered as a listener to receive it. Handoff 67 proved the path:
//  once a thumb drive was granted, QEMU, started by AVM, took it with
//  usb-host and Windows used it, with no root helper.
//
//  Handoff 67 also found that listening is a grab. While AVM listened for
//  every device, macOS handed over every device granted earlier, even at
//  launch, and quitting AVM gave them all back. So this version listens
//  per device, and only when asked:
//    - Debug > Grant Test: Listen for a USB Device registers one listener
//      whose matching criteria name only that device's vendor and product
//      IDs. If the device was granted before, macOS should hand it over
//      at once. If not, the user grants it in Virtual Machine Accessories.
//    - Debug > Grant Test: Stop Listening unregisters that one listener.
//      Apple's unregister call takes the listener object, so each device
//      needs its own listener. The question is whether macOS then gives
//      back only that device, without AVM quitting.
//    - Debug > Grant Test: Status speaks what AVM is listening for and
//      which of those devices AVM has now.
//  Nothing listens at launch. Nothing is remembered between launches yet.
//
//  This file only registers, reports and unregisters. It never opens a
//  device. The test asks QEMU to take a granted device with usb-host,
//  over the diagnostic QMP socket.
//

#if DEBUG
import AccessoryAccess
import AppKit
import Foundation
import IOKit

/// The Debug menu's three Grant Test items. Holds one listener per device.
@available(macOS 27.0, *)
enum AccessoryGrantTest {

    /// Listeners by "vvvv:pppp". A listener stays here until macOS
    /// confirms it's unregistered.
    private static var listeners: [String: AccessoryGrantListener] = [:]

    static func key(_ vendorID: UInt16, _ productID: UInt16) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    // MARK: Listen

    static func chooseDeviceToListen() {
        var seen = Set<String>()
        var choices: [AVMUSBDeviceIdentity] = []
        for device in USBDeviceEnumerator.all() {
            let k = key(device.vendorID, device.productID)
            if seen.contains(k) || listeners[k] != nil { continue }
            seen.insert(k)
            choices.append(device)
        }
        guard !choices.isEmpty else {
            Announcer.shared.announce("No other USB devices are plugged in.", tone: .info)
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for device in choices {
            let name = device.productString.isEmpty ? "Unnamed USB device" : device.productString
            popup.addItem(withTitle: "\(name) (\(key(device.vendorID, device.productID)))")
        }
        popup.setAccessibilityLabel("USB device")

        let alert = NSAlert()
        alert.messageText = "Listen for which USB device?"
        alert.informativeText = "AVM will listen for this device only. If you gave it to AVM before, macOS should hand it over right away. If not, give it to AVM in Virtual Machine Accessories."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Listen")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let device = choices[popup.indexOfSelectedItem]
        let name = device.productString.isEmpty ? "the USB device" : device.productString
        let listener = AccessoryGrantListener(vendorID: device.vendorID,
                                              productID: device.productID,
                                              name: name)
        listeners[listener.key] = listener
        listener.start()
    }

    // MARK: Stop

    static func chooseDeviceToStop() {
        let active = listeners.values.sorted { $0.name < $1.name }
        guard !active.isEmpty else {
            Announcer.shared.announce("AVM isn't listening for any USB devices.", tone: .info)
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for listener in active {
            popup.addItem(withTitle: "\(listener.name) (\(listener.key))")
        }
        popup.setAccessibilityLabel("USB device")

        let alert = NSAlert()
        alert.messageText = "Stop listening for which USB device?"
        alert.informativeText = "If AVM has this device, macOS should give it back to the Mac."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Stop Listening")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        active[popup.indexOfSelectedItem].stop()
    }

    /// Called by a listener once macOS confirms it's unregistered.
    static func forget(_ key: String) {
        listeners[key] = nil
    }

    // MARK: Status

    static func speakStatus() {
        let active = listeners.values.sorted { $0.name < $1.name }
        guard !active.isEmpty else {
            log("status: not listening for any devices")
            Announcer.shared.announce("AVM isn't listening for any USB devices.", tone: .info)
            return
        }
        let parts = active.map { listener in
            "\(listener.name), \(listener.hasDevice ? "with AVM" : "not with AVM")"
        }
        let line = "AVM is listening for \(active.count) USB device\(active.count == 1 ? "" : "s"): " + parts.joined(separator: "; ") + "."
        log("status: \(line)")
        Announcer.shared.announce(line, tone: .info)
    }

    static func log(_ message: String) {
        AVMLog.write("AccessoryGrantTest: \(message)", category: "USBHelper")
    }
}

/// Listens for one device, by vendor and product ID.
@available(macOS 27.0, *)
nonisolated final class AccessoryGrantListener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {

    let vendorID: UInt16
    let productID: UInt16
    let name: String
    let key: String

    /// Granted devices by registry ID. Touched only on the main actor.
    private var granted: [UInt64: AAUSBAccessory] = [:]

    @MainActor var hasDevice: Bool { !granted.isEmpty }

    init(vendorID: UInt16, productID: UInt16, name: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.key = String(format: "%04x:%04x", vendorID, productID)
        super.init()
    }

    @MainActor
    func start() {
        let device = AAUSBAccessoryMatchingCriteria.DeviceMatchingCriteria(
            vendorID: Int(vendorID), productID: Int(productID),
            deviceClass: nil, deviceSubClass: nil, deviceProtocol: nil, speed: nil)
        let criteria = AAUSBAccessoryMatchingCriteria(deviceMatchingCriteria: device)
        let name = self.name
        let key = self.key
        AccessoryGrantTest.log("registering for \(name) (\(key)) only")
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: [criteria]) { list, error in
            let lines = list.map { Self.describe($0) }
            let ids = list.map { $0.registryID }
            Task { @MainActor in
                if let error {
                    AccessoryGrantTest.log("registering for \(key) failed: \(error)")
                    AccessoryGrantTest.forget(key)
                    Announcer.shared.announce("AVM couldn't listen for \(name). Reason: \(error.localizedDescription)", tone: .failure)
                    return
                }
                for (id, accessory) in zip(ids, list) { self.granted[id] = accessory }
                AccessoryGrantTest.log("registered for \(key); already granted: \(lines.count)")
                for line in lines { AccessoryGrantTest.log("already granted: \(line)") }
                if lines.isEmpty {
                    Announcer.shared.announce("AVM is listening for \(name). It isn't given to AVM yet.", tone: .info)
                } else {
                    Announcer.shared.announce("AVM is listening for \(name), and macOS handed it over.", tone: .success)
                }
            }
        }
    }

    @MainActor
    func stop() {
        let name = self.name
        let key = self.key
        AccessoryGrantTest.log("unregistering \(key)")
        AAUSBAccessoryManager.shared.unregisterListener(self) {
            Task { @MainActor in
                self.granted.removeAll()
                AccessoryGrantTest.forget(key)
                AccessoryGrantTest.log("unregistered \(key)")
                Announcer.shared.announce("AVM stopped listening for \(name).", tone: .info)
            }
        }
    }

    // MARK: AAUSBAccessoryListener

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        let line = Self.describe(usbAccessory)
        let name = Self.productName(usbAccessory)
        let key = self.key
        Task { @MainActor in
            self.granted[id] = usbAccessory
            AccessoryGrantTest.log("granted to AVM (listener \(key)): \(line)")
            Announcer.shared.announce("AVM received \(name).", tone: .info)
        }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        let id = usbAccessory.registryID
        let key = self.key
        let name = self.name
        Task { @MainActor in
            self.granted[id] = nil
            AccessoryGrantTest.log("taken back or unplugged (listener \(key)): registry \(id)")
            Announcer.shared.announce("\(name) left AVM.", tone: .info)
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
}
#endif
