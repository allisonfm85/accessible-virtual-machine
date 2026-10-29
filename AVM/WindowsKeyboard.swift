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
    /// Test jobs run machines with a made-up keyboard id: the helper isn't
    /// asked (2026-10-28).
    static var disabledForTests = false

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
        // The machine is chosen now (2026-10-28, code review): stop() let
        // go of held keys and then cleared the target, so the releases
        // went to whichever machine was current.
        let machine = target ?? VMManager.shared
        lastSend = Task { @MainActor in
            await previous?.value
            _ = try? await machine?.sendQMPCommand("input-send-event", arguments: ["events": [event]])
        }
    }
    /// An Apple ISO keyboard: § and ` swapped back (HIDKeyMap.isoSwapped).
    var appleISO: Bool {
        get { translator.appleISO }
        set { translator.appleISO = newValue }
    }
    private var translator = WindowsKeyTranslator()

    private(set) var keyboardID: String?
    /// The machine it types into (2026-10-27, several machines at once):
    /// the one whose screen started it.
    private(set) weak var target: VMManager?
    private var keyboardName = "The keyboard for Windows"
    private var announcedHeld = false

    private init() {}

    /// Which start a wait belongs to (2026-10-28): a stop and a new start
    /// during the approval wait left two waits for one keyboard.
    private var startGeneration = 0

    func start(keyboardID: String, name: String?, target: VMManager? = nil, appleISO: Bool = false) {
        // Already in another machine (2026-10-28, fourth audit): ignored
        // without a word, so the user thought it typed in this one.
        guard self.keyboardID == nil else {
            if let target, self.target !== target {
                Announcer.shared.announce("\(keyboardName) is in \(self.target?.machineName ?? "another machine") already, so it types there, not in \(target.machineName).", tone: .info)
            }
            return
        }
        self.keyboardID = keyboardID
        self.target = target
        self.appleISO = appleISO
        _ = lockObservers   // watching for the screen lock from now on
        keyboardName = name ?? "The keyboard for Windows"
        announcedHeld = false
        startGeneration += 1
        let generation = startGeneration
        AVMLog.write("AVM: WindowsKeyboard — asking the helper for the keyboard for Windows.")
        Task { @MainActor in
            var result = await USBHelperClient.shared.holdKeyboard(keyboardID)
            // The helper is waiting for its approval in Login Items
            // (2026-10-28, code review): "USB helper approved, continuing"
            // used to continue nothing for this keyboard. Wait, then ask
            // again.
            if case .failure(.notEnabled(.requiresApproval)) = result {
                AVMLog.write("AVM: WindowsKeyboard — waiting for the helper's approval.")
                Announcer.shared.announce("\(keyboardName) goes to Windows once AVM's helper is allowed in Login Items.", tone: .info)
                if await USBHelperClient.shared.waitForApproval(while: { self.keyboardID == keyboardID && self.startGeneration == generation }) {
                    guard self.keyboardID == keyboardID, self.startGeneration == generation else { return }
                    result = await USBHelperClient.shared.holdKeyboard(keyboardID)
                }
            }
            if case .failure(let error) = result {
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
        target = nil
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
        // For the same machine (2026-10-28, code review): started again
        // with no target, keys went to the front machine, and any machine
        // stopping ended the keyboard.
        let machine = target
        Announcer.shared.announce("\(keyboardName) types on the Mac for a moment: AVM's helper restarted. Asking for it again.", tone: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, VMManager.shared != nil, self.keyboardID == nil else { return }
                if let machine, case .running = machine.state {} else if machine != nil { return }
                self.start(keyboardID: id, name: name, target: machine)
            }
        }
    }

    /// The Mac's screen is locked (2026-10-28, fourth audit): the keyboard
    /// for Windows went on typing into the guest, often signed in, for
    /// anyone at the locked Mac. Keys are dropped until it's unlocked, and
    /// any held when it locked are let go.
    private var screenLocked = false
    private lazy var lockObservers: [NSObjectProtocol] = {
        let center = DistributedNotificationCenter.default()
        return [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screenLocked = true
                    if self.keyboardID != nil { self.releaseAllKeys() }
                }
            },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = false }
            },
        ]
    }()

    func key(usage: Int, pressed down: Bool) {
        _ = lockObservers
        guard keyboardID != nil, let send, !screenLocked else { return }
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
            // Held again, so a later helper loss gets its retry too
            // (2026-10-28, code review: the second restart in one session
            // stranded the keyboard).
            retriedAfterHelperLoss = false
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
        } else if detail == "away" {
            releaseAllKeys()
            AVMLog.write("AVM: WindowsKeyboard — its user left the screen; the helper takes it again when they're back.")
            Announcer.shared.announce("\(keyboardName) types on the Mac while another user is at the screen. It types in Windows again when you're back.", tone: .info)
        } else if detail == "waiting" {
            // The Mac has no other keyboard right now (2026-10-28): the
            // helper keeps looking, and takes it once the Mac has one.
            releaseAllKeys()
            AVMLog.write("AVM: WindowsKeyboard — waiting: the Mac has no other keyboard yet.")
            Announcer.shared.announce("\(keyboardName) types on the Mac for now: the Mac needs a keyboard of its own first. As soon as your Mac has another keyboard connected, \(keyboardName) types only in Windows.", tone: .info)
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

    /// Lets go of every key held on this keyboard in `machine`, and waits
    /// until QEMU has them, before the machine pauses or is saved
    /// (2026-10-28, fourth audit): a key let go while it was paused was
    /// refused by QEMU, and Windows kept it down and repeated it after the
    /// resume, Backspace deleting and Shift capitalising.
    func releaseHeldKeys(before machine: VMManager) async {
        guard target === machine else { return }
        releaseAllKeys()
        await lastSend?.value
    }

    private static func reason(_ error: USBHelperError) -> String {
        switch error {
        case .helper(_, let detail) where !detail.isEmpty: return detail
        case .notEnabled: return "AVM's helper isn't allowed yet; allow it in System Settings, General, Login Items."
        default: return "AVM's helper didn't answer."
        }
    }
}
