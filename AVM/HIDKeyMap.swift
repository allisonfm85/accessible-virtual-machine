// HIDKeyMap.swift
// AVM — Accessible Virtual Machine
//
// USB HID keyboard usages (page 7) to the PC set 1 scancodes AVM sends
// Windows through SPICE (2026-10-26), for the keyboard for Windows
// (WindowsKeyboard.swift), whose keys arrive from the helper as HID
// usages rather than as Mac key events. Extended keys carry 0x100, as in
// VMView's own table (scancode(forVirtualKey:)). A key position, not a
// letter: Windows applies its own keyboard layout, as for any PC keyboard.

import Foundation

nonisolated enum HIDKeyMap {

    static func scancode(forUsage usage: Int) -> Int? { table[usage] }

    private static let extended = 0x100

    /// An Apple keyboard's Fn key, as the helper passes it (not a page-7
    /// usage; KeyboardHold.handle).
    static let fnUsage = 0x1_0003
    /// Pause has no plain scancode: PC keyboards send E1 1D 45 E1 9D C5,
    /// which CocoaSpice's sendPause does. WindowsKeyboard sends it that way.
    static let pauseUsage = 0x48

    /// With Fn held, what an Apple keyboard's keys mean on a Mac, as the
    /// PC keys that do the same in Windows: Forward Delete, Page Up and
    /// Down, Home, End.
    static let fnLayer: [Int: Int] = [
        0x2A: extended | 0x53,   // Fn-Backspace: Delete
        0x52: extended | 0x49,   // Fn-Up: Page Up
        0x51: extended | 0x51,   // Fn-Down: Page Down
        0x50: extended | 0x47,   // Fn-Left: Home
        0x4F: extended | 0x4F,   // Fn-Right: End
        0x28: extended | 0x1C,   // Fn-Return: keypad Enter
    ]

    /// An Apple ISO keyboard reports the key left of 1 (§) and the key
    /// right of left Shift (`) the other way round from a PC keyboard;
    /// macOS swaps them back, and with the keyboard held, AVM does, when
    /// the setting says so.
    static func isoSwapped(_ usage: Int) -> Int {
        switch usage {
        case 0x35: return 0x64
        case 0x64: return 0x35
        default: return usage
        }
    }

    static let table: [Int: Int] = {
        var t: [Int: Int] = [:]
        // Letters a-z, in HID order.
        let letters = [0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
                       0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C]
        for (i, code) in letters.enumerated() { t[0x04 + i] = code }
        // 1-9, 0.
        for i in 0..<10 { t[0x1E + i] = 0x02 + i }
        let pairs: [(Int, Int)] = [
            (0x28, 0x1C), (0x29, 0x01), (0x2A, 0x0E), (0x2B, 0x0F), (0x2C, 0x39),  // Return Esc Backspace Tab Space
            (0x2D, 0x0C), (0x2E, 0x0D), (0x2F, 0x1A), (0x30, 0x1B), (0x31, 0x2B),  // - = [ ] \
            (0x32, 0x2B), (0x33, 0x27), (0x34, 0x28), (0x35, 0x29), (0x36, 0x33),  // non-US # ; ' ` ,
            (0x37, 0x34), (0x38, 0x35), (0x39, 0x3A),                              // . / Caps Lock
            (0x44, 0x57), (0x45, 0x58),                                            // F11 F12
            (0x46, extended | 0x37), (0x47, 0x46),                                 // Print Screen, Scroll Lock
            (0x49, extended | 0x52), (0x4A, extended | 0x47), (0x4B, extended | 0x49), // Insert Home Page Up
            (0x4C, extended | 0x53), (0x4D, extended | 0x4F), (0x4E, extended | 0x51), // Delete End Page Down
            (0x4F, extended | 0x4D), (0x50, extended | 0x4B), (0x51, extended | 0x50), (0x52, extended | 0x48), // arrows: right left down up
            (0x53, 0x45), (0x54, extended | 0x35), (0x55, 0x37), (0x56, 0x4A), (0x57, 0x4E), // Num Lock, keypad / * - +
            (0x58, extended | 0x1C),                                               // keypad Enter
            (0x59, 0x4F), (0x5A, 0x50), (0x5B, 0x51), (0x5C, 0x4B), (0x5D, 0x4C),  // keypad 1-5
            (0x5E, 0x4D), (0x5F, 0x47), (0x60, 0x48), (0x61, 0x49), (0x62, 0x52),  // keypad 6-9, 0
            (0x63, 0x53), (0x64, 0x56), (0x65, extended | 0x5D), (0x67, 0x59),     // keypad . , non-US \\, Menu, keypad =
            (0x7F, extended | 0x20), (0x80, extended | 0x30), (0x81, extended | 0x2E), // Mute, Volume Up, Volume Down
            (0x85, 0x7E),                                                          // keypad , (Brazilian)
            (0x87, 0x73), (0x88, 0x70), (0x89, 0x7D), (0x8A, 0x79), (0x8B, 0x7B),  // Japanese Ro Kana Yen Henkan Muhenkan
            (0xE0, 0x1D), (0xE1, 0x2A), (0xE2, 0x38), (0xE3, extended | 0x5B),     // left Ctrl Shift Alt Windows
            (0xE4, extended | 0x1D), (0xE5, 0x36), (0xE6, extended | 0x38), (0xE7, extended | 0x5C), // right ones
        ]
        for (usage, code) in pairs { t[usage] = code }
        // F1-F10.
        for i in 0..<10 { t[0x3A + i] = 0x3B + i }
        // F13-F24.
        let f13 = [0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x76]
        for (i, code) in f13.enumerated() { t[0x68 + i] = code }
        return t
    }()
}

