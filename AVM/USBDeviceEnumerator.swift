//
//  USBDeviceEnumerator.swift
//  AVM
//
//  Unprivileged USB enumeration. Lists the devices macOS can see and
//  builds the identity the root helper needs to find one again.
//
//  Scope contract (handoff 46, decision 1b): the helper never lists
//  devices. AVM lists them here with IOKit, which needs no privilege
//  and no libusb in the AVM target, and hands the helper a bus number,
//  a device address and a vendor:product to check them against.
//
//  Bus and address come from two IORegistry properties on each
//  IOUSBHostDevice: bus is the top byte of locationID, address is the
//  "USB Address" property. That is how libusb's darwin backend derives
//  the same two numbers on its side, so the helper's
//  libusb_get_bus_number / libusb_get_device_address lookup lands on
//  the same device. This mapping is a theory until the live proof
//  compares it against `probe3 list`; the helper's own vendor:product
//  check at step "identify" is the backstop if it is wrong.
//

import Foundation
import IOKit

enum USBDeviceEnumerator {

    /// Every USB device macOS currently sees, in registry order.
    /// Devices missing any of the four numeric properties are skipped
    /// (hubs and roots usually have them; a device without them could
    /// not be handed to the helper anyway).
    static func all() -> [AVMUSBDeviceIdentity] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            AVMLog.write("USBDeviceEnumerator: IOServiceMatching returned nil", category: "USBHelper")
            return []
        }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            AVMLog.write("USBDeviceEnumerator: IOServiceGetMatchingServices failed: \(kr)", category: "USBHelper")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [AVMUSBDeviceIdentity] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            if let identity = identity(for: service) {
                found.append(identity)
            }
        }
        return found
    }

    /// The devices matching one vendor:product. More than one means
    /// two of the same model are plugged in; the caller decides.
    static func devices(vendorID: UInt16, productID: UInt16) -> [AVMUSBDeviceIdentity] {
        all().filter { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// Builds the identity for one IOUSBHostDevice registry entry, or nil
    /// when any of the four numeric properties is missing. all() and the
    /// hot-plug watcher both use this, so they always agree on a device.
    static func identity(for service: io_service_t) -> AVMUSBDeviceIdentity? {
        guard let vendor = number(service, "idVendor"),
              let product = number(service, "idProduct"),
              let location = number(service, "locationID"),
              let address = number(service, "USB Address")
        else { return nil }

        return AVMUSBDeviceIdentity(
            vendorID: UInt16(truncatingIfNeeded: vendor),
            productID: UInt16(truncatingIfNeeded: product),
            busNumber: UInt8(truncatingIfNeeded: location >> 24),
            deviceAddress: UInt8(truncatingIfNeeded: address),
            serialNumber: string(service, "USB Serial Number"),
            productString: string(service, "USB Product Name") ?? ""
        )
    }

    /// The USB class codes one device reports: its own class from the
    /// device descriptor, and the classes of the interfaces under it.
    /// Many devices report 0 at the device level and put their real
    /// classes on the interfaces. A USB microphone with volume buttons
    /// can show audio (1) and HID (3). Interfaces are read from the
    /// device's children and grandchildren only, so a hub never reports
    /// the interfaces of devices plugged into it. Right after a device
    /// arrives, macOS may not have published its interfaces yet, so an
    /// empty list can mean "not yet" as well as "none".
    static func classCodes(for service: io_service_t) -> (device: Int?, interfaces: [Int]) {
        let deviceClass = number(service, "bDeviceClass")
        var interfaceClasses = Set<Int>()
        forEachChild(of: service) { child in
            if IOObjectConformsTo(child, "IOUSBHostDevice") != 0 { return }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                if let c = number(child, "bInterfaceClass") { interfaceClasses.insert(c) }
                return
            }
            forEachChild(of: child) { grandchild in
                if IOObjectConformsTo(grandchild, "IOUSBHostInterface") != 0,
                   let c = number(grandchild, "bInterfaceClass") {
                    interfaceClasses.insert(c)
                }
            }
        }
        return (deviceClass, interfaceClasses.sorted())
    }

    /// Calls body once for each direct child of entry in the IOService
    /// plane. Each child is released after body returns.
    private static func forEachChild(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            body(child)
            IOObjectRelease(child)
        }
    }

    // MARK: Registry property readers

    private static func number(_ service: io_service_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (raw.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return raw.takeRetainedValue() as? String
    }
}
