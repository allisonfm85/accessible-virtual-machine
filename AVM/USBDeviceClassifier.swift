//
//  USBDeviceClassifier.swift
//  AVM
//
//  USB increment 2b, piece 4 step 1: decides whether a USB device is
//  protected. The watcher logs the answer; nothing acts on it yet.
//
//  Protected-device rule of record (2026-09-26):
//  - Always mode never sends a protected device to Windows.
//  - A braille display may be remembered for Windows, but only when
//    the user checks Remember in its alert. Never automatic.
//  - Keyboards, mice, and the Mac's current audio output always ask,
//    with no Remember option.
//  - An HID interface whose kind can't be read yet counts as
//    protected. Unknown means ask.
//  - A device with braille evidence is a braille display even if it
//    also reports keyboard or mouse parts: those are its own keys.
//    Being the current audio output still always asks.
//  - Generic serial chips from BRLTTY's table count as possible
//    braille displays (see USBBrailleDeviceTable.swift).
//
//  Evidence (2026-09-26, ioreg on Allison's Mac): keyboard is HID
//  usage page 1 usage 6, trackpad page 1 usage 2, the Monarch page
//  0x41 usage 1, the ATR2100x's buttons page 0x0C usage 1 (consumer
//  controls, not protected). Core Audio's ID string for a USB audio
//  device carries the device's locationID in hex as its second-to-last
//  colon field: "...:ATR2100x-USB Microphone:2100000:1" for location
//  0x2100000.
//

import Foundation
import IOKit
import CoreAudio

struct USBDeviceClassification {
    enum Protection: String {
        /// Not protected. The mode and remembered choices apply.
        case none
        /// A braille display. Always mode skips it; Remember is allowed.
        case brailleDisplay = "braille display"
        /// Always ask, with no Remember option.
        case alwaysAsk = "always ask"
    }

    let protection: Protection
    /// Plain reasons for the protection, for the log.
    let reasons: [String]
    /// Every HID usage found, as "page/usage" in hex, for the log.
    let hidUsages: [String]

    var logText: String {
        let kinds = hidUsages.isEmpty ? "none" : hidUsages.joined(separator: ",")
        if protection == .none {
            return "not protected (HID usages \(kinds))"
        }
        return "protected, \(protection.rawValue): \(reasons.joined(separator: "; ")) (HID usages \(kinds))"
    }
}

enum USBDeviceClassifier {

    static func classify(_ service: io_service_t, identity: AVMUSBDeviceIdentity) -> USBDeviceClassification {
        var braille: [String] = []
        var inputParts: [String] = []
        var audio: [String] = []

        // 1. What each HID interface says it is.
        let hid = hidUsages(of: service)
        for (page, usage) in hid.usages {
            switch (page, usage) {
            case (0x41, _): braille.append("HID braille")
            case (0x01, 0x06), (0x01, 0x07): inputParts.append("keyboard")
            case (0x01, 0x01), (0x01, 0x02): inputParts.append("mouse")
            default: break
            }
        }
        if hid.unreadInterfaces > 0 {
            inputParts.append("HID kind not readable yet")
        }

        // 2. BRLTTY's table, for displays that don't speak HID braille.
        switch USBBrailleDeviceTable.match(vendorID: identity.vendorID, productID: identity.productID) {
        case .braille?: braille.append("in BRLTTY's braille table")
        case .genericChip?: braille.append("generic serial chip braille displays use")
        case nil: break
        }

        // 3. The Mac's current audio output or alert output.
        let output = currentUSBOutput()
        if let location = intProperty(service, "locationID"), output.locations.contains(location) {
            audio.append("the Mac's current audio output")
        } else if output.unreadable,
                  USBDeviceEnumerator.classCodes(for: service).interfaces.contains(0x01) {
            audio.append("may be the Mac's current audio output")
        }

        let usageText = hid.usages.map { String(format: "%02x/%02x", $0.page, $0.usage) }
        if !audio.isEmpty {
            return USBDeviceClassification(protection: .alwaysAsk, reasons: unique(audio + braille + inputParts), hidUsages: usageText)
        }
        if !braille.isEmpty {
            return USBDeviceClassification(protection: .brailleDisplay, reasons: unique(braille + inputParts), hidUsages: usageText)
        }
        if !inputParts.isEmpty {
            return USBDeviceClassification(protection: .alwaysAsk, reasons: unique(inputParts), hidUsages: usageText)
        }
        return USBDeviceClassification(protection: .none, reasons: [], hidUsages: usageText)
    }