/// The keyboard for Windows' keys, from HID usages to what Windows gets
/// (2026-10-26): Fn combinations, the Apple ISO swap, Pause, and each
/// release matching its press. Pure, so the tests run it (AVMLogicTests).
nonisolated struct WindowsKeyTranslator {
    enum Output: Equatable {
        case key(Int32, down: Bool)
        case pause(down: Bool)
    }

    var appleISO = false
    private(set) var fnHeld = false
    private(set) var pressed = Set<Int32>()
    /// What each held key was sent as, so its release matches its press
    /// even if Fn came up in between.
    private var sentFor: [Int: Int32] = [:]

    mutating func translate(usage rawUsage: Int, pressed down: Bool) -> Output? {
        if rawUsage == HIDKeyMap.fnUsage { fnHeld = down; return nil }
        let usage = appleISO ? HIDKeyMap.isoSwapped(rawUsage) : rawUsage
        if usage == HIDKeyMap.pauseUsage { return .pause(down: down) }
        if down {
            guard let code = (fnHeld ? HIDKeyMap.fnLayer[usage] : nil) ?? HIDKeyMap.scancode(forUsage: usage) else { return nil }
            let scancode = Int32(code)
            sentFor[usage] = scancode
            pressed.insert(scancode)
            return .key(scancode, down: true)
        }
        guard let scancode = sentFor.removeValue(forKey: usage) ?? HIDKeyMap.scancode(forUsage: usage).map(Int32.init) else { return nil }
        pressed.remove(scancode)
        return .key(scancode, down: false)
    }

    /// Everything still down, to release; the state starts over.
    mutating func releaseAll() -> [Int32] {
        let codes = Array(pressed)
        pressed.removeAll()
        sentFor.removeAll()
        fnHeld = false
        return codes
    }
}

/// Which side of a modifier a Mac key event is about (2026-10-26): the
/// device-dependent bits of NSEvent's modifier flags (IOLLEvent.h's
/// NX_DEVICE…KEYMASK). The device-independent .shift stays set while the
/// OTHER Shift is held, so releasing one Shift looked like a press.
nonisolated enum ModifierSides {
    /// Mac virtual key codes (Carbon's kVK_…) for the eight modifiers.
    static func sideMask(forVirtualKey vk: Int) -> UInt {
        switch vk {
        case 0x3B: return 0x0000_0001   // left Control
        case 0x38: return 0x0000_0002   // left Shift
        case 0x3C: return 0x0000_0004   // right Shift
        case 0x37: return 0x0000_0008   // left Command
        case 0x36: return 0x0000_0010   // right Command
        case 0x3A: return 0x0000_0020   // left Option
        case 0x3D: return 0x0000_0040   // right Option
        case 0x3E: return 0x0000_2000   // right Control
        default:   return 0
        }
    }

    /// Whether this modifier key is down after a flagsChanged event with
    /// these raw modifier flags; nil for keys that aren't modifiers.
    static func isDown(virtualKey vk: Int, flags: UInt) -> Bool? {
        let side = sideMask(forVirtualKey: vk)
        return side == 0 ? nil : (flags & side) != 0
    }
}
