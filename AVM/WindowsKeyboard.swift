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
    /// Not Now to Input Monitoring in this run (2026-10-29).
    private static var inputMonitoringNotNow = false

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
    private(set) var keyboardName = "The keyboard for Windows"
    private var announcedHeld = false

    private init() {}

    /// Which start a wait belongs to (2026-10-28): a stop and a new start
    /// during the approval wait left two waits for one keyboard. The ask
    /// at an unlock counts as one (seventh audit).
    private var startGeneration = 0

    func start(keyboardID: String, name: String?, target: VMManager? = nil, appleISO: Bool = false) {
        // Already in another machine (2026-10-28, fourth audit): ignored
        // without a word, so the user thought it typed in this one.
        guard self.keyboardID == nil else {
            if let target, self.target !== target {
                let holder = self.target?.machineName ?? "another machine"
                if self.keyboardID == keyboardID {
                    Announcer.shared.announce("\(keyboardName) is in \(holder) already, so it types there, not in \(target.machineName).", tone: .info)
                } else {
                    // A different keyboard (2026-10-28, fifth audit): AVM holds
                    // one keyboard for Windows at a time, and the refusal
                    // named the wrong one.
                    Announcer.shared.announce("\(name ?? "The keyboard") can't go to \(target.machineName) while \(keyboardName) is in \(holder): AVM holds one keyboard for Windows at a time.", tone: .info)
                }
            }
            return
        }
        self.keyboardID = keyboardID
        self.target = target
        self.appleISO = appleISO
        _ = lockObservers   // watching for the screen lock from now on
        // Locked already (2026-10-28, fifth audit): the notification came
        // before the observers existed, and the keyboard typed into the
        // signed-in guest for anyone at the locked Mac.
        screenLocked = FocusLockManager.screenIsLockedNow
        keyboardName = name ?? "The keyboard for Windows"
        announcedHeld = false
        startGeneration += 1
        // Not while the screen is locked (2026-10-29, seventh audit): a
        // start under a lock (a machine started at login, a hand-over from
        // a machine that stopped, the helper's restart) took the keyboard
        // for the whole lock, so it typed nowhere, and couldn't type the
        // password. Asked for at the unlock, like one given back for a lock.
        if screenLocked {
            releasedForScreenLock = true
            AVMLog.write("AVM: WindowsKeyboard — the screen is locked; the keyboard stays with the Mac, and the helper is asked at the unlock.")
            return
        }
        AVMLog.write("AVM: WindowsKeyboard — asking the helper for the keyboard for Windows.")
        askHelper(for: keyboardID, generation: startGeneration)
    }

    /// Asks the helper for the keyboard and acts on its answer: from
    /// start(), and at the unlock after a screen lock gave it back
    /// (2026-10-29, seventh audit: that ask dropped the answer, so a
    /// refusal left the keyboard typing on the Mac while AVM believed it
    /// was in Windows). `generation`: the start this ask belongs to; a
    /// stop or a newer start meanwhile makes the answer nobody's.
    private func askHelper(for keyboardID: String, generation: Int) {
        Task { @MainActor in
            // Input Monitoring first (2026-10-29): macOS lets the helper take
            // a keyboard only when AVM is allowed there, and refused it
            // without a word (InputMonitoring.swift). Not asked again in this
            // run after a Not Now, at every start and unlock; the helper's
            // refusal then says what to do.
            if !InputMonitoring.isAllowed, !Self.inputMonitoringNotNow {
                let outcome = await InputMonitoring.ask(
                    title: "AVM needs Input Monitoring for the keyboard for Windows",
                    why: "macOS lets AVM's helper take a keyboard only when AVM is allowed under Input Monitoring.",
                    then: "\(keyboardName) types only in Windows as soon as it's allowed.",
                    while: { self.keyboardID == keyboardID && self.startGeneration == generation })
                guard self.keyboardID == keyboardID, self.startGeneration == generation else { return }
                if outcome == .notNow {
                    Self.inputMonitoringNotNow = true
                    AVMLog.write("AVM: WindowsKeyboard — Input Monitoring not allowed (Not Now); the keyboard stays with the Mac.")
                    Announcer.shared.announce("\(keyboardName) types on the Mac for now. Once AVM is allowed under Input Monitoring, it goes to Windows the next time the machine starts.", tone: .info)
                    self.keyboardID = nil
                    return
                }
            }
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
            // Stopped while the helper was asked (2026-10-28, fifth audit):
            // the hold went ahead with nobody listening, and the keyboard
            // was seized by root, dead, until the next start.
            if case .success = result, self.keyboardID != keyboardID || self.startGeneration != generation {
                // Only when no newer start wants a keyboard (2026-10-29, sixth
                // audit): the helper's release takes no id, and it let go of
                // the newer start's hold, while AVM said the keyboard typed in
                // the machine. A newer start for another keyboard asks for
                // that one again, in case the helper took this one after it.
                if self.keyboardID == nil {
                    AVMLog.write("AVM: WindowsKeyboard — the machine stopped while the helper took the keyboard; giving it back.")
                    await USBHelperClient.shared.releaseKeyboard()
                } else if let newer = self.keyboardID, newer != keyboardID {
                    AVMLog.write("AVM: WindowsKeyboard — a newer start wants another keyboard; asking for it again.")
                    _ = await USBHelperClient.shared.holdKeyboard(newer)
                } else {
                    AVMLog.write("AVM: WindowsKeyboard — a newer start for the same keyboard; its hold stays.")
                }
                return
            }
            if case .failure(let error) = result {
                AVMLog.write("AVM: WindowsKeyboard — the helper couldn't hold it: \(error)")
                // Only if no newer start has replaced this one meanwhile, the
                // same keyboard's included (sixth audit: its failure ended the
                // newer start's wait for the helper's approval).
                guard self.keyboardID == keyboardID, self.startGeneration == generation else { return }
                // Not after the client's line about a helper that isn't
                // starting (2026-10-29), which says what to do.
                if case .notStarting = error {
                    self.keyboardID = nil
                    return
                }
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
        releasedForScreenLock = false
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
        // With its Apple ISO swap (2026-10-29, sixth audit): started again
        // without it, the key left of 1 and the one by left Shift traded
        // places in Windows for the rest of the run.
        let iso = appleISO
        // For the same machine (2026-10-28, code review): started again
        // with no target, keys went to the front machine, and any machine
        // stopping ended the keyboard.
        let machine = target
        Announcer.shared.announce("\(keyboardName) types on the Mac for a moment: AVM's helper restarted. Asking for it again.", tone: .info)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, VMManager.shared != nil, self.keyboardID == nil else { return }
                // A paused machine too (sixth audit): "Asking for it again"
                // was followed by nothing, and after Resume the keyboard
                // typed into the Mac's front app.
                if let machine, machine.state == .running || machine.state == .paused {} else if machine != nil { return }
                self.start(keyboardID: id, name: name, target: machine, appleISO: iso)
            }
        }
    }

    /// The Mac's screen is locked (2026-10-28, fourth audit): the keyboard
    /// for Windows went on typing into the guest, often signed in, for
    /// anyone at the locked Mac. Keys are dropped until it's unlocked, and
    /// any held when it locked are let go.
    private var screenLocked = false
    /// Given back for the screen lock, to be taken again at the unlock.
    private var releasedForScreenLock = false
    private lazy var lockObservers: [NSObjectProtocol] = {
        let center = DistributedNotificationCenter.default()
        return [
            center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screenLocked = true
                    if self.keyboardID != nil {
                        self.releaseAllKeys()
                        // Back on the Mac while it's locked (2026-10-29, sixth
                        // audit): when it was the only keyboard anyone could
                        // type on (the Mac's other one switched off, say), its
                        // keys were dropped and the password couldn't be typed.
                        // Taken again at the unlock.
                        self.releasedForScreenLock = true
                        AVMLog.write("AVM: WindowsKeyboard — the screen locked; the keyboard goes back to the Mac until it's unlocked.")
                        Task { await USBHelperClient.shared.releaseKeyboard() }
                    }
                }
            },
            center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.screenLocked = false
                    if self.releasedForScreenLock {
                        self.releasedForScreenLock = false
                        if let id = self.keyboardID {
                            AVMLog.write("AVM: WindowsKeyboard — the screen is unlocked; asking for the keyboard again.")
                            // The one ask (2026-10-29, seventh audit): this
                            // one dropped the helper's answer. Its own
                            // generation, so a wait left by the start (for
                            // the helper's approval, say) ends instead of
                            // asking too.
                            self.startGeneration += 1
                            self.askHelper(for: id, generation: self.startGeneration)
                        }
                    }
                }
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
            // Refused for want of Input Monitoring (2026-10-29): what to do,
            // not the code. Allowed already, the code is said.
            if let detail, InputMonitoring.refusedHelper(detail), !InputMonitoring.isAllowed {
                Announcer.shared.announce("\(keyboardName) can't be used for Windows: macOS lets AVM's helper take a keyboard only when AVM is allowed under Input Monitoring. \(InputMonitoring.steps) Then it goes to Windows the next time the machine starts. It still types on the Mac.", tone: .failure)
            } else {
                // Not "on the Mac" when it's in a machine already, through
                // Bluetooth Devices (2026-10-29, sixth audit).
                let whereNow = detail?.contains("in a virtual machine already") == true ? "" : " It still types on the Mac."
                Announcer.shared.announce("\(keyboardName) can't be used for Windows. Reason: \(detail ?? "unknown.")\(whereNow)", tone: .failure)
            }
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
