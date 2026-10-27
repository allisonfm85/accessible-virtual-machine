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
// keyboard sends (HIDKeyMap.swift) and sends it to QEMU's own input
// through its control connection (QMP input-send-event), in order.
// Keys still down are released when the keyboard goes back to the Mac,
// so none sticks in Windows.
//
// THROUGH QMP, NOT SPICE (2026-10-26, code audit): the machine's window,
// and with it SPICE, goes away whenever the user returns to the Mac, and
// stopping with it broke "whichever app is in front". QMP is connected
// for as long as the machine runs.
//
// Starts when the machine's keyboard channel first opens and it has a
// keyboard chosen in Settings (VMConfiguration.windowsKeyboardID); stops
// when the machine stops (VMManager). No key is ever logged or spoken.

import Foundation

@MainActor
final class WindowsKeyboard {
    static let shared = WindowsKeyboard()

    /// Sends a scancode to the running guest, through QMP.
    var send: ((Int32, Bool) -> Void)? = { code, down in
        WindowsKeyboard.shared.sendThroughQMP(["type": "number", "data": HIDKeyMap.qemuNumber(forScancode: Int(code))], down: down)
    }
    /// Sends Pause, which has no single scancode (HIDKeyMap.pauseUsage);
    /// QMP's qcode sends it down and up (CocoaSpice's never sent it up).
    var sendPause: ((Bool) -> Void)? = { down in
        WindowsKeyboard.shared.sendThroughQMP(["type": "qcode", "data": "pause"], down: down)
    }

    /// One after another: each key waits for the one before, so a release
    /// can never overtake its press.
    private var lastSend: Task<Void, Never>?
    private func sendThroughQMP(_ key: [String: Any], down: Bool) {
        let previous = lastSend
        nonisolated(unsafe) let event: [String: Any] = ["type": "key", "data": ["down": down, "key": key]]
        lastSend = Task { @MainActor in
            await previous?.value
            _ = try? await VMManager.shared?.sendQMPCommand("input-send-event", arguments: ["events": [event]])
        }
    }
    /// An Apple ISO keyboard: § and ` swapped back (HIDKeyMap.isoSwapped).
    var appleISO: Bool {
        get { translator.appleISO }
        set { translator.appleISO = newValue }
    }
    private var translator = WindowsKeyTranslator()

    private(set) var keyboardID: String?
    private var keyboardName = "The keyboard for Windows"
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
                // Only if no newer start has replaced this one meanwhile.
                guard self.keyboardID == keyboardID else { return }
                Announcer.shared.announce("\(keyboardName) can't be used for Windows. Reason: \(Self.reason(error)) It still types on the Mac.", tone: .failure)
                self.keyboardID = nil
            }
        }
    }

    func stop() {
        guard keyboardID != nil else { return }
        releaseAllKeys()
        keyboardID = nil
        retriedAfterHelperLoss = false
        AVMLog.write("AVM: WindowsKeyboard — giving the keyboard back to the Mac.")
        Task { await USBHelperClient.shared.releaseKeyboard() }
    }

    /// AVM's helper stopped while holding the keyboard: keys still down are
    /// let go in Windows, and AVM asks for the keyboard once more.
    private var retriedAfterHelperLoss = false
    func helperLost() {
        guard let id = keyboardID else { return }
        releaseAllKeys()
        keyboardID = nil
        AVMLog.write("AVM: WindowsKeyboard — the helper stopped while holding the keyboard.")
        guard !retriedAfterHelperLoss else {
            Announcer.shared.announce("\(keyboardName) types on the Mac again: AVM's helper stopped. Restart the machine to try again.", tone: .failure)
            return
        }
        retriedAfterHelperLoss = true
        let name = keyboardName
        Announcer.shared.announce("\(keyboardName) types on the Mac for a moment: AVM's helper restarted. Asking for it again.", tone: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, VMManager.shared != nil, self.keyboardID == nil else { return }
                self.start(keyboardID: id, name: name)
            }
        }
    }

    func key(usage: Int, pressed down: Bool) {
        guard keyboardID != nil, let send else { return }
        switch translator.translate(usage: usage, pressed: down) {
        case .key(let scancode, let isDown): send(scancode, isDown)
        case .pause(let isDown): sendPause?(isDown)
        case nil: break
        }
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
        let codes = translator.releaseAll()
        guard let send else { return }
        for code in codes { send(code, false) }
    }

    private static func reason(_ error: USBHelperError) -> String {
        switch error {
        case .helper(_, let detail) where !detail.isEmpty: return detail
        case .notEnabled: return "AVM's helper isn't allowed yet; allow it in System Settings, General, Login Items."
        default: return "AVM's helper didn't answer."
        }
    }
}
