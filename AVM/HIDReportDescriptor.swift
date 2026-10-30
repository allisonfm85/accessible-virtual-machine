// HIDReportDescriptor.swift
// AVM — Accessible Virtual Machine
//
// What a HID device is, read from its report descriptor (2026-10-29): the
// usage of each top-level application collection, the pairs macOS lists
// as a device's DeviceUsagePairs. For a Bluetooth device AVM has only the
// descriptor (the helper's list), and it needs to know before a send
// whether the device has a keyboard in it: macOS lets the helper open one
// that does only when AVM is allowed under Input Monitoring
// (InputMonitoring.swift). An APH Mantis Q40's pairs are 93/01, 41/01,
// 01/06 and 01/00: a braille display whose keys are a keyboard too.

import Foundation

enum HIDReportDescriptor {
    /// The usage page and usage of each top-level application collection,
    /// in order. A long item is skipped; a short one cut off ends the read.
    static func applicationUsages(_ descriptor: Data) -> [(page: Int, usage: Int)] {
        let bytes = [UInt8](descriptor)
        var found: [(page: Int, usage: Int)] = []
        var page: UInt32 = 0
        var pushedPages: [UInt32] = []
        // Local usages until the next main item. A 4-byte usage carries its
        // own page; a shorter one takes the page in force at the main item.
        var usages: [(value: UInt32, hasPage: Bool)] = []
        var depth = 0
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xfe {
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard i + size < bytes.count else { break }
            var value: UInt32 = 0
            for k in 0..<size { value |= UInt32(bytes[i + 1 + k]) << (8 * k) }
            switch prefix & 0xfc {
            case 0x04: page = value                                     // Usage Page
            case 0xa4: pushedPages.append(page)                         // Push
            case 0xb4: page = pushedPages.popLast() ?? page             // Pop
            case 0x08: usages.append((value, size == 4))                // Usage
            case 0xa0:                                                  // Collection
                if depth == 0, (value & 0xff) == 1, let first = usages.first {
                    let full = first.hasPage ? first.value : (page << 16) | first.value
                    found.append((page: Int(full >> 16), usage: Int(full & 0xffff)))
                }
                depth += 1
                usages = []
            case 0xc0:                                                  // End Collection
                depth = max(0, depth - 1)
                usages = []
            case 0x80, 0x90, 0xb0: usages = []                          // Input, Output, Feature
            default: break
            }
            i += 1 + size
        }
        return found
    }

    /// True when one of them is a keyboard or a keypad.
    static func hasKeyboard(_ descriptor: Data) -> Bool {
        applicationUsages(descriptor).contains { $0.page == 0x01 && ($0.usage == 0x06 || $0.usage == 0x07) }
    }
}
