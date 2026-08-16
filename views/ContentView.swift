// ContentView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import AppKit

// MARK: - Menu-to-dashboard requests

/// Posted by the Virtual Machine menu (AVMApp.swift) when the user invokes
/// Start Virtual Machine (Cmd-Shift-S). ContentView listens and starts the
/// configured VM if exactly one exists and nothing is running. The menu cannot
/// call startVM directly: the start path creates a VMSession into
/// ContentView's activeSession @State, which only this view owns.
extension Notification.Name {
    static let avmStartVMFromMenu = Notification.Name("avmStartVMFromMenu")

    /// Posted by the Virtual Machine menu's "Reclaim Disk Space…" item
    /// (2026-08-15). ContentView owns the response for the same reason as
    /// Start: the sheet must be presented from the view tree, and the
    /// scan-or-announce decision needs vmStore. Point 2 of the design of
    /// record lives in the handler: fresh scan at invocation, spoken
    /// answer when there is nothing to reclaim, sheet only when there is.
    static let avmReclaimFromMenu = Notification.Name("avmReclaimFromMenu")
}

struct ContentView: View {

    // MARK: - Environment

    // KeyboardInterceptor was removed 2026-07-26 (see AVMApp.swift for the
    // full rationale — the event tap was never started and never could have
    // done what its header claimed). Both its @EnvironmentObject declaration
    // here and its re-injection below went with it.
    @EnvironmentObject var vmStore: VMStore
    @EnvironmentObject var focusLock: FocusLockManager

    // MARK: - State

    // NOTE: @State only HOLDS the session; it does NOT observe the object's
    // @Published changes. All UI that depends on session.vmState must live in a
    // child view that takes the session as an @ObservedObject (SessionGate /
    // DashboardContent below), otherwise the UI never updates when the VM
    // transitions (e.g. starting -> running) and the status stays stuck.
    @State private var activeSession: VMSession? = nil
    @State private var showingSetup = false
    @State private var showingSettings = false
    @State private var showingReclaim = false
    @State private var errorMessage: String? = nil

    // MARK: - Body

