//
//  USBPlugDecision.swift
//  AVM
//
//  USB increment 2b, piece 4 step 2: what AVM does with a USB device
//  plugged in while a VM runs. One pure function, so the rule lives in
//  one place. Step 2 only logs the answer; later steps act on it.
//
//  Decision order of record (agreed with Allison 2026-09-27). The first
//  rule that applies wins:
//  1. Always-ask devices (keyboard, mouse, the Mac's current audio
//     output, HID not readable yet): ask, with no Remember option.
//     Exception: a remembered "keep on the Mac" is honored. It can only
//     come from before the device became protected, and keeping is
//     always the safe direction.
//  2. A remembered choice for this device: do what was remembered.
//     This includes braille displays, which are only ever remembered
//     when the user checked Remember. Device-specific beats the mode.
//  3. Mode "keep on the Mac": keep it, protected or not.
//  4. A braille display with nothing remembered: ask, Remember offered.
//     "Always use in Windows" never applies to it.
//  5. Mode "always": send it to Windows.
//  6. Mode "ask": ask, Remember offered.
//

import Foundation

enum USBPlugDecision: Equatable {
    case ask(rememberOffered: Bool)
    case sendToWindows
    case keepOnMac

    var logText: String {
        switch self {
        case .ask(let offered): return offered ? "ask (remember offered)" : "ask (no remember option)"
        case .sendToWindows: return "send to Windows"
        case .keepOnMac: return "keep on the Mac"
        }
    }
}

enum USBPlugDecider {

    /// remembered: true for "use in Windows", false for "keep on the
    /// Mac", nil when nothing is remembered or the word isn't understood.
    static func decide(mode: USBPlugMode,
                       remembered: Bool?,
                       protection: USBDeviceClassification.Protection) -> (decision: USBPlugDecision, why: String) {
        if protection == .alwaysAsk {
            if remembered == false {
                return (.keepOnMac, "rule 1: protected, but remembered keep on the Mac")
            }
            return (.ask(rememberOffered: false), "rule 1: protected, always asks")
        }
        if let remembered {
            return remembered
                ? (.sendToWindows, "rule 2: remembered use in Windows")
                : (.keepOnMac, "rule 2: remembered keep on the Mac")
        }
        if mode == .keepOnMac {
            return (.keepOnMac, "rule 3: mode keep on the Mac")
        }
        if protection == .brailleDisplay {
            return (.ask(rememberOffered: true), "rule 4: braille display, asks unless remembered")
        }
        if mode == .always {
            return (.sendToWindows, "rule 5: mode always")
        }
        return (.ask(rememberOffered: true), "rule 6: mode ask")
    }
}
