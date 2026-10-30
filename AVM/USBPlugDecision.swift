//
//  USBPlugDecision.swift
//  AVM
//
//  What AVM does with a USB device: one plugged in while Windows runs
//  (decide), and one already plugged in when Windows starts
//  (decideAtStart). Pure functions, so the rules live in one place.
//  USBHotPlugWatcher acts on the answers.
//
//  Plug-in decision order of record (agreed with Allison 2026-09-27).
//  The first rule that applies wins:
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
//  Start rule (agreed with Allison 2026-10-18): run the plug-in rule,
//  then keep its send and keep answers. An ask becomes a quiet keep on
//  the Mac, except one case: a device remembered for Windows that is
//  now always-ask, such as the Mac's current sound output. That one
//  gets the normal alert. So at start:
//  - Remembered for Windows goes over. Remembered keep on the Mac stays.
//  - In Always mode, ordinary devices go over. Making sure nothing is
//    in use on the Mac is the user's job, as at plug-in.
//  - Everything else stays on the Mac with no question. Asking about
//    every plugged-in device at each start would get tiresome.
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
        if protection == .keepOnMac {
            return (.keepOnMac, "rule 0: a USB hub stays on the Mac")
        }
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

    /// The same inputs as decide, for a device already plugged in when
    /// Windows starts. See the start rule in the header.
    static func decideAtStart(mode: USBPlugMode,
                              remembered: Bool?,
                              protection: USBDeviceClassification.Protection) -> (decision: USBPlugDecision, why: String) {
        let plugIn = decide(mode: mode, remembered: remembered, protection: protection)
        guard case .ask = plugIn.decision else {
            return (plugIn.decision, "at start, \(plugIn.why)")
        }
        if protection == .alwaysAsk, remembered == true {
            return (.ask(rememberOffered: false), "at start: remembered use in Windows, but now always asks")
        }
        return (.keepOnMac, "at start: would ask at plug-in, stays on the Mac quietly (\(plugIn.why))")
    }
}