    var body: some View {
        Group {
            if let session = activeSession {
                SessionGate(
                    session: session,
                    errorMessage: $errorMessage,
                    activeSession: $activeSession,
                    showingSetup: $showingSetup,
                    showingSettings: $showingSettings
                )
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        DashboardContent(
                            observedSession: nil,
                            activeSession: $activeSession,
                            errorMessage: $errorMessage,
                            showingSetup: $showingSetup,
                            showingSettings: $showingSettings
                        )
                    }
                    .padding(32)
                }
                .frame(minWidth: 480, minHeight: 560)
            }
        }
        // Inject the environment objects HERE, on the outermost Group, so they
        // flow to EVERY descendant (SessionGate, DashboardContent, VMView, and
        // their children) automatically. This prevents "No ObservableObject of
        // type FocusLockManager found" crashes in nested views.
        .environmentObject(vmStore)
        .environmentObject(focusLock)
        // Start Virtual Machine from the menu (Cmd-Shift-S). Honest scope:
        // starts the VM only when exactly ONE is configured and nothing is
        // running. Zero or multiple configurations: beep + explanatory status
        // message — never guess which machine the user meant. (A selection
        // model for multiple VMs belongs to the dashboard redesign.)
        //
        // STAGE C (2026-08-03): the three log lines below were promoted from
        // NSLog to AVMLog.write — same disposition and rationale as their
        // siblings in the Virtual Machine menu (AVMApp.swift): a chord that
        // "did nothing" is a classic field report, and these lines record
        // which gate answered. Privacy check: configuration names and counts
        // only, same as VMManager already writes to the file log.
        .onReceive(NotificationCenter.default.publisher(for: .avmStartVMFromMenu)) { _ in
            guard activeSession == nil else {
                AVMLog.write("AVM: Start-from-menu — a session is already active; beeping.")
                NSSound.beep()
                errorMessage = "A virtual machine is already running."
                return
            }
            let configs = vmStore.configurations
            guard let config = configs.first, configs.count == 1 else {
                AVMLog.write("AVM: Start-from-menu — \(configs.count) configuration(s); cannot pick one. Beeping.")
                NSSound.beep()
                errorMessage = configs.isEmpty
                    ? "No virtual machine is set up yet. Use the Setup Wizard first."
                    : "More than one virtual machine is configured. Use the Start button next to the machine you want."
                return
            }
            AVMLog.write("AVM: Start-from-menu — starting '\(config.name)'.")
            startVM(config: config)
        }
        // Reclaim Disk Space from the menu (2026-08-15, design of record
        // Point 2): fresh scan at invocation — never cached, never at
        // launch. Nothing to reclaim answers with a spoken .info, not an
        // empty dialog (a dialog demands a dismissal keystroke to say
        // nothing happened; the announcement returns you where you were).
        // Orphans found: open the sheet, which re-scans on appear.
        .onReceive(NotificationCenter.default.publisher(for: .avmReclaimFromMenu)) { _ in
            let orphans = vmStore.findOrphans()
            guard !orphans.isEmpty else {
                AVMLog.write("AVM: Reclaim-from-menu — scan found no orphans; announcing.")
                Announcer.shared.announce(
                    "No leftover files found. Nothing to reclaim.",
                    tone: .info
                )
                return
            }
            AVMLog.write("AVM: Reclaim-from-menu — scan found \(orphans.count) orphan(s); opening sheet.")
            showingReclaim = true
        }
        .sheet(isPresented: $showingSetup) {
            SetupView()
                .environmentObject(vmStore)
        }
        .sheet(isPresented: $showingSettings) {
            if let session = activeSession {
                SettingsView(session: session)
                    .environmentObject(vmStore)
            }
        }
        .sheet(isPresented: $showingReclaim) {
            ReclaimView()
                .environmentObject(vmStore)
        }
    }

    // MARK: - Helpers

    /// Same start path as the dashboard's per-VM Start button (see
    /// DashboardContent.startVM). Duplicated here because the menu-driven
    /// start needs access to this view's activeSession @State.
    private func startVM(config: VMConfiguration) {
        errorMessage = nil
        let session = VMSession(configuration: config)
        activeSession = session
        Task {
            do {
                try await session.start()
            } catch {
                errorMessage = error.localizedDescription
                activeSession = nil
            }
        }
    }
}

// MARK: - Session Gate (observes the active session AND the focus lock)

/// Observes the active VMSession and the focus lock, and chooses between the
/// live SPICE display and the dashboard.
///
/// SCREEN MODEL (the lock state drives which screen you see — this turns an
/// invisible keyboard-routing mode into a visible, audible one for VoiceOver):
///   - The VM keeps running regardless of lock state.
///   - We show the Windows display (VMView) ONLY when the VM is running/paused
///     AND focus is locked. While locked, the keyboard goes to Windows.
///   - When focus is unlocked (Control-Command-Escape, or the on-screen
///     "Return to Mac"), we drop back to the DASHBOARD while the VM keeps
///     running in the background. VoiceOver lands on "Status: Running", so the
///     user knows unambiguously they are in Mac-control mode.
///   - Re-entering Windows is the "Enter Windows" button (or Cmd-Shift-E from
///     the Virtual Machine menu), which calls focusLock.lock(); that flips
///     this gate back to VMView.
///
/// AUTO-LOCK: when the VM first reaches .running, we lock automatically so the
/// user is dropped straight into Windows with no extra step. This is driven by
/// onChange(of: vmState) here (NOT solely by VMView.onAppear), because with the
/// lock-gated condition below, VMView would not mount until isLocked is true —
/// so the lock trigger must not depend on VMView already being on screen.
private struct SessionGate: View {

    @ObservedObject var session: VMSession
    @EnvironmentObject var focusLock: FocusLockManager
    @Binding var errorMessage: String?
    @Binding var activeSession: VMSession?
    @Binding var showingSetup: Bool
    @Binding var showingSettings: Bool

    /// Tracks whether we've already auto-locked for this running session, so we
    /// only auto-lock on the first transition into .running, not on every
    /// pause/resume or re-render.
    @State private var didAutoLock = false

