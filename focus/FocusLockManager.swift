// FocusLockManager.swift
import Foundation
import AppKit
import Combine
import Carbon.HIToolbox

/// Manages the full screen focus lock when Windows is running.
/// When locked, Command-Tab and other system shortcuts are disabled.
/// The escape hotkey is Control-Command-Escape.
///
/// ESCAPE-ONLY BY DESIGN (hardened 2026-07-22):
///   Control-Command-Escape always means "take me to the Mac" — it is a
///   one-way escape hatch, never a toggle. A toggle would throw a confused
///   user INTO Windows at the exact moment they are most lost (the H10
///   mode-confusion incidents); the same logic as Cancel-as-default on
///   destructive dialogs. The Carbon handler therefore calls unlock() only.
///   Entering Windows is always a deliberate, guarded act (Enter Windows /
///   Start Virtual Machine), never a side effect of the panic chord.
///   Note the hotkey is registered in lock() and unregistered in unlock(),
///   so AVM claims the chord ONLY while locked — on the dashboard the chord
///   is untouched and available to the rest of the system.
///
/// CAPS LOCK REMAP LIFECYCLE (added 2026-07-26 — Stage 2):
///   The lock owns one more piece of state: the Caps Lock → F19 hidutil
///   remap that lets guest screen readers use Caps Lock as their modifier.
///   See CapsLockRemapper.swift for the root cause and the full rationale.
///   Here, only the placement matters, and it is deliberate on both sides:
///     - lock() APPLIES the remap BEFORE announcing "Entering Windows".
///     - unlock() RESTORES it BEFORE announcing "Entering Mac".
///   Both orderings exist for the same reason: a .failure announcement
///   INTERRUPTS and FLUSHES the Announcer queue, so a remap failure that
///   spoke AFTER the mode-transition announcement would cut that
///   announcement off mid-word. Doing the work first means a failure speaks
///   cleanly and the transition enqueues behind it. Success is silent and
///   costs about 30 ms, so the ordinary path sounds exactly as it did before.
///   Mac-side Caps Lock is therefore normal whenever the keyboard is not in
///   Windows. Termination and crash recovery are NOT handled here — they
///   belong to the app delegate in AVMApp.swift, because this object has no
///   lifecycle hook that runs at quit (see the note on cleanup() below).
///
/// AUTHORITATIVE KEYBOARD ROUTING (added 2026-07-19):
///   The lock now defends keyboard focus, not just system shortcuts.
///   Diagnosis (focus trace, 2026-07-18): with VoiceOver's "synchronize
///   keyboard focus and VO cursor" enabled, VO-navigating to any focusable
///   AVM control while locked silently moved the window's first responder
///   from SPICEKeyCaptureView to SwiftUI's hosting view — a single discrete
///   theft, not a fight. From that moment keystrokes stopped reaching the
///   guest, and Return/Space would activate whatever AVM button held focus
///   (the mechanism behind the 2026-07-12 "crash": Return landed on Force
///   Stop and killed the VM mid-sentence).
///   Enforcement: while locked, a KVO observation on the window's
///   firstResponder reclaims focus for the registered capture view whenever
///   anything else takes it. Consequences, by design:
///     - The VO cursor roams and announces AVM's overlay freely; only
///       KEYBOARD focus is reclaimed. VO-Space still activates overlay
///       buttons via the accessibility press action, which bypasses the
///       responder chain — the deliberate escape routes survive.
///     - Plain Return/Space can no longer accidentally activate an AVM
///       button from inside the lock. That accident is now impossible.
///     - Control-Command-Escape always wins: the Carbon hotkey fires outside
///       the responder chain entirely, and unlock() tears the observer down
///       before anything else. The lock is authoritative, not a trap.
///   SCOPE LIMIT (deliberate): we reclaim first responder WITHIN our window
///   only. We never fight over which window is KEY — VoiceOver legitimately
///   takes key status for its own panels, and stealing it back would be
///   fighting the screen reader. If another window is key, our keys aren't
///   going to the guest and that is accepted; the lock re-enforces the
///   moment our window's responder changes again.
///
/// KEY-WINDOW AUDIBILITY (added 2026-07-22):
///   The scope limit above accepts key-window loss — but in the recommended
///   ritual VoiceOver is OFF while locked, so a foreign window taking key
///   (e.g. a system password dialog: the Developer Tools Access incident,
///   2026-07-22) silently swallows every keystroke with no cue. "My keyboard
///   is dead" is the natural misread. So: while locked, we WATCH key status
///   and ANNOUNCE loss — we still never reclaim key (announce, never fight).
///     - Debounced 1 second: transient flicker (VO waking, lock/unlock
///       window churn) stays silent; a real dialog sits there waiting and
///       always gets announced. All conditions are re-checked when the
///       timer fires, not when it is scheduled.
///     - Suppressed while VoiceOver is running: with VO on the user can
///       already perceive the thief, and VO's own panels legitimately take
///       key constantly. This cue exists precisely for the VO-off blind
///       spot. The regain announcement follows the same rule (note: in the
///       expected recovery flow VO is on at regain, so regain is usually
///       silent by design; the log always records it).
///     - Announcements: "Another window took the keyboard. Turn VoiceOver
///       on to check." / "Keyboard back in Windows." — distinct from the
///       lock-transition pair on purpose; each phrase means one thing.
///     - Enforcement start also checks key status once, so a thief already
///       in place at lock time enters the same debounced path.
///
/// AUDIBLE MODE TRANSITIONS (added 2026-07-19):
///   lock/unlock announce "Entering Windows" / "Entering Mac" (2026-10-26,
///   the same words for every guest, at the user's request) via
///   Announcer (.info — Tink, neutral by design). Reclaims themselves are
///   SILENT: with VO-cursor sync on, every arrow press triggers one, and
///   per-reclaim speech would make VO navigation unbearable.
///
/// STAGE C LOGGING DISPOSITION (2026-08-03) — two tiers, decided together:
///   1. PROMOTED to AVMLog (file log): transitions and lifecycle — lock/
///      unlock, capture-view registration, hotkey register/unregister,
///      enforcement start/stop, the initial seize, key watch start/stop,
///      the thief-at-start entry, and the four key-watch OUTCOME lines
///      (loss/regain, announced or suppressed). All fire at most once or
///      twice per lock cycle; they are AVMLog's charter category
///      ("focus-lock transitions") and the full story of a Developer-Tools-
///      Access-class incident. Promoting the outcome lines also moves the
///      header's promise "the log always records it" into the file testers
///      actually send.
///   2. NSLog PERMANENTLY: the RECLAIMED line (with VO-cursor sync, EVERY
///      arrow press triggers a reclaim — per-keystroke frequency would
///      chew the 5MB cap and bury the transitions; the same reasoning that
///      keeps reclaims audibly silent) and the three debounce intermediates
///      (resign/regain-within-debounce/conditions-cleared — VO's panels
///      take key constantly with VO on, so these are the mechanism's
///      heartbeat, not its verdicts). Verdict to file log, mechanism to
///      unified log — same split as CapsLockRemapper tier 3; every path
///      that matters ends in a tier-1 line.
@MainActor
class FocusLockManager: ObservableObject {
    // MARK: - Published State
    @Published var isLocked: Bool = false

