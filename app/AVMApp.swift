// AVMApp.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import AppKit

@main
struct AVMApp: App {

    // All app-wide observable objects are created here, at the root, and injected
    // into the view tree so every descendant can find them via @EnvironmentObject.
    // ContentView (and its children) read vmStore and focusLock, so BOTH must be
    // injected here — otherwise reading a missing one traps with
    // "No ObservableObject of type ... found".
    //
    // KeyboardInterceptor was REMOVED 2026-07-26. It was a system-wide
    // .cghidEventTap that was never started: start(vmView:) had no callers
    // anywhere in the tree, so tapCreate was never called, isActive was
    // permanently false, and Input Monitoring was never requested. Its header
    // claimed it intercepted Caps Lock "before macOS processes them" — not
    // achievable at any layer, since macOS resolves Caps Lock in the HID
    // driver before an event exists (this is the H17 root cause). Had the tap
    // ever run, its handleEvent stripped .maskAlphaShift at head-insert, which
    // would have made VMView's `flags.contains(.capsLock)` permanently false
    // and killed the legacy synthesis outright. Removing it drops an Input
    // Monitoring prompt and a system-wide keystroke tap from the bundle ahead
    // of notarization. The real Caps Lock fix is the F19 hidutil remap.
    //
    // FocusDebugLogger was REMOVED 2026-08-03 (Stage C): the temporary
    // 10 Hz first-responder tracer from the 2026-07-18 focus-lock "fight"
    // investigation, which wrote unsanitized window titles and responder
    // descriptions to ~/Desktop/avm_focus_trace.txt. The investigation is
    // long closed; its own header ordered removal before tester release.
    // File deleted from the project AND from disk (Xcode's "Remove
    // Reference" leaves the source file in place — verified gone with ls).
    @StateObject private var vmStore = VMStore()
    @StateObject private var focusLock = FocusLockManager()

    /// Sparkle updater (ADDED 2026-08-16). Created at the app root like the
    /// other app-wide objects, but NOT injected into the view tree — no view
    /// reads it; its only consumer is the Check for Updates menu item below.
    /// Construction starts the updater (startingUpdater: true), which owns
    /// the launch-time check schedule and the one-time consent dialog. Full
    /// design of record in AVMUpdater.swift's header.
    @StateObject private var updater = AVMUpdater()