    // MARK: HID kinds

    /// Usage pairs from every HID interface of one device, and how many
    /// HID interfaces had no readable kind. Looks at the device's own
    /// interfaces only, never at devices behind a hub.
    private static func hidUsages(of device: io_service_t) -> (usages: [(page: Int, usage: Int)], unreadInterfaces: Int) {
        var usages: [(page: Int, usage: Int)] = []
        var unread = 0
        walk(device, depth: 2) { entry in
            if conforms(entry, "IOUSBHostDevice") { return false }
            if conforms(entry, "IOUSBHostInterface") {
                if intProperty(entry, "bInterfaceClass") == 3 {
                    let found = usagesBelow(entry)
                    if found.isEmpty { unread += 1 } else { usages += found }
                }
                return false
            }
            return true
        }
        return (usages, unread)
    }

    /// The usage pairs of the first HID device entries under one interface.
    private static func usagesBelow(_ interface: io_registry_entry_t) -> [(page: Int, usage: Int)] {
        var found: [(page: Int, usage: Int)] = []
        walk(interface, depth: 5) { entry in
            if conforms(entry, "IOHIDDevice") {
                found += usagePairs(entry)
                return false
            }
            return true
        }
        return found
    }

    /// DeviceUsagePairs when present, else the primary usage.
    private static func usagePairs(_ entry: io_registry_entry_t) -> [(page: Int, usage: Int)] {
        if let raw = IORegistryEntryCreateCFProperty(entry, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] {
            let pairs = raw.compactMap { pair -> (page: Int, usage: Int)? in
                guard let page = (pair["DeviceUsagePage"] as? NSNumber)?.intValue,
                      let usage = (pair["DeviceUsage"] as? NSNumber)?.intValue else { return nil }
                return (page, usage)
            }
            if !pairs.isEmpty { return pairs }
        }
        if let page = intProperty(entry, "PrimaryUsagePage"), let usage = intProperty(entry, "PrimaryUsage") {
            return [(page, usage)]
        }
        return []
    }

    // MARK: Current audio output

    /// Location IDs of USB devices the Mac is playing sound or alerts
    /// through right now. unreadable is true when an output is a USB
    /// device but its location can't be read from Core Audio.
    static func currentUSBOutput() -> (locations: Set<Int>, unreadable: Bool) {
        var locations = Set<Int>()
        var unreadable = false
        let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var device = AudioObjectID(0)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != 0 else { continue }

            address.mSelector = kAudioDevicePropertyTransportType
            var transport = UInt32(0)
            size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeUSB else { continue }

            address.mSelector = kAudioDevicePropertyDeviceUID
            var uid: Unmanaged<CFString>?
            size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else {
                unreadable = true
                continue
            }
            // Read from the end: a product name can contain a colon.
            let fields = (uid.takeRetainedValue() as String).split(separator: ":", omittingEmptySubsequences: false)
            if fields.count >= 3, let location = Int(fields[fields.count - 2], radix: 16) {
                locations.insert(location)
            } else {
                unreadable = true
            }
        }
        return (locations, unreadable)
    }

    // MARK: Registry helpers

    /// Visits each child of entry, then that child's children when
    /// visit returns true, down to depth levels. Each entry is
    /// released after its visit.
    private static func walk(_ entry: io_registry_entry_t, depth: Int, _ visit: (io_registry_entry_t) -> Bool) {
        guard depth > 0 else { return }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            if visit(child) { walk(child, depth: depth - 1, visit) }
            IOObjectRelease(child)
        }
    }

    private static func conforms(_ entry: io_registry_entry_t, _ className: String) -> Bool {
        IOObjectConformsTo(entry, className) != 0
    }

    private static func intProperty(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return (raw.takeRetainedValue() as? NSNumber)?.intValue
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