    /// The guest's name for "Enter Windows" / "Enter Ubuntu" and the
    /// keyboard announcements. A published mirror of
    /// VMManager.currentGuestName (the one source), so the menu redraws:
    /// SessionGate sets it when a session appears, and lock() refreshes it
    /// before speaking. Windows until then.
    @Published var guestName: String = GuestOS.windows.displayName

    // MARK: - Out-of-tree access
    /// Same pattern as VMManager.shared: set at init so out-of-tree callers
    /// (the capture view registering itself from viewDidMoveToWindow) can
    /// reach the app's single instance without environment plumbing.
    static private(set) weak var shared: FocusLockManager?

    // MARK: - Private Properties
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// The view that must hold keyboard focus while locked (the SPICE
    /// display / key-capture view). Weak: the view's lifecycle belongs to
    /// SwiftUI; if it goes away the enforcement simply has nothing to defend.
    private weak var captureView: NSView?
    /// True when `view` is the screen that has (or last had) the keyboard.
    func isCaptureView(_ view: NSView?) -> Bool { view != nil && captureView === view }
    /// KVO observation of the capture view's window's firstResponder.
    /// Non-nil exactly while enforcement is active (locked with a registered
    /// view in a window).
    private var responderObservation: NSKeyValueObservation?

    // MARK: - Key-window watch state
    /// Notification observer tokens for the capture window's
    /// didResignKey/didBecomeKey. Non-empty exactly while enforcement is
    /// active (same lifecycle as responderObservation).
    private var keyWatchTokens: [NSObjectProtocol] = []
    /// Pending debounced loss announcement. Cancelled by regain or teardown.
    private var pendingLossTask: Task<Void, Never>?
    /// True after a loss announcement actually spoke, so regain knows
    /// whether there is anything to confirm. Reset on regain and teardown.
    private var keyLossAnnounced = false

