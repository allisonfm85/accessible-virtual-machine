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

    /// The running VM's state and the USB devices in it, so the Virtual
    /// Machine menu dims what can't act right now (2026-10-25). Both are
    /// app-lifetime singletons; observing them here is what makes the
    /// menu redraw when they change.
    @ObservedObject private var activity = VMActivity.shared
    @ObservedObject private var usbRedirect = USBRedirectController.shared
    /// A running macOS machine (MacGuest.swift): Enter goes to it when no
    /// QEMU machine is running.
    @ObservedObject private var macGuest = MacGuestRunner.shared

    /// AVM's FIRST app delegate (added 2026-07-26). See AVMAppDelegate below
    /// for why one became necessary.
    @NSApplicationDelegateAdaptor(AVMAppDelegate.self) private var appDelegate

    /// --build-install-media (InstallMediaJob.swift) builds install media
    /// with no window and exits before anything else starts; any other
    /// launch carries on as always. --audit-accessibility
    /// (AccessibilityAudit.swift, 2026-10-26) checks AVM's own screens the
    /// same way, window-less as far as the user can tell, and exits.
    init() {
        AccessibilityAudit.runIfAsked()
        InstallMediaJob.runIfAsked()
        MacTestJob.runIfAsked()
        KeyboardTestJob.runIfAsked()
    }

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
            // Start posts a notification to ContentView.
            //
            // DIMMING (2026-10-25, replaces "commands are always enabled"):
            // items that can't act right now are dimmed, read from
            // VMActivity (the app-level VM-state observable this used to
            // wait for). VoiceOver reads them as "dimmed", which says what
            // is possible before you try, and a dimmed item's key combo
            // only beeps. Start and the Start submenu dim while a machine
            // is starting, running, paused or stopping; Enter dims unless
            // running or paused; Send Ctrl-Alt-Delete, Reset and Attach USB
            // dim unless running; Detach USB dims with nothing attached.
            // Start Virtual Machine stays enabled with zero or several
            // machines set up, because it explains what to do instead.
            // Speak Status, Reclaim and Save Diagnostic Log never dim:
            // Speak Status is the way to ask why something is dimmed. The
            // handlers keep their own guards and spoken refusals as defense
            // in depth.
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
            // 6. Attach USB Device… / Detach USB Device… (no key combos) —
            //    ADDED 2026-09-12 (USB increment 2a). Post notifications;
            //    ContentView owns the picker sheet for the same reason as
            //    Reclaim (sheet presentation needs the view tree). Empty
            //    lists are spoken, never shown. The redirection itself is
            //    USBRedirectController; the announcements are
            //    USBHelperClient's. Placed after their own Divider: they
            //    change what the guest can see, not the machine's state.
            //
            // 7. Start submenu (no key combos) — ADDED 2026-10-25. Shown
            //    only when more than one VM is set up, which is exactly when
            //    Start Virtual Machine (item 1) beeps. One item per machine,
            //    named as on the dashboard. Each posts .avmStartVMFromMenu
            //    with the machine's ID; ContentView's handler starts that
            //    one, with the same already-running guard as item 1.
            //
            // 8. Speak Status (Cmd-Shift-I) — ADDED 2026-10-25. Speaks, in
            //    the system voice, which machine is in which state, which
            //    side the keyboard is on, and which USB devices are
            //    attached. The non-visual glance at the dashboard: it works
            //    with VoiceOver asleep (the VO-OFF ritual in item 2) and
            //    without leaving where you are. It gets a combo because it
            //    is asked during normal use, not maintenance. Posts
            //    .avmSpeakStatusFromMenu; ContentView answers, since the
            //    session and the machine list live there.
            //
            // Debug menu — DEBUG BUILDS ONLY. Test instruments for the USB
            // helper scaffold (2026-09-07). Nothing here ships. The version
            // probe is the first end-to-end proof of the privileged path:
            // lazy registration, Login Items approval, launchd start, the
            // helper's code-signing gate, and one reply. Every outcome is
            // spoken through Announcer; every failure names its step. The
            // Attach/Detach ATR2100x instruments and USBRedirectDebug.swift
            // were deleted 2026-09-12 when the real picker shipped.
            #if DEBUG
            CommandMenu("Debug") {
                Button("USB Helper: Version Probe") {
                    Task { @MainActor in
                        AVMLog.write("Debug menu: USB helper version probe", category: "USBHelper")
                        switch await USBHelperClient.shared.fetchHelperVersion() {
                        case .success(let version):
                            Announcer.shared.announce("USB helper answered: \(version)", tone: .success)
                        case .failure(.notEnabled):
                            // The approval dialog or the registration
                            // announcement already said what to do.
                            break
                        case .failure(let error):
                            Announcer.shared.announce("USB helper did not answer. Step: XPC call. Reason: \(error). Next: check Login Items, then the diagnostic log.", tone: .failure)
                        }
                    }
                }
                Button("USB Helper: Status") {
                    let s = USBHelperClient.shared.refreshStatus()
                    AVMLog.write("Debug menu: USB helper status \(s.rawValue)", category: "USBHelper")
                    Announcer.shared.announce("USB helper status: \(s.rawValue).", tone: .info)
                }
                Button("USB Helper: Open Login Items") {
                    USBHelperClient.shared.openLoginItems()
                }
                Button("USB Helper: Unregister") {
                    USBHelperClient.shared.unregister()
                }
            }
            #endif
            CommandMenu("Virtual Machine") {
                Button("Start Virtual Machine") {
                    AVMLog.write("AVM: Start Virtual Machine menu — posting start request to ContentView.")
                    NotificationCenter.default.post(name: .avmStartVMFromMenu, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!activity.canStart)

                if vmStore.configurations.count > 1 {
                    Menu("Start") {
                        ForEach(vmStore.configurations) { config in
                            Button(config.name) {
                                AVMLog.write("AVM: Start submenu — posting start request for '\(config.name)' to ContentView.")
                                NotificationCenter.default.post(name: .avmStartVMFromMenu, object: config.id)
                            }
                        }
                    }
                    .disabled(!activity.canStart)
                }

                Button(macGuest.runningID != nil && !activity.isRunningOrPaused ? "Enter macOS" : "Enter \(focusLock.guestName)") {
                    // A macOS machine has its own window and keyboard model
                    // (2026-10-26, MacGuest.swift).
                    if macGuest.runningID != nil && !activity.isRunningOrPaused {
                        AVMLog.write("AVM: Enter macOS menu — giving the macOS machine the keyboard.")
                        macGuest.enter()
                        return
                    }
                    // Same gate as the dashboard's Enter Windows button: only
                    // meaningful when a VM is running or paused. focusLock.lock()
                    // flips SessionGate to VMView and speaks "Windows keyboard
                    // on" (system voice — audible with VoiceOver off).
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
                .disabled(!activity.isRunningOrPaused && macGuest.runningID == nil)

                // macOS's VoiceOver from any screen (2026-10-26): Command-F5
                // reaches the macOS machine for 10 seconds. MacGuest.swift.
                if macGuest.runningID != nil {
                    Button("Pass Command-F5 to macOS") {
                        AVMLog.write("AVM: Pass Command-F5 menu — system keys to the macOS machine for 10 seconds.")
                        macGuest.passSystemKeysBriefly()
                    }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                }

                Button("Speak Status") {
                    AVMLog.write("AVM: Speak Status menu — posting request to ContentView.")
                    NotificationCenter.default.post(name: .avmSpeakStatusFromMenu, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("Send Ctrl-Alt-Delete") {
                    Task { @MainActor in
                        await VMManager.shared?.sendCtrlAltDel()
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!activity.isRunning)

                Divider()

                Button("Attach USB Device…") {
                    AVMLog.write("AVM: Attach USB Device menu — posting request to ContentView.", category: "USBHelper")
                    NotificationCenter.default.post(name: .avmAttachUSBFromMenu, object: nil)
                }
                .disabled(!activity.isRunning)
                Button("Detach USB Device…") {
                    AVMLog.write("AVM: Detach USB Device menu — posting request to ContentView.", category: "USBHelper")
                    NotificationCenter.default.post(name: .avmDetachUSBFromMenu, object: nil)
                }
                .disabled(usbRedirect.portByDevice.isEmpty)

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
                        let guest = VMManager.currentGuestName
                        alert.informativeText = "This is like pressing the reset button on a physical PC. \(guest) restarts immediately and unsaved work inside the virtual machine is lost. If \(guest) is installing or updating, a reset can damage it."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Cancel")
                        alert.addButton(withTitle: "Reset")
                        if alert.runModal() == .alertSecondButtonReturn {
                            await manager.resetVM()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!activity.isRunning)

                Divider()

                // 9. Export and Import (2026-10-26, MachineArchivePanels
                //    .swift). Export names the machine: one item when there
                //    is one machine, a submenu of names when there are
                //    several, dimmed with none. Not dimmed for a running
                //    machine: its handler says to shut it down first, which
                //    a dimmed item couldn't. Import is always there. No key
                //    combos: rare, deliberate, like Reclaim.
                if vmStore.configurations.count > 1 {
                    Menu("Export Virtual Machine") {
                        ForEach(vmStore.configurations) { config in
                            Button("\(config.name)…") {
                                AVMLog.write("AVM: Export submenu — posting export request for '\(config.name)' to ContentView.")
                                NotificationCenter.default.post(name: .avmExportVMFromMenu, object: config.id)
                            }
                        }
                    }
                } else {
                    Button("Export Virtual Machine…") {
                        guard let config = vmStore.configurations.first else { return }
                        AVMLog.write("AVM: Export Virtual Machine menu — posting export request for '\(config.name)' to ContentView.")
                        NotificationCenter.default.post(name: .avmExportVMFromMenu, object: config.id)
                    }
                    .disabled(vmStore.configurations.isEmpty)
                }

                Button("Import Virtual Machine…") {
                    AVMLog.write("AVM: Import Virtual Machine menu — posting import request to ContentView.")
                    NotificationCenter.default.post(name: .avmImportVMFromMenu, object: nil)
                }

                Divider()

                Button("Reclaim Disk Space…") {
                    AVMLog.write("AVM: Reclaim Disk Space menu — posting reclaim request to ContentView.")
                    NotificationCenter.default.post(name: .avmReclaimFromMenu, object: nil)
                }
            }

            // Help menu (2026-10-24, suggested by Victor Tsaran). The system's
            // own Help item only said help isn't available for AVM. This
            // replaces it with one item that opens the README, where the
            // help is. It goes straight to the README rather than the
            // repository's main page, so someone who's stuck lands where
            // they need to be. No key combo: Command-? would be the usual one,
            // but macOS keeps it for the Help menu's search, so this item
            // never received it (tested 2026-10-24). The search field is the
            // system's and stays.
            CommandGroup(replacing: .help) {
                // Report a Problem… (2026-10-26, ProblemReporter.swift).
                Button("Report a Problem…") {
                    ProblemReporter.reportAProblem()
                }
                Button("AVM README on GitHub") {
                    AVMLog.write("AVM: Help menu — opening the README on GitHub.")
                    if let url = URL(string: "https://github.com/allisonfm85/accessible-virtual-machine#readme") {
                        NSWorkspace.shared.open(url)
                    }
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
            // The Mac's VoiceOver back on if AVM ended while it was off for a
            // macOS machine (2026-10-26).
            MacVoiceOver.recoverAtLaunch()
            // Pause a running VM before the Mac sleeps (2026-10-26).
            SleepCoordinator.shared.start()
        }
    }

    /// Quitting with a VM running (2026-10-25). See QuitCoordinator.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            QuitCoordinator.shouldTerminate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("AVM: AppDelegate — applicationWillTerminate; restoring Caps Lock if applied.")
        MainActor.assumeIsolated {
            CapsLockRemapper.shared.restoreForTermination()
            // The Mac's VoiceOver back on if AVM turned it off for a macOS
            // machine (2026-10-26, MacVoiceOver in MacGuest.swift).
            MacVoiceOver.restoreAfterGuest(beforeQuitting: true)
            // The focus lock's own teardown (2026-10-25): its hot key, its
            // focus enforcement, and the presentation options it sets.
            // cleanup() existed with no callers; this is the place the
            // header above left for it.
            FocusLockManager.shared?.cleanup()
            Announcer.shared.waitUntilQuiet(seconds: 8)
        }
    }
}

// MARK: - Closing the window with a VM running (2026-10-25)

/// AVM has one window, and the running VM's session lives in it. Closing it
/// (Command-W, the close button) used to tear that session down, which
/// pulled the plug on the guest with no question, nothing spoken, and USB
/// devices left in the VM (code audit). While a VM is active, Close now
/// asks the quit question instead (QuitCoordinator), and the window stays
/// open unless AVM really quits. Installed as the window's delegate,
/// forwarding everything else to the delegate SwiftUI set.
final class MainWindowCloseGuard: NSObject, NSWindowDelegate {
    static let shared = MainWindowCloseGuard()
    private weak var original: NSWindowDelegate?

    func install(on window: NSWindow) {
        guard window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if QuitCoordinator.vmIsActive {
            AVMLog.write("AVM: Close window — a VM is active; asking the quit question.")
            QuitCoordinator.closingWindow = true
            NSApp.terminate(nil)
            QuitCoordinator.closingWindow = false
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

/// Hands its window to a closure once it is in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { onWindow(window) }
    }
}

// MARK: - Quitting with a VM running

/// What happens at Quit while a VM is starting, running, paused or
/// shutting down (2026-10-25). Before this, nothing stopped QEMU at quit:
/// the guest kept running with no window, and USB devices stayed in it.
///
/// Asks first, Cancel the default (same rule as Reset and Delete: one
/// ambiguous key press must never cost a blind user their work):
///   - Shut Down <guest> and Quit: the quit is cancelled, the guest is
///     shut down as Stop does, and AVM quits once it has. The wait can be
///     minutes during an update, so AVM stays usable meanwhile (Force Stop
///     works, and Quit again offers Quit Now); holding macOS in a
///     terminate-later state that long would freeze the app instead.
///   - Quit Now: like pulling the plug.
/// Either way, USB devices go back to the Mac first, and QEMU is gone
/// before AVM exits (VMManager.terminateForQuit). Every outcome is spoken.
@MainActor
enum QuitCoordinator {

    /// True from Shut Down and Quit until the guest has shut down.
    private static var quitWhenShutDown = false

    /// How long giving USB devices back may hold up the quit. The helper
    /// answers in milliseconds; this only guards against one that doesn't.
    private static let usbReleaseLimit: Duration = .seconds(5)

    /// A VM is starting, running, paused or shutting down, and there is a
    /// manager for it. VMActivity alone could say so for a VM whose manager
    /// is already gone (2026-10-25, code audit), and asking about that one
    /// made Shut Down and Quit call terminate from inside terminate, which
    /// asked again, in a loop.
    static var vmIsActive: Bool {
        guard VMManager.shared != nil else { return false }
        switch VMActivity.shared.state {
        case .starting, .running, .paused, .stopping: return true
        case .stopped, .error: return false
        }
    }

    /// True while the main window's Close is being handled, so the
    /// question can say that closing ends the VM too.
    static var closingWindow = false

    static func shouldTerminate() -> NSApplication.TerminateReply {
        // An export or import in progress (2026-10-26): quitting stops it.
        // Its half-made copy is a hidden folder that the next export to the
        // same place, or the next import, clears away. Cancel is the default.
        if let activity = MachineArchiveController.shared.activity {
            let alert = NSAlert()
            alert.messageText = "AVM is \(activity). Quit anyway?"
            alert.informativeText = "Quitting stops it part way. The machine itself is untouched. The half-made copy is hidden, never mistaken for a whole one, and AVM clears it away the next time you export or import."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit and Stop")
            guard alert.runModal() == .alertSecondButtonReturn else {
                AVMLog.write("AVM: Quit — cancelled while \(activity).")
                return .terminateCancel
            }
            AVMLog.write("AVM: Quit — chosen while \(activity).")
        }
        // A macOS machine runs inside AVM itself (2026-10-26): quitting
        // ends it at once, so ask.
        if MacGuestRunner.shared.runningID != nil {
            let alert = NSAlert()
            alert.messageText = "macOS is still running. Quit AVM?"
            alert.informativeText = "Quitting turns the macOS machine off at once, like pulling the plug; unsaved work in it is lost. To shut it down properly first, choose Cancel, then Shut Down in its window."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Now")
            // Save and Quit (2026-10-26): macOS kept as it is, resumed in
            // seconds at the next Start (MacGuestRunner.saveAndStop).
            let saveable = MacGuestRunner.shared.canSave
            if saveable {
                alert.addButton(withTitle: "Save and Quit")
                alert.informativeText += " Save and Quit keeps macOS as it is, open apps and all, and its next Start carries on from there in seconds."
            }
            // BOTH KINDS RUNNING (2026-10-26, code audit): the macOS answer
            // used to end the quit here, so a Windows or Linux machine
            // running beside it was cut off unasked and its USB devices
            // never given back. Now a Windows or Linux machine is asked
            // about next: Quit Now goes on to that question, and Save and
            // Quit saves macOS, then quits again, which asks it.
            let otherActive = vmIsActive || !USBRedirectController.shared.portByDevice.isEmpty
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                if !otherActive { return .terminateNow }
                MacGuestRunner.shared.forceStop()
            case .alertThirdButtonReturn where saveable:
                if !otherActive {
                    MacGuestRunner.shared.saveAndStop { saved in
                        NSApp.reply(toApplicationShouldTerminate: saved)
                    }
                    return .terminateLater
                }
                MacGuestRunner.shared.saveAndStop { saved in
                    if saved { NSApp.terminate(nil) }
                }
                return .terminateCancel
            default:
                return .terminateCancel
            }
        }
        let vmActive = vmIsActive
        let hasUSB = !USBRedirectController.shared.portByDevice.isEmpty
        guard vmActive || hasUSB else { return .terminateNow }

        if vmActive {
            let guest = VMManager.currentGuestName
            // While starting, nothing can shut it down yet (stopGracefully
            // refuses before .running), so only Cancel and Quit Now.
            let starting = VMActivity.shared.state == .starting
            let alert = NSAlert()
            if quitWhenShutDown {
                alert.messageText = "AVM is waiting for \(guest) to shut down. Quit now?"
            } else if starting {
                alert.messageText = "\(guest) is starting. Quit AVM?"
            } else {
                alert.messageText = "\(guest) is still running. Quit AVM?"
            }
            let closeNote = closingWindow ? "Closing AVM's window quits AVM, which ends \(guest) too. " : ""
            alert.informativeText = starting
                ? closeNote + "Quit Now stops \(guest) while it starts. If it is building install media, that work is lost and starts again next time."
                : closeNote + "Quit Now turns \(guest) off at once, like pulling the plug, and unsaved work in \(guest) is lost. Shut Down \(guest) and Quit shuts it down first, and AVM quits when it has finished. That can take a few minutes if \(guest) is updating."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            if !starting {
                alert.addButton(withTitle: "Shut Down \(guest) and Quit")
            }
            alert.addButton(withTitle: "Quit Now")
            let choice = alert.runModal()
            let shutDown = !starting && choice == .alertSecondButtonReturn
            let quitNow = starting ? choice == .alertSecondButtonReturn : choice == .alertThirdButtonReturn
            if shutDown {
                AVMLog.write("AVM: Quit — Shut Down and Quit chosen.")
                beginShutDownThenQuit(guest: guest)
                return .terminateCancel
            } else if quitNow {
                AVMLog.write("AVM: Quit — Quit Now chosen with the VM \(VMActivity.shared.state).")
            } else {
                AVMLog.write("AVM: Quit — cancelled with the VM \(VMActivity.shared.state).")
                return .terminateCancel
            }
        }

        Task { @MainActor in
            await releaseUSBDevices()
            if vmActive {
                VMManager.shared?.terminateForQuit()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func beginShutDownThenQuit(guest: String) {
        guard !quitWhenShutDown else {
            // Already shutting down for a quit; the alert's Cancel or
            // this choice both mean keep waiting.
            Announcer.shared.announce("Still waiting for \(guest) to shut down. AVM quits when it has.", tone: .info)
            return
        }
        guard let session = VMSession.current else {
            // Called from inside applicationShouldTerminate: quit on the
            // next turn, not re-entrantly (2026-10-25, code audit).
            AVMLog.write("AVM: Quit — no current session to shut down; quitting.")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        quitWhenShutDown = true
        Announcer.shared.announce("AVM will quit when \(guest) has shut down.", tone: .info)
        Task { @MainActor in
            do {
                if session.vmState == .stopping {
                    // A Stop is already under way; wait for it.
                    while session.vmState == .stopping {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } else {
                    try await session.stopGracefully()
                }
            } catch {
                quitWhenShutDown = false
                AVMLog.write("AVM: Quit — shutdown for quit failed: \(error.localizedDescription)")
                Announcer.shared.announce(
                    "\(guest) could not be shut down, so AVM did not quit. Reason: \(error.localizedDescription) Next: try Quit again, and choose Quit Now if \(guest) is not responding.",
                    tone: .failure
                )
                return
            }
            quitWhenShutDown = false
            AVMLog.write("AVM: Quit — guest has shut down; quitting.")
            NSApp.terminate(nil)
        }
    }

    /// Gives every attached USB device back to the Mac, waiting at most
    /// usbReleaseLimit. Each release is spoken by USBHelperClient.
    private static func releaseUSBDevices() async {
        let devices = USBRedirectController.shared.redirectedDevices
        guard !devices.isEmpty else { return }
        AVMLog.write("AVM: Quit — giving \(devices.count) USB device(s) back to the Mac.", category: "USBHelper")
        // A race, not a task group: a group waits for every child, and a
        // detach stuck in XPC can't be cancelled, so the limit would never
        // apply. Whichever finishes first resumes; the other is ignored.
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                for device in devices {
                    await USBRedirectController.shared.detach(device)
                }
                once.resume(continuation)
            }
            Task { @MainActor in
                try? await Task.sleep(for: usbReleaseLimit)
                if once.resume(continuation) {
                    AVMLog.write("AVM: Quit — USB release took longer than \(usbReleaseLimit); quitting anyway.", category: "USBHelper")
                }
            }
        }
    }

    /// Resumes a continuation exactly once, whichever caller is first.
    @MainActor
    private final class ResumeOnce {
        private var done = false
        /// True if this call did the resuming.
        @discardableResult
        func resume(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            guard !done else { return false }
            done = true
            continuation.resume()
            return true
        }
    }
}
