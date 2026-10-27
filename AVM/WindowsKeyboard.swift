// WindowsKeyboard.swift
// AVM — Accessible Virtual Machine
//
// A keyboard for Windows (2026-10-26): a second keyboard, USB or
// Bluetooth, that types only into Windows, so there is no switching the
// one keyboard between the Mac and Windows. The Mac's own keyboard stays
// with the Mac and VoiceOver; the chosen one belongs to Windows whenever
// the machine is running, whichever app is in front.
//
// The privileged helper holds the keyboard (macOS lets only a privileged
// process take a keyboard over; AVMUSBHelper/KeyboardHold.swift) and
// passes each key here as a HID usage. AVM turns it into the scancode a PC
// keyboard sends (HIDKeyMap.swift) and sends it to Windows through SPICE,
// the same way as the Mac keyboard's keys when Windows has the keyboard.
// Keys still down are released when the keyboard goes back to the Mac,
// so none sticks in Windows.
//
// Starts when SPICE connects and the machine has a keyboard chosen in
// Settings (VMConfiguration.windowsKeyboardID); stops when SPICE goes.
// No key is ever logged or spoken.

import Foundation

@MainActor
final class WindowsKeyboard {
    static let shared = WindowsKeyboard()

    /// Sends a scancode to the running guest; set by VMView's SPICE
    /// coordinator while connected.
    var send: ((Int32, Bool) -> Void)?

    private(set) var keyboardID: String?
    private var keyboardName = "The keyboard for Windows"
    private var pressed = Set<Int32>()
    private var announcedHeld = false

    private init() {}

    func start(keyboardID: String, name: String?) {
        guard self.keyboardID == nil else { return }
        self.keyboardID = keyboardID
        keyboardName = name ?? "The keyboard for Windows"
        announcedHeld = false
        AVMLog.write("AVM: WindowsKeyboard — asking the helper for the keyboard for Windows.")
        Task { @MainActor in
            if case .failure(let error) = await USBHelperClient.shared.holdKeyboard(keyboardID) {
                AVMLog.write("AVM: WindowsKeyboard — the helper couldn't hold it: \(error)")
                Announcer.shared.announce("\(keyboardName) can't be used for Windows. Reason: \(Self.reason(error)) It still types on the Mac.", tone: .failure)
                self.keyboardID = nil
            }
        }
    }

    func stop() {
        guard keyboardID != nil else { return }
        releaseAllKeys()
        keyboardID = nil
        AVMLog.write("AVM: WindowsKeyboard — giving the keyboard back to the Mac.")
        Task { await USBHelperClient.shared.releaseKeyboard() }
    }

    func key(usage: Int, pressed down: Bool) {
        guard keyboardID != nil, let code = HIDKeyMap.scancode(forUsage: usage), let send else { return }
        let scancode = Int32(code)
        if down { pressed.insert(scancode) } else { pressed.remove(scancode) }
        send(scancode, down)
    }

    func stateChanged(_ id: String, held: Bool, detail: String?) {
        guard id == keyboardID else { return }
        if held {
            AVMLog.write("AVM: WindowsKeyboard — held.")
            if !announcedHeld {
                announcedHeld = true
                Announcer.shared.announce("\(keyboardName) now types only in Windows.", tone: .info)
            } else {
                Announcer.shared.announce("\(keyboardName) is back, typing in Windows.", tone: .info)
            }
        } else if detail == "disconnected" {
            releaseAllKeys()
            AVMLog.write("AVM: WindowsKeyboard — disconnected; the helper will take it again when it's back.")
            Announcer.shared.announce("\(keyboardName) disconnected. It types in Windows again as soon as it reconnects.", tone: .info)
        } else {
            releaseAllKeys()
            keyboardID = nil
            AVMLog.write("AVM: WindowsKeyboard — not held: \(detail ?? "no reason")")
            Announcer.shared.announce("\(keyboardName) can't be used for Windows. Reason: \(detail ?? "unknown.") It still types on the Mac.", tone: .failure)
            Task { await USBHelperClient.shared.releaseKeyboard() }
        }
    }

    private func releaseAllKeys() {
        guard let send else { pressed.removeAll(); return }
        for code in pressed { send(code, false) }
        pressed.removeAll()
    }

    private static func reason(_ error: USBHelperError) -> String {
        switch error {
        case .helper(_, let detail) where !detail.isEmpty: return detail
        case .notEnabled: return "AVM's helper isn't allowed yet; allow it in System Settings, General, Login Items."
        default: return "AVM's helper didn't answer."
        }
    }
}