    private var showWindows: Bool {
        (session.vmState == .running || session.vmState == .paused) && focusLock.isLocked
    }

    var body: some View {
        Group {
            if showWindows {
                VMView(session: session)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        DashboardContent(
                            observedSession: session,
                            activeSession: $activeSession,
                            errorMessage: $errorMessage,
                            showingSetup: $showingSetup,
                            showingSettings: $showingSettings
                        )
                    }
                    .padding(32)
                }
                .frame(minWidth: 480, minHeight: 560)
            }
        }
        .onChange(of: session.vmState) { newState in
            // Auto-lock the first time the VM reaches running, so the user is
            // taken straight into Windows. Reset the latch when the VM leaves
            // the running/paused states so a future run auto-locks again.
            //
            // STAGE C (2026-08-03): the auto-lock line below was promoted from
            // NSLog to AVMLog.write — it is the single most important
            // focus-lock transition in the app (the moment AVM takes the user
            // into Windows automatically), squarely inside AVMLog's charter
            // ("focus-lock transitions"), and the anchor line for any
            // "I started the VM and got lost" field report.
            switch newState {
            case .running:
                if !didAutoLock {
                    didAutoLock = true
                    AVMLog.write("AVM: SessionGate — VM reached .running, auto-locking into Windows.")
                    focusLock.lock()
                }
            case .stopped, .error:
                didAutoLock = false
                if focusLock.isLocked {
                    focusLock.unlock()
                }
            default:
                break
            }
        }
    }
}

// MARK: - Dashboard Content

/// The main dashboard. `observedSession` is non-nil only when a session exists
/// (passed down from SessionGate, which is the @ObservedObject owner), so the
/// status text and controls reflect live VM state.
///
/// ACCESSIBILITY STRUCTURE (2026-07-19 — the honest-elements pass):
///   The VM rows were previously wrapped in
///   .accessibilityElement(children: .combine), which merged the name, the
///   spec line, and the Start/Delete buttons into ONE element. The merged
///   element inherited the button trait from its children, so VoiceOver
///   announced "button" — but pressing VO-Space did nothing, because the
///   merged element had no activation of its own. An element must never claim
///   an affordance it doesn't honor — that is the interaction equivalent of a
///   silent hang.
///   NOW: every control is its own element, and headings form a lean outline
///   for the VoiceOver heading rotor (VO-Command-H), in Allison's chosen
///   order — machines first, status after:
///     h1  Accessible Virtual Machine        (app title)
///     h2    <each VM's name>                (one per machine)
///     h3  Status                            (section, BELOW the VM list)
///   "Your Virtual Machines" remains VISIBLE text but carries NO heading
///   trait — with each machine's name already a heading, a section heading
///   above them is just one more stop between the user and the machine
///   (Allison's call, 2026-07-19).
///   The spec line is plain static text with spelled-out units (VoiceOver
///   reads "·" poorly). Start and Delete are separate, honestly-labeled
///   buttons; Delete requires CONFIRMATION (Cancel is the default button —
///   same rationale as Reset: a blind user must never be one ambiguous
///   activation away from an irreversible action).
///   The Enter Windows button carries NO keyboard shortcut — Cmd-Shift-E in
///   the Virtual Machine menu is the single documented chord for it
///   (previously the button also had plain Cmd-E; one chord, one action).
private struct DashboardContent: View {

    @EnvironmentObject var vmStore: VMStore
    @EnvironmentObject var focusLock: FocusLockManager