    /// AVM's FIRST app delegate (added 2026-07-26). See AVMAppDelegate below
    /// for why one became necessary.
    @NSApplicationDelegateAdaptor(AVMAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vmStore)
                .environmentObject(focusLock)
        }
        .windowStyle(.automatic)
        .commands {
            // Remove the default New Window menu item — AVM is single-window.
            CommandGroup(replacing: .newItem) { }

            // Check for Updates… (application menu, after About AVM) — ADDED
            // 2026-08-16. Placement is the macOS convention and therefore the
            // first place a VoiceOver user will look; this is an APP
            // operation, so it does not belong in the Virtual Machine menu
            // (machine operations). No keyboard chord: rare, deliberate
            // action — the same chord-budget rule as Save Diagnostic Log and
            // Reclaim Disk Space. Dimmed via Sparkle's own canCheckForUpdates
            // while a check or install is in flight (reactive dimming is fine
            // HERE, unlike the parked VM-state dimming — Sparkle provides the
            // observable). The action logs the invocation; every outcome,
            // including "you're up to date", is carried by Sparkle's standard
            // AppKit UI — native VoiceOver territory, nothing to self-voice.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            // Save Diagnostic Log… (File menu) — STAGE D (2026-08-06). The
            // whole flow (gate, save panel, copy, announcements, log lines)
            // lives in DiagnosticLogExporter; this button only invokes it.
            // NO menu-action log line here, deliberately — the exporter
            // records every path itself: confirm writes the "saving" verdict
            // to the file log, nothing-to-save goes to NSLog (the documented
            // exception — writing "log is empty" into the log would unempty
            // it), and cancel is silent by design. A line here would
            // duplicate or contradict those records.
            // No keyboard chord: this is a rare, deliberate action used when
            // preparing a report, and the chord budget is spent on things
            // done during normal operation. The File menu is where save
            // actions live and where a VoiceOver user will look first.
            CommandGroup(after: .saveItem) {
                Button("Save Diagnostic Log…") {
                    Task { @MainActor in
                        await DiagnosticLogExporter.saveDiagnosticLog()
                    }
                }
            }

            // Virtual Machine menu — machine-level actions and the "send
            // system key" family. Members:
            //
            // 1. Start Virtual Machine (Cmd-Shift-S) — ADDED 2026-07-19,
            //    part of the VO-OFF entry ritual (see item 2). Posts
            //    .avmStartVMFromMenu; ContentView owns the actual start path
            //    (VMSession creation lands in its activeSession @State, which
            //    only that view can write). HONEST SCOPE: ContentView starts
            //    the VM only when exactly ONE is configured and nothing is
            //    running; zero or multiple configurations beep with an
            //    explanatory status message rather than guessing which
            //    machine the user meant (a selection model for multiple VMs
            //    belongs to the dashboard redesign). Cmd-Shift-S deliberately
            //    avoids plain Cmd-S, which the dashboard's Setup Wizard
            //    button already owns.
            //
            // 2. Enter Windows (Cmd-Shift-E) — engages focus lock, same
            //    action as the dashboard's Enter Windows button, and the
            //    SINGLE documented chord for it (the button's old plain
            //    Cmd-E shortcut was removed 2026-07-19 — one chord, one
            //    action). ADDED 2026-07-19 to enable the VO-OFF entry
            //    ritual: the forwarding log proved that pressing Cmd-F5
            //    (VoiceOver toggle) WHILE LOCKED leaks a clean bare Command
            //    tap to the guest — macOS eats the F5 at the system level,
            //    but the Command flagsChanged still forwards, so Windows
            //    sees a bare Win tap and OPENS THE START MENU (three
            //    convicted down/up pairs in the 2026-07-19 log, right where
            //    the ritual said "now sleep VoiceOver"). With these
            //    shortcuts the ritual inverts and the leak never fires: on
            //    the dashboard, Cmd-F5 sleeps VoiceOver FIRST (nothing
            //    forwards — not locked), then Cmd-Shift-S starts the machine
            //    (or Cmd-Shift-E enters a running one), and the lock
            //    announcement "Windows keyboard on" is spoken by Announcer's
            //    system voice — audible without VO. Exit mirrors it:
            //    Control-Command-Escape → "Mac keyboard on" → Cmd-F5 wakes
            //    VO (forwards nothing — already unlocked). Deliberate
            //    Win-key taps for the Start menu keep working inside
            //    Windows, exactly as every Windows user expects.
            //    DOCS NOTE: toggling VoiceOver with Cmd-F5 while the
            //    keyboard is IN Windows may open the Start menu (Windows
            //    sees the Command key as a Windows-key tap); press Escape to
            //    close it.
            //    If no VM is running or paused, this beeps and does nothing.
            //
            // 3. Send Ctrl-Alt-Delete (Cmd-Shift-D) — the Windows secure
            //    attention sequence (lock screen, sign-out, Task Manager). On
            //    a Mac keyboard that chord is Control+Option+Forward Delete,
            //    and Control+Option is the VoiceOver modifier — VO consumes it
            //    even with the pass-through command (verified by test
            //    2026-07-11). Sent via QMP send-key at the virtual-hardware
            //    level, bypassing host keyboard forwarding.
            //
            // 4. Reset Virtual Machine… (Cmd-Shift-R) — the virtual reset
            //    button via QMP system_reset. Recovery experiment for the
            //    stochastic firmware reboot wedge (upstream QEMU/edk2 — UTM
            //    issue #7648; the install watchdog's spoken guidance offers
            //    this first, stop+restart as the proven fallback) and the
            //    general escape hatch for any hard-hung guest. CONFIRMATION
            //    REQUIRED (added 2026-07-12 after a reset during OOBE dropped
            //    the guest into WinRE — a hard reset mid-setup/mid-update can
            //    corrupt Windows, exactly like a physical reset button, and
            //    for a non-visual user the resulting WinRE screen is a
            //    silently different world with no audio). Cancel is the
            //    DEFAULT button so Return backs out; resetting requires
            //    deliberately choosing Reset. With no VM running, the dialog
            //    is skipped and resetVM's own guard no-ops with a console
            //    message — no confirming a no-op.
            //
            // 5. Reclaim Disk Space… (no chord) — ADDED 2026-08-15. Cleans
            //    up orphaned VM directories left behind by the pre-fix
            //    delete (issue #5). Posts .avmReclaimFromMenu; ContentView
            //    owns the response (fresh scan at invocation — announces
            //    "nothing to reclaim" when the scan is empty, opens the
            //    Reclaim sheet otherwise; sheet presentation needs the view
            //    tree, and the scan needs vmStore). No keyboard chord: rare,
            //    deliberate maintenance — the same chord-budget rule as Save
            //    Diagnostic Log. Placed after its own Divider: maintenance,
            //    not machine operation. Full design of record in
            //    ReclaimView.swift's header.
            //
            // Items 3 and 4 reach the manager through VMManager.shared (the
            // existing weak static VMSession sets at init for out-of-tree
            // handlers — same route the QEMU stderr/termination handlers
            // use); Enter Windows uses the app-root focusLock directly;
            // Start posts a notification to ContentView. Commands are always
            // enabled. (Reactive menu dimming needs an app-level VM-state
            // observable — parked with the UI redesign; audible feedback
            // arrives with the announcements work.)
            //
            // The shortcuts only fire when AVM has key focus OUTSIDE focus
            // lock (inside lock, keys forward to the guest), which is exactly
            // the intended flow. For Cmd-Shift-E and Cmd-Shift-S in
            // particular this is correct by construction — inside Windows,
            // those chords should be the guest's Win+Shift+E / Win+Shift+S
            // (File Explorer / snipping), not AVM commands.
            //
            // STAGE C (2026-08-03): the menu-action log lines below were
            // promoted from NSLog to AVMLog.write — a chord that "did
            // nothing" is a classic field report, and the file log is what
            // Stage D's diagnostic bundle will carry. Privacy check: these
            // lines name AVM menu commands and VM state only, never guest
            // keystrokes, so the key-naming prohibition does not apply.
            CommandMenu("Virtual Machine") {
                Button("Start Virtual Machine") {
                    AVMLog.write("AVM: Start Virtual Machine menu — posting start request to ContentView.")
                    NotificationCenter.default.post(name: .avmStartVMFromMenu, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Enter Windows") {
                    // Same gate as the dashboard's Enter Windows button: only
                    // meaningful when a VM is running or paused. focusLock.lock()
                    // flips SessionGate to VMView and speaks "Windows keyboard
                    // on" (system voice — audible with VoiceOver asleep).
                    guard let manager = VMManager.shared else {
                        AVMLog.write("AVM: Enter Windows menu — no VMManager; beeping.")
                        NSSound.beep()
                        return
                    }
                    switch manager.state {
                    case .running, .paused:
                        AVMLog.write("AVM: Enter Windows menu — engaging focus lock.")
                        focusLock.lock()
                    default:
                        AVMLog.write("AVM: Enter Windows menu — VM not running/paused (state=\(manager.state)); beeping.")
                        NSSound.beep()
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Send Ctrl-Alt-Delete") {
                    Task { @MainActor in
                        await VMManager.shared?.sendCtrlAltDel()
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Reset Virtual Machine…") {
                    Task { @MainActor in
                        guard let manager = VMManager.shared, case .running = manager.state else {
                            // Not running: skip the dialog; resetVM's guard
                            // emits the "isn't running" console message.
                            await VMManager.shared?.resetVM()
                            return
                        }
                        let alert = NSAlert()
                        alert.messageText = "Reset the virtual machine?"
                        alert.informativeText = "This is like pressing the reset button on a physical PC. Windows restarts immediately and unsaved work inside the virtual machine is lost. If Windows is installing or updating, a reset can damage it."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Cancel")
                        alert.addButton(withTitle: "Reset")
                        if alert.runModal() == .alertSecondButtonReturn {
                            await manager.resetVM()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Reclaim Disk Space…") {
                    AVMLog.write("AVM: Reclaim Disk Space menu — posting reclaim request to ContentView.")
                    NotificationCenter.default.post(name: .avmReclaimFromMenu, object: nil)
                }
            }
        }
    }
}

// MARK: - App delegate

/// AVM's first app delegate, added 2026-07-26 for ONE reason: the Caps Lock
/// remap needs a lifecycle, and SwiftUI's App protocol has no hook that fires
/// at quit.
///
/// WHY THIS WAS NECESSARY (verified by grep 2026-07-26, not assumed):
///   FocusLockManager.cleanup() exists and has ZERO callers. AVM had no
///   NSApplicationDelegate, no
///   applicationWillTerminate, no lifecycle hooks of any kind. Nothing ran at
///   quit. For the Caps Lock remap that is not a cosmetic gap: quitting while
///   locked would strand the mapping EVERY TIME — not just on a crash — and
///   the user's Caps Lock would stay dead on their Mac, system-wide, with no
///   caps, no screen-reader modifier, and nothing connecting the symptom to
///   AVM. A blind user would experience their whole machine as broken.
///
/// SCOPE IS DELIBERATELY MINIMAL. This delegate does exactly two things, both
/// Caps Lock. It does NOT wire up the two orphaned cleanup() methods, even
/// though this is now the natural place for them — that is a separate change
/// with separate risk (presentation options, hotkey teardown, USB device
/// release), and one variable per run. Those remain a known loose end.
///
/// THE TWO SAFETY NETS, and why both are needed:
///   - applicationWillTerminate covers the ORDINARY quit (Cmd-Q, menu Quit,
///     logout). Synchronous by necessity: there is no time for an async
///     completion to land, which is why CapsLockRemapper's hidutil calls are
///     synchronous Process invocations rather than async.
///   - recoverAtLaunch covers what termination cannot: crash, force quit,
///     power loss. It is gated on a UserDefaults flag, so if AVM did exit
///     cleanly it touches NOTHING — that is what protects a user who runs
///     their own persistent Caps Lock remap from having AVM wipe it at launch.
///   Reboot also clears any hidutil mapping, which is the last-resort remedy
///   and belongs in the tester guide's troubleshooting section.
///
/// ORDER AT LAUNCH: recovery runs in applicationDidFinishLaunching, BEFORE the
/// user can reach Enter Windows. A stranded remap is therefore cleared before
/// any new one could be applied on top of it.
///
/// TERMINATION-CONTEXT RULE (settled 2026-08-03, PERMANENT — Handoff 28):
/// the two NSLog lines below stay on NSLog. The AVMLog read resolved the
/// once-open question: FileHandle.write is an unbuffered syscall, so written
/// lines are durable and no flush path is needed — but AVMLog.write enqueues
/// via queue.async, and a write enqueued inside applicationWillTerminate can
/// be lost when the process exits before the block runs. Silently, which is
/// worse than not promoting. Lines that can fire during termination stay on
/// NSLog; the launch line stays with its partner for symmetry. This is the
/// same rule that shaped CapsLockRemapper.restore()'s context-split sink.
final class AVMAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("AVM: AppDelegate — applicationDidFinishLaunching; running Caps Lock recovery check.")
        MainActor.assumeIsolated {
            CapsLockRemapper.shared.recoverAtLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("AVM: AppDelegate — applicationWillTerminate; restoring Caps Lock if applied.")
        MainActor.assumeIsolated {
            CapsLockRemapper.shared.restoreForTermination()
        }
    }
}