    // MARK: - Hotkey Definition
    // Escape hotkey: Control-Command-Escape (one-way, unlock only)
    private let hotkeyID = EventHotKeyID(signature: OSType(0x4156_4D00), id: 1)
    private let hotkeyKeyCode: UInt32 = 53  // Escape key
    private let hotkeyModifiers: UInt32 = UInt32(controlKey) | UInt32(cmdKey)

    // MARK: - Init
    init() {
        FocusLockManager.shared = self
        // AVM STOPPED BEING THE ACTIVE APP (2026-10-25, code audit): the
        // Caps Lock remap applies to the whole Mac, so a lock left on while
        // another app is in front made Caps Lock F19 everywhere, VoiceOver
        // included when Caps Lock is its key. Process switching is blocked
        // while locked, but routes remain (VoiceOver's app chooser, a system
        // dialog). Leaving AVM now unlocks, which restores Caps Lock and
        // says "Mac keyboard on".
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                AVMLog.write("AVM: FocusLock — AVM is no longer the active app while locked; unlocking.")
                self.resignedWhileLocked = (Date(), self.guestName)
                self.unlock()
            }
        }
        // The screen locking, the Mac sleeping, or another user taking the
        // Mac also ends the lock (2026-10-28, fourth audit): AVM stays the
        // active app through them, so Caps Lock stayed F19 at the login
        // window and for the other user.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.isLocked else { return }
                    AVMLog.write("AVM: FocusLock — \(note.name.rawValue) while locked; unlocking.")
                    self.droppedBySystem = self.guestName
                    self.unlock(bringListForward: false)
                }
            })
        }
        systemObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isLocked else {
                    // Unlocked moments ago because AVM lost the front, as a
                    // screen saver does before the lock (sixth audit): the
                    // return is owed the same note as a sleep.
                    if let resigned = self.resignedWhileLocked, Date().timeIntervalSince(resigned.at) < 10 {
                        self.droppedBySystem = resigned.guest
                    }
                    return
                }
                AVMLog.write("AVM: FocusLock — the screen locked while locked; unlocking.")
                self.droppedBySystem = self.guestName
                self.unlock(bringListForward: false)
            }
        })
        // Said when the Mac is back (2026-10-28, fifth audit): "Entering
        // Mac" went out as the Mac went down, unheard, and on return the
        // user typed into the Mac with no word why.
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sayKeyboardIsBack() }
            })
        }
        systemObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sayKeyboardIsBack() }
        })
        _ = activeObserver
    }

    private var resignObserver: NSObjectProtocol?
    private var systemObservers: [NSObjectProtocol] = []
    /// The machine the lock was in when the Mac slept, locked its screen
    /// or switched users (fifth audit).
    private var droppedBySystem: String?
    private var toldHowToLeave = false
    /// When AVM last stopped being the active app while locked, and in
    /// which machine (sixth audit): a screen saver that starts first, then
    /// locks the screen, unlocked through that path.
    private var resignedWhileLocked: (at: Date, guest: String)?

    private func sayKeyboardIsBack() {
        guard let guest = droppedBySystem, !isLocked else { return }
        // At the lock screen still (a wake before the unlock): the unlock says it.
        if Self.screenIsLockedNow { return }
        droppedBySystem = nil
        // Only about a machine still running (2026-10-29, sixth audit): one
        // that shut itself down meanwhile was named, with a key that did
        // nothing.
        guard MachineSessions.shared.sessions.values.contains(where: {
            $0.configuration.name == guest && ($0.vmState == .running || $0.vmState == .paused)
        }) else {
            AVMLog.write("AVM: FocusLock — \(guest) isn't running any more; nothing to say about returning to it.")
            return
        }
        Announcer.shared.announce("Your keyboard is on the Mac. Press Command Shift E to return to \(guest).", tone: .info)
    }

    /// Whether the Mac's screen is locked now (2026-10-28, fifth audit):
    /// for code that starts after the lock's notification went out.
    static var screenIsLockedNow: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool { return locked }
        return (session["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
    }

    /// Back in AVM after copying something in another app: offer the
    /// Mac's clipboard to the guest (AVMPasteboard, 2026-10-25).
    private lazy var activeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated { AVMPasteboard.shared.macPasteboardMayHaveChanged() }
    }

    // MARK: - Capture view registration
    /// Called by SPICEKeyCaptureView from viewDidMoveToWindow — the moment
    /// the view and its window are both guaranteed valid. Safe to call
    /// repeatedly (window changes re-register). If we are already locked
    /// (auto-lock fired before the view landed in the window), start
    /// enforcement now.
    func registerCaptureView(_ view: NSView) {
        // While the keyboard is in one machine, another machine's screen
        // appearing doesn't take it (2026-10-27, code audit: several
        // machines). Entering that machine unlocks first, then registers.
        if isLocked, let existing = captureView, existing !== view,
           let window = existing.window, window.isVisible, window !== view.window {
            AVMLog.write("AVM: FocusLock — another machine's screen appeared while locked; keeping the keyboard where it is.")
            return
        }
        // The same view again (its window became key) keeps the "keyboard
        // lost" note (2026-10-28, fourth audit): restarting the watch reset
        // it, so "keyboard back in Windows" was never said after a window
        // took the keyboard and gave it back.
        let sameView = captureView === view
        captureView = view
        AVMLog.write("AVM: FocusLock — capture view registered (window=\(view.window != nil ? "present" : "nil")).")
        if isLocked, !sameView {
            startEnforcement()
        }
    }

    /// Not another machine's screen (2026-10-29, sixth audit): the machine
    /// being entered has none yet, and registers its own once it's made.
    func forgetCaptureView() {
        guard !isLocked else { return }
        captureView = nil
    }

    // MARK: - Lock (Enter Windows Full Screen)
    func lock() {
        AVMLog.write("AVM: FocusLock.lock() called — isLocked was \(isLocked)")
        guard !isLocked else {
            AVMLog.write("AVM: FocusLock.lock() — already locked, no-op.")
            return
        }
        // Not while another app is in front (2026-10-25, code audit): the
        // automatic lock when a VM reaches running could fire while the user
        // was in Mail, sending nothing to the guest while Caps Lock became
        // F19 across the Mac. Say where things stand instead.
        guard NSApp.isActive else {
            let guest = VMManager.currentGuestName
            AVMLog.write("AVM: FocusLock.lock() — AVM is not the active app; not locking.")
            Announcer.shared.announce("\(guest) is running. To use it, switch to AVM and press Command Shift E.", tone: .info)
            return
        }
        NSApp.presentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination
        ]
        registerHotKey()
        isLocked = true
        startEnforcement()
        // Caps Lock remap BEFORE the transition announcement — a .failure
        // from here interrupts and flushes the queue, so speaking it after
        // "Windows keyboard on" would clip that announcement mid-word. The
        // remapper is silent on success and handles its own failure speech.
        CapsLockRemapper.shared.applyForLock()
        guestName = VMManager.currentGuestName
        // A note owed from before is spent once the user is back in (sixth
        // audit): it came out at a later wake, about a stale machine.
        droppedBySystem = nil
        // Copied on the Mac before entering? Offer it to the guest now.
        AVMPasteboard.shared.macPasteboardMayHaveChanged()
        // The way out, the first time in a run (2026-10-29, sixth audit), as
        // macOS machines say it: with VoiceOver off, only the overlay's text
        // said it, and nothing read that.
        let wayOut = toldHowToLeave ? "" : ". Control-Command-Escape returns to your Mac."
        toldHowToLeave = true
        Announcer.shared.announce("Entering \(guestName)\(wayOut)", tone: .enterGuest)
        AVMLog.write("AVM: FocusLock.lock() — NOW LOCKED (isLocked=true).")
    }

    // MARK: - Unlock (Return to Mac)
    /// `bringListForward` false: the caller is putting another window in
    /// front (2026-10-28), so the list stays where it is.
    func unlock(bringListForward: Bool = true) {
        AVMLog.write("AVM: FocusLock.unlock() called — isLocked was \(isLocked)")
        guard isLocked else {
            AVMLog.write("AVM: FocusLock.unlock() — already unlocked, no-op.")
            return
        }
        // Enforcement DOWN FIRST: nothing may reclaim focus for the guest
        // after the user has asked to leave.
        stopEnforcement()
        NSApp.presentationOptions = []
        unregisterHotKey()
        isLocked = false
        // Caps Lock back to normal Mac behavior BEFORE the transition
        // announcement, for the same queue-flush reason as lock().
        CapsLockRemapper.shared.restoreForUnlock()
        Announcer.shared.announce("Entering Mac", tone: .leaveGuest)
        AVMLog.write("AVM: FocusLock.unlock() — NOW UNLOCKED (isLocked=false).")
        // From a machine's own window (2026-10-27), back to the list.
        if bringListForward { MachineSessions.shared.returnedToMac() }
    }

    // MARK: - First-responder enforcement
    private func startEnforcement() {
        guard let view = captureView, let window = view.window else {
            AVMLog.write("AVM: FocusLock — enforcement not started (no capture view/window yet; will start on registration).")
            return
        }
        // Seize focus immediately — the lock begins with the keyboard where
        // it belongs, regardless of what held it a moment ago.
        if window.firstResponder !== view {
            let ok = window.makeFirstResponder(view)
            AVMLog.write("AVM: FocusLock — initial seize makeFirstResponder -> \(ok).")
        }
        // Re-arm cleanly if already observing (window may have changed).
        responderObservation?.invalidate()
        responderObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            // KVO callback thread is the main thread for AppKit windows, but
            // hop explicitly: enforcement must never run re-entrantly inside
            // the responder-change machinery, and MainActor isolation is
            // required for our state.
            Task { @MainActor [weak self] in
                self?.enforceResponder()
            }
        }
        AVMLog.write("AVM: FocusLock — enforcement STARTED (observing window firstResponder).")
        startKeyWatch(window: window)
    }

    private func stopEnforcement() {
        responderObservation?.invalidate()
        responderObservation = nil
        stopKeyWatch()
        AVMLog.write("AVM: FocusLock — enforcement STOPPED.")
    }

    private func enforceResponder() {
        // Re-check everything: the unlock path tears the observer down first,
        // but a queued enforcement may still land after unlock. isLocked is
        // the authority.
        guard isLocked, let view = captureView, let window = view.window else { return }
        let current = window.firstResponder
        if current !== view {
            let ok = window.makeFirstResponder(view)
            // STAGE C tier 2: NSLog permanently — with VO-cursor sync on,
            // every arrow press triggers a reclaim; per-keystroke frequency
            // belongs in the unified log, not the capped file log.
            NSLog("AVM: FocusLock — RECLAIMED first responder from \(current.map { String(describing: type(of: $0)) } ?? "nil") -> \(ok).")
        }
    }

    // MARK: - Key-window watch (announce, never reclaim)
    private var voiceOverIsRunning: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    private func startKeyWatch(window: NSWindow) {
        // Re-arm cleanly if already watching (window may have changed).
        stopKeyWatch()
        let center = NotificationCenter.default
        keyWatchTokens.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleKeyResign()
            }
        })
        keyWatchTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleKeyRegain()
            }
        })
        AVMLog.write("AVM: FocusLock — key watch STARTED.")
        // A thief may already hold key at enforcement start; same debounced
        // path as a live resign.
        if !window.isKeyWindow {
            AVMLog.write("AVM: FocusLock — key watch: window NOT key at start; scheduling debounced check.")
            scheduleLossAnnouncement()
        }
    }

    private func stopKeyWatch() {
        pendingLossTask?.cancel()
        pendingLossTask = nil
        keyLossAnnounced = false
        if !keyWatchTokens.isEmpty {
            let center = NotificationCenter.default
            for token in keyWatchTokens {
                center.removeObserver(token)
            }
            keyWatchTokens = []
            AVMLog.write("AVM: FocusLock — key watch STOPPED.")
        }
    }

    private func handleKeyResign() {
        guard isLocked else { return }
        // STAGE C tier 2: NSLog permanently — with VoiceOver on, VO's
        // panels take key constantly; this is the mechanism's heartbeat.
        // The verdict lines (loss/regain outcomes) go to the file log.
        NSLog("AVM: FocusLock — key watch: window RESIGNED key; debounce started.")
        scheduleLossAnnouncement()
    }

    private func handleKeyRegain() {
        pendingLossTask?.cancel()
        pendingLossTask = nil
        guard isLocked else { return }
        if keyLossAnnounced {
            keyLossAnnounced = false
            if voiceOverIsRunning {
                AVMLog.write("AVM: FocusLock — key watch: window REGAINED key; announcement suppressed (VoiceOver running).")
            } else {
                Announcer.shared.announce("Entering \(guestName)", tone: .enterGuest)
                AVMLog.write("AVM: FocusLock — key watch: window REGAINED key; ANNOUNCED return.")
            }
        } else {
            // STAGE C tier 2: NSLog — regain inside the debounce window is
            // routine churn (VO panels), not a verdict.
            NSLog("AVM: FocusLock — key watch: window regained key within debounce; silent.")
        }
    }

    private func scheduleLossAnnouncement() {
        pendingLossTask?.cancel()
        pendingLossTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pendingLossTask = nil
            // Re-check EVERYTHING at fire time: still locked, window still
            // not key, VoiceOver still off.
            guard self.isLocked,
                  let window = self.captureView?.window,
                  !window.isKeyWindow else {
                // STAGE C tier 2: NSLog — a debounce that dissolves is
                // routine churn, not a verdict.
                NSLog("AVM: FocusLock — key watch: debounce fired but conditions cleared; silent.")
                return
            }
            if self.voiceOverIsRunning {
                AVMLog.write("AVM: FocusLock — key watch: key LOST >1s; announcement suppressed (VoiceOver running).")
                return
            }
            self.keyLossAnnounced = true
            Announcer.shared.announce("Another window took the keyboard. Turn VoiceOver on to check.", tone: .info)
            AVMLog.write("AVM: FocusLock — key watch: key LOST >1s; ANNOUNCED loss.")
        }
    }

    // MARK: - Hotkey Registration
    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<FocusLockManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                // Its own hotkey only (2026-10-28, code review): a macOS
                // machine's chord registers beside it.
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == manager.hotkeyID.signature, id.id == manager.hotkeyID.id else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async {
                    // Escape-only by design: the chord always means "take me
                    // to the Mac." See the header. Never lock from here.
                    manager.unlock()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        let registered = RegisterEventHotKey(
            hotkeyKeyCode,
            hotkeyModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        // Checked, not assumed (2026-10-26, keyboard audit): the line used
        // to say "registered" before the call and ignore its result. If the
        // chord is taken, the in-window Control-Command-Escape (the capture
        // view's own check) is the way back, and the user hears so.
        if installed == noErr && registered == noErr {
            AVMLog.write("AVM: FocusLock — Carbon hotkey registered (Control-Command-Escape).")
        } else {
            AVMLog.write("AVM: FocusLock — Carbon hotkey NOT registered (handler \(installed), hotkey \(registered)).")
            Announcer.shared.announce("AVM couldn't reserve Control-Command-Escape; it still returns to your Mac while the machine's window is in front.", tone: .failure)
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        AVMLog.write("AVM: FocusLock — Carbon hotkey unregistered.")
    }

    // MARK: - Cleanup
    /// NOTE (2026-07-26): this method currently has NO CALLERS anywhere in the
    /// project — verified by grep. AVM has no
    /// NSApplicationDelegate and no applicationWillTerminate hook, so nothing
    /// runs at quit. It is left in place because it is correct and cheap, but
    /// it must NOT be treated as a safety net: the Caps Lock remap deliberately
    /// does NOT restore from here, because a restore that never runs is worse
    /// than no restore at all — it reads as covered when it isn't. Termination
    /// restore belongs to the app delegate in AVMApp.swift.
    func cleanup() {
        stopEnforcement()
        unregisterHotKey()
        NSApp.presentationOptions = []
    }
}