    var observedSession: VMSession?
    @Binding var activeSession: VMSession?
    @Binding var errorMessage: String?
    @Binding var showingSetup: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 24) {

            Text("Accessible Virtual Machine")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)

            // Saved Virtual Machines (first in the reading/heading order).
            // The section label is visible text only — NOT a heading (see
            // header comment).
            if !vmStore.configurations.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Virtual Machines")
                        .font(.headline)

                    ForEach(vmStore.configurations) { config in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(config.name)
                                    .font(.body)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityHeading(.h2)
                                Text("\(config.cpuCount) cores · \(config.ramSizeGB) GB RAM · \(config.diskSizeGB) GB disk")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("\(config.cpuCount) cores, \(config.ramSizeGB) gigabytes RAM, \(config.diskSizeGB) gigabytes disk")
                            }

                            Spacer()

                            if activeSession == nil {
                                Button("Start") {
                                    startVM(config: config)
                                }
                                .accessibilityLabel("Start \(config.name)")
                                .accessibilityHint("Starts this virtual machine")

                                Button("Delete") {
                                    confirmDelete(config: config)
                                }
                                .accessibilityLabel("Delete \(config.name)")
                                .accessibilityHint("Moves this virtual machine and all of its files to the Trash. Asks for confirmation first.")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal)
            }

            // Status (after the VM list in the reading/heading order)
            VStack(spacing: 8) {
                Text("Status")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h3)
                Text(statusMessage)
                    .font(.title2)
                    .accessibilityLabel("Virtual machine status: \(statusMessage)")
                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }
            .padding()

            // Primary Actions
            VStack(spacing: 16) {
                if let session = observedSession {
                    if session.vmState == .starting {
                        ProgressView()
                            .accessibilityLabel("Virtual machine is starting, please wait")
                        Text("Starting Windows…")
                            .font(.body)
                    }

                    if session.vmState == .stopping {
                        ProgressView()
                            .accessibilityLabel("Virtual machine is stopping, please wait")
                        Text("Stopping Windows…")
                            .font(.body)
                    }

                    if session.vmState == .running || session.vmState == .paused {
                        Button("Enter Windows") {
                            focusLock.lock()
                        }
                        .accessibilityHint("Switches keyboard focus to the Windows display. Press Control Command Escape to return.")
                    }

                    if session.vmState == .running {
                        Button("Pause Windows") {
                            Task {
                                do { try await session.pause() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityHint("Pauses the virtual machine")
                    }

                    if session.vmState == .paused {
                        Button("Resume Windows") {
                            Task {
                                do { try await session.resume() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityHint("Resumes the paused virtual machine")
                    }

                    if session.vmState == .running || session.vmState == .paused {
                        Button("Stop Windows") {
                            Task {
                                do { try await session.stop() }
                                catch { errorMessage = error.localizedDescription }
                                activeSession = nil
                            }
                        }
                        .accessibilityHint("Gracefully shuts down Windows")
                        .keyboardShortcut(".", modifiers: .command)

                        Button("Force Stop") {
                            session.forceStop()
                            activeSession = nil
                        }
                        .accessibilityHint("Immediately terminates the virtual machine without a graceful shutdown")
                    }
                }
            }

            // Secondary Actions
            VStack(spacing: 12) {
                Button("Setup Wizard") {
                    showingSetup = true
                }
                .accessibilityHint("Opens the setup wizard to create a new virtual machine")
                .keyboardShortcut("s", modifiers: .command)

                if activeSession != nil {
                    Button("Settings") {
                        showingSettings = true
                    }
                    .accessibilityHint("Opens virtual machine settings")
                    .keyboardShortcut(",", modifiers: .command)
                }
            }

            // The escape hatch is ONE-WAY by design: it always returns you to
            // the Mac, never into Windows — safe to press even when you've
            // lost track of which side your keyboard is on. Going INTO Windows
            // is always a deliberate action (Enter Windows, or Cmd-Shift-E).
            // The previous caption called this a "toggle", which the hotkey
            // never was.
            Text("Press Control Command Escape at any time to return to the Mac. Use Enter Windows to go back into Windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helpers

    private var statusMessage: String {
        guard let session = observedSession else { return "No virtual machine running" }
        switch session.vmState {
        case .stopped:        return "Stopped"
        case .starting:       return "Starting…"
        case .running:        return "Running"
        case .paused:         return "Paused"
        case .stopping:       return "Stopping…"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// Delete requires confirmation (added 2026-07-19). Same design as the
    /// Reset dialog: Cancel is the DEFAULT button so Return backs out safely;
    /// deleting requires deliberately choosing Delete.
    ///
    /// STAGE C (2026-08-03): the confirmed/cancelled lines below were promoted
    /// from NSLog to AVMLog.write — a confirmed irreversible action and its
    /// cancellation are decision-of-record material for the file log.
    ///
    /// ISSUE #5 (2026-08-15): delete now removes the VM's files, not just the
    /// list entry. Decisions of record:
    ///   - Files go to the TRASH (recoverable until emptied), and the dialog
    ///     says so explicitly — the old wording claimed "cannot be undone"
    ///     while in reality touching nothing on disk. Both halves are fixed.
    ///   - The dialog SPEAKS THE SIZE ("about 72 gigabytes"): a sighted user
    ///     gets a disk-space bar to glance at; the size in the dialog is the
    ///     non-visual equivalent, and it distinguishes a husk from your main
    ///     machine before you commit.
    ///   - RUNNING-VM GUARD: structurally, the Delete button only renders
    ///     when activeSession == nil, so this cannot fire while a VM runs.
    ///     The explicit guard below is defense in depth — if a future
    ///     dashboard redesign changes when the button renders, deleting a
    ///     disk out from under a live QEMU must still be impossible, and the
    ///     refusal must be spoken (.failure), never silent.
    ///   - Outcomes are ANNOUNCED: success .success (Glass) with the size and
    ///     the Trash-recovery note; failure .failure (Basso) stating the
    ///     machine was NOT deleted and its files are untouched (VMStore keeps
    ///     the entry on failure — see deleteMovingFilesToTrash).
    private func confirmDelete(config: VMConfiguration) {
        // Defense-in-depth guard (see header). Matching ID with a live
        // session in any non-stopped state refuses with a spoken reason.
        if let session = activeSession,
           session.configuration.id == config.id,
           session.vmState != .stopped {
            AVMLog.write("AVM: Delete refused for '\(config.name)' — VM is not stopped.")
            Announcer.shared.announce(
                "Cannot delete \(config.name) while it is running. Stop the virtual machine first.",
                tone: .failure
            )
            return
        }

        let sizeBytes = vmStore.vmDirectorySizeBytes(for: config)

        let alert = NSAlert()
        alert.messageText = "Delete \(config.name)?"
        if let bytes = sizeBytes {
            alert.informativeText = "This moves this virtual machine and all of its files — \(spokenSize(bytes)) — to the Trash. You can recover it from the Trash until the Trash is emptied."
        } else {
            // Orphaned entry: the list has it, the disk doesn't. Honest
            // wording — there are no files to move.
            alert.informativeText = "This virtual machine has no files on disk. This removes it from the list."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        if alert.runModal() == .alertSecondButtonReturn {
            AVMLog.write("AVM: Delete confirmed for '\(config.name)'.")
            do {
                let freed = try vmStore.deleteMovingFilesToTrash(config)
                if freed > 0 {
                    Announcer.shared.announce(
                        "\(config.name) deleted. \(spokenSize(freed)) moved to the Trash.",
                        tone: .success
                    )
                } else {
                    Announcer.shared.announce(
                        "\(config.name) removed from the list. There were no files on disk.",
                        tone: .success
                    )
                }
            } catch {
                Announcer.shared.announce(
                    "Deleting \(config.name) failed. The machine was not deleted and its files are untouched. \(error.localizedDescription)",
                    tone: .failure
                )
            }
        } else {
            AVMLog.write("AVM: Delete cancelled for '\(config.name)'.")
        }
    }

    /// Spoken-friendly byte size with spelled-out units — VoiceOver reads
    /// "GB" unreliably, same principle as the dashboard spec line. One
    /// decimal place above 10 units would be false precision for a dialog;
    /// whole numbers read faster and are exactly as useful.
    private func spokenSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return "about \(Int(gb.rounded())) gigabytes"
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 {
            return "about \(Int(mb.rounded())) megabytes"
        }
        return "less than one megabyte"
    }

    private func startVM(config: VMConfiguration) {
        errorMessage = nil
        let session = VMSession(configuration: config)
        activeSession = session
        Task {
            do {
                try await session.start()
            } catch {
                errorMessage = error.localizedDescription
                activeSession = nil
            }
        }
    }
}
