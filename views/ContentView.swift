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

    /// Posted by the Virtual Machine menu's "Attach USB Device…" and
    /// "Detach USB Device…" items (2026-09-12, USB increment 2a). Same
    /// ownership rule: the picker sheet is presented from the view tree.
    /// Attach enumerates fresh at invocation; detach reads the
    /// controller's live map. Empty answers are spoken, not shown.
    static let avmAttachUSBFromMenu = Notification.Name("avmAttachUSBFromMenu")
    static let avmDetachUSBFromMenu = Notification.Name("avmDetachUSBFromMenu")

    /// Posted by the Virtual Machine menu's "Speak Status" item
    /// (Cmd-Shift-I, 2026-10-25). ContentView answers because the active
    /// session and the machine list live here.
    static let avmSpeakStatusFromMenu = Notification.Name("avmSpeakStatusFromMenu")

    /// Posted by the Virtual Machine menu's Export and Import items
    /// (2026-10-26, MachineArchivePanels.swift). Export carries the
    /// machine's ID. ContentView answers because whether a machine is
    /// running is known here (the active session) and the list is vmStore.
    static let avmExportVMFromMenu = Notification.Name("avmExportVMFromMenu")
    static let avmImportVMFromMenu = Notification.Name("avmImportVMFromMenu")
}

/// One open of the USB picker sheet: which mode, which devices. Identity
/// is per request so the sheet reloads if a new request arrives.
struct USBPickerRequest: Identifiable {
    let id = UUID()
    let mode: USBDevicePickerView.Mode
    let devices: [AVMUSBDeviceIdentity]
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
    @State private var showingMacSetup = false
    /// The VM whose Settings sheet is open; nil means closed. Replaces the old
    /// show-Settings flag, which could only open Settings for a running VM.
    @State private var settingsTarget: VMConfiguration? = nil
    @State private var showingReclaim = false
    @State private var usbPicker: USBPickerRequest? = nil
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
                    settingsTarget: $settingsTarget
                )
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        DashboardContent(
                            observedSession: nil,
                            activeSession: $activeSession,
                            errorMessage: $errorMessage,
                            showingSetup: $showingSetup,
                            settingsTarget: $settingsTarget
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
        // Closing the window while a VM runs asks first (MainWindowCloseGuard).
        .background(WindowAccessor { window in
            MainWindowCloseGuard.shared.install(on: window)
        })
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
        //
        // START SUBMENU (2026-10-25): a request carrying a machine's ID comes
        // from the Start submenu, which names the machine, so there is no
        // guessing to refuse. It goes through the same already-running guard.
        // A machine deleted while the menu was open is spoken, not ignored.
        .onReceive(NotificationCenter.default.publisher(for: .avmStartVMFromMenu)) { note in
            guard activeSession == nil else {
                AVMLog.write("AVM: Start-from-menu — a session is already active; beeping.")
                NSSound.beep()
                errorMessage = "A virtual machine is already running."
                return
            }
            if let id = note.object as? UUID {
                guard let config = vmStore.configurations.first(where: { $0.id == id }) else {
                    AVMLog.write("AVM: Start-from-menu — requested machine \(id) is no longer configured; announcing.")
                    Announcer.shared.announce(
                        "That virtual machine is no longer in your list. Nothing was started.",
                        tone: .failure
                    )
                    return
                }
                AVMLog.write("AVM: Start-from-menu — starting '\(config.name)' (named in the Start submenu).")
                startVM(config: config)
                return
            }
            let configs = vmStore.configurations
            guard let config = configs.first, configs.count == 1 else {
                AVMLog.write("AVM: Start-from-menu — \(configs.count) configuration(s); cannot pick one. Beeping.")
                NSSound.beep()
                errorMessage = configs.isEmpty
                    ? "No virtual machine is set up yet. Use the Setup Wizard first."
                    : "More than one virtual machine is configured. Choose the one you want from Start in the Virtual Machine menu, or use the Start button next to it."
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
        .sheet(isPresented: $showingMacSetup) {
            MacSetupView()
                .environmentObject(vmStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avmShowMacSetup)) { _ in
            showingMacSetup = true
        }
        .sheet(item: $settingsTarget) { config in
            // Settings works for a stopped VM too (2026-09-26). isRunning is
            // true only for the VM this session is running. SettingsView
            // offers disk growth only when it is false.
            if config.guestOS == .macOS {
                MacSettingsView(configuration: config, isRunning: MacGuestRunner.shared.runningID == config.id)
                    .environmentObject(vmStore)
            } else {
                SettingsView(
                    configuration: config,
                    isRunning: activeSession?.configuration.id == config.id
                )
                .environmentObject(vmStore)
            }
        }
        .sheet(isPresented: $showingReclaim) {
            ReclaimView()
                .environmentObject(vmStore)
        }
        // USB picker (2026-09-12, increment 2a). Attach: the VM must be
        // running (the helper needs a listening QEMU port), the Mac must
        // see at least one device, and devices already redirected are
        // not offered twice. Detach: nothing attached is spoken; exactly
        // one attached detaches without a sheet (no picking among one);
        // several open the picker in detach mode.
        .onReceive(NotificationCenter.default.publisher(for: .avmAttachUSBFromMenu)) { _ in
            guard let manager = VMManager.shared, case .running = manager.state else {
                AVMLog.write("AVM: Attach-USB-from-menu — VM not running; announcing.", category: "USBHelper")
                Announcer.shared.announce("The virtual machine is not running. Start it, then attach a USB device.", tone: .failure)
                return
            }
            let redirected = Set(USBRedirectController.shared.redirectedDevices)
            let devices = USBDeviceEnumerator.all().filter { !redirected.contains($0) }
            guard !devices.isEmpty else {
                AVMLog.write("AVM: Attach-USB-from-menu — no devices to offer; announcing.", category: "USBHelper")
                Announcer.shared.announce("No USB devices are plugged in. Next: plug one in and try again.", tone: .info)
                return
            }
            AVMLog.write("AVM: Attach-USB-from-menu — \(devices.count) device(s); opening picker.", category: "USBHelper")
            usbPicker = USBPickerRequest(mode: .attach, devices: devices)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avmDetachUSBFromMenu)) { _ in
            let devices = USBRedirectController.shared.redirectedDevices
            switch devices.count {
            case 0:
                AVMLog.write("AVM: Detach-USB-from-menu — nothing attached; announcing.", category: "USBHelper")
                Announcer.shared.announce("No USB device is attached to the virtual machine.", tone: .info)
            case 1:
                AVMLog.write("AVM: Detach-USB-from-menu — one device; detaching directly.", category: "USBHelper")
                Task { @MainActor in
                    await USBRedirectController.shared.detach(devices[0])
                }
            default:
                AVMLog.write("AVM: Detach-USB-from-menu — \(devices.count) devices; opening picker.", category: "USBHelper")
                usbPicker = USBPickerRequest(mode: .detach, devices: devices)
            }
        }
        .sheet(item: $usbPicker) { request in
            USBDevicePickerView(mode: request.mode, devices: request.devices)
        }
        // Speak Status (Cmd-Shift-I, 2026-10-25). Always .info: asking is
        // not an outcome, so no verdict sound, even when the answer is an
        // error state. Privacy check: machine names, states and USB product
        // names only, the same things the file log already records.
        .onReceive(NotificationCenter.default.publisher(for: .avmSpeakStatusFromMenu)) { _ in
            let status = spokenStatus()
            AVMLog.write("AVM: Speak Status — \(status)")
            Announcer.shared.announce(status, tone: .info)
        }
        // Export and Import (2026-10-26). A machine is "running" for export
        // while any session for it exists (starting, running, paused or
        // shutting down) or macOS runs it: its disk is in use.
        .onReceive(NotificationCenter.default.publisher(for: .avmExportVMFromMenu)) { note in
            guard let id = note.object as? UUID,
                  let config = vmStore.configurations.first(where: { $0.id == id }) else {
                Announcer.shared.announce("That virtual machine is no longer in your list. Nothing was exported.", tone: .failure)
                return
            }
            let running = activeSession?.configuration.id == id || MacGuestRunner.shared.runningID == id
            MachineArchiveController.shared.export(config, isRunning: running)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avmImportVMFromMenu)) { _ in
            MachineArchiveController.shared.importMachine(into: vmStore)
        }
    }

    // MARK: - Helpers

    /// The words for Speak Status: the machine and its state, then where
    /// the keyboard is, then USB. Without a session, how many machines are
    /// set up, so "nothing running" is never confused with "nothing exists".
    private func spokenStatus() -> String {
        // A macOS machine runs beside any QEMU session (2026-10-26).
        let mac = MacGuestRunner.shared
        let macPart = mac.runningID.flatMap { id in vmStore.configurations.first { $0.id == id } }.map { config in
            "\(config.name), a macOS machine, is running. The keyboard is \(mac.keyboardInGuest ? "in macOS" : "on your Mac")."
        }
        guard let session = activeSession else {
            if let macPart { return macPart }
            switch vmStore.configurations.count {
            case 0:
                return "No virtual machine is set up yet. Use the Setup Wizard first."
            case 1:
                return "No virtual machine is running. \(vmStore.configurations[0].name) is ready to start."
            case let n:
                return "No virtual machine is running. \(n) virtual machines are set up."
            }
        }

        let name = session.configuration.name
        let guest = session.configuration.guestOS.displayName
        var parts: [String] = macPart.map { [$0] } ?? []
        switch session.vmState {
        case .stopped:            parts.append("\(name) is stopped.")
        case .starting:
            parts.append("\(name) is starting.")
            if let install = session.manager.spokenInstallStatus() {
                parts.append(install)
            }
        case .running:            parts.append("\(name) is running.")
        case .paused:             parts.append("\(name) is paused.")
        case .stopping:           parts.append("\(name) is shutting down.")
        case .error(let message): parts.append("\(name) stopped with an error: \(message)")
        }

        switch session.vmState {
        case .running, .paused:
            if let install = session.manager.spokenInstallStatus() {
                parts.append(install)
            }
            parts.append(focusLock.isLocked
                ? "The keyboard is in \(guest)."
                : "The keyboard is on the Mac.")
            let devices = USBRedirectController.shared.redirectedDevices.map(\.displayName)
            switch devices.count {
            case 0:  parts.append("No USB devices are attached.")
            case 1:  parts.append("One USB device is attached: \(devices[0]).")
            default: parts.append("\(devices.count) USB devices are attached: \(devices.joined(separator: ", ")).")
            }
        default:
            break
        }
        return parts.joined(separator: " ")
    }

    /// Same start path as the dashboard's per-VM Start button (see
    /// DashboardContent.startVM). Duplicated here because the menu-driven
    /// start needs access to this view's activeSession @State.
    private func startVM(config: VMConfiguration) {
        // Not while its files are being copied (2026-10-26).
        if MachineArchiveController.shared.refusesWhileBusy(config) { return }
        errorMessage = nil
        // macOS runs on Apple's Virtualization framework, in its own window
        // (MacGuest.swift), not in a QEMU session.
        if config.guestOS == .macOS {
            MacGuestRunner.shared.start(config)
            return
        }
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
    @Binding var settingsTarget: VMConfiguration?

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
                            vmState: session.vmState,
                            activeSession: $activeSession,
                            errorMessage: $errorMessage,
                            showingSetup: $showingSetup,
                            settingsTarget: $settingsTarget
                        )
                    }
                    .padding(32)
                }
                .frame(minWidth: 480, minHeight: 560)
            }
        }
        .onAppear {
            focusLock.guestName = session.configuration.guestOS.displayName
        }
        .onChange(of: session.restartingAfterInstall) { restarting in
            // AVM's restart after an Ubuntu install has ended. If it left
            // the VM stopped or in error, end the session now (it was kept
            // through the restart on purpose).
            guard !restarting else { return }
            switch session.vmState {
            case .stopped, .error: endSessionIfStoppedByItself(session.vmState)
            default: break
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
                endSessionIfStoppedByItself(newState)
            default:
                break
            }
        }
    }

    /// SESSION END WHEN THE VM STOPS BY ITSELF (code review, 2026-10-19).
    /// Only Stop and Force Stop used to end a session, so a VM that shut
    /// down from inside, an Ubuntu install that failed, or a VM that died
    /// left a stopped session behind, and the dashboard hid every Start
    /// button while any session existed: "press Start" had nothing to
    /// press. Ending the session here brings back Start, Settings and
    /// Delete exactly as after Stop. Not while AVM is starting an Ubuntu VM
    /// again after its install (same manager, same session). An error's
    /// text moves to the dashboard's error line, which outlives the session.
    /// After a Stop it runs too, harmlessly: stopGracefully watches the
    /// manager, not the session, and clears only a session still current.
    private func endSessionIfStoppedByItself(_ newState: VMRuntimeState) {
        guard activeSession === session, !session.restartingAfterInstall else { return }
        if case .error(let message) = newState {
            errorMessage = message
        }
        AVMLog.write("AVM: SessionGate — VM stopped by itself (\(newState)); ending the session so Start is available.")
        activeSession = nil
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
    /// macOS machines' state for their rows (2026-10-26).
    @ObservedObject private var macGuest = MacGuestRunner.shared

    var observedSession: VMSession?
    /// The VM state, passed by value so SwiftUI redraws this view when it
    /// changes. observedSession alone is the same object every time, so
    /// SwiftUI skipped the redraw, and after a pause the dashboard kept
    /// showing Running and a Pause button (2026-10-17). The body still
    /// reads the state through the session; this input only forces the
    /// redraw. nil when no session exists.
    var vmState: VMRuntimeState? = nil
    @Binding var activeSession: VMSession?
    @Binding var errorMessage: String?
    @Binding var showingSetup: Bool
    @Binding var settingsTarget: VMConfiguration?

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
                                Text("\(config.cpuCount) cores · \(config.ramSizeGB) GB RAM · \(config.diskSizeGB) GB disk\(storageNote(config).map { " · \($0)" } ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(config.storageIsMissing ? Color.red : Color.secondary)
                                    .accessibilityLabel("\(config.cpuCount) cores, \(config.ramSizeGB) gigabytes RAM, \(config.diskSizeGB) gigabytes disk\(storageNote(config).map { ", \($0)" } ?? "")")
                            }

                            Spacer()

                            // macOS machines run beside QEMU, in their own
                            // window (2026-10-26): their row says how they
                            // are and runs them.
                            if config.guestOS == .macOS {
                                macRowControls(config)
                            } else if let session = observedSession, session.configuration.id == config.id {
                                qemuRowControls(config, session: session)
                            } else if activeSession == nil {
                                // Saved (2026-10-27): its Start carries on.
                                if QEMUSavedState.looksSaved(config) {
                                    Text("Saved: Start carries on where you left it")
                                        .font(.caption)
                                        .accessibilityLabel("\(config.name): Saved. Start carries on where you left it")
                                }
                                Button("Start") {
                                    startVM(config: config)
                                }
                                .accessibilityLabel("Start \(config.name)")
                                .accessibilityHint(QEMUSavedState.looksSaved(config) ? "Carries on from where it was saved" : "Starts this virtual machine")

                                Button("Settings") {
                                    openSettings(config)
                                }
                                .accessibilityLabel("Settings for \(config.name)")
                                .accessibilityHint("Opens settings for this virtual machine")

                                exportButton(config)

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
                        Text("Starting \(guest)…")
                            .font(.body)
                    }

                    if session.vmState == .stopping {
                        ProgressView()
                            .accessibilityLabel("Virtual machine is stopping, please wait")
                        Text("Stopping \(guest)…")
                            .font(.body)
                    }

                    if session.vmState == .running || session.vmState == .paused {
                        Button("Enter \(guest)") {
                            focusLock.lock()
                        }
                        .accessibilityHint("Switches keyboard focus to the \(guest) display. Press Control Command Escape to return.")
                    }

                    if session.vmState == .running {
                        Button("Pause \(guest)") {
                            Task {
                                do { try await session.pause() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityHint("Pauses the virtual machine")
                    }

                    if session.vmState == .paused {
                        Button("Resume \(guest)") {
                            Task {
                                do { try await session.resume() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .accessibilityHint("Resumes the paused virtual machine")
                    }

                    if session.canSave {
                        Button("Save \(guest)") {
                            Task { await session.saveAndStop() }
                        }
                        .accessibilityHint("Keeps \(guest) as it is, open apps and all, and stops it. The next Start carries on from there in seconds.")
                    }

                    if session.canSave {
                        Button("Save Restore Point…") {
                            askRestorePointName(session)
                        }
                        .accessibilityHint("Saves \(guest) as it is now, open apps and all, as a restore point you can go back to from Settings. \(guest) keeps running.")
                    }

                    if session.vmState == .running || session.vmState == .paused {
                        Button("Stop \(guest)") {
                            shutDown(session)
                        }
                        .accessibilityHint("Gracefully shuts down \(guest)")
                        // No Command-period (2026-10-26, code audit): it's
                        // the Mac's own Cancel chord, and here it began a
                        // shutdown without asking.
                    }

                    // Force Stop is offered while shutting down too
                    // (2026-10-25, code audit): a guest that ignores the power
                    // button, such as the firmware screen or an installer, would
                    // otherwise leave nothing to press, though the two-minute
                    // reminder tells the user to use Force Stop. It asks first,
                    // Cancel the default: it is the same plug-pull as Quit Now.
                    if session.vmState == .running || session.vmState == .paused || session.vmState == .stopping {
                        Button("Force Stop") {
                            if confirmForceStop(guest: guest) {
                                session.forceStop()
                                activeSession = nil
                            }
                        }
                        .accessibilityHint("Turns the virtual machine off at once, without shutting down. Asks first.")
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

                Button("New macOS Virtual Machine…") {
                    NotificationCenter.default.post(name: .avmShowMacSetup, object: nil)
                }
                .accessibilityHint("Downloads macOS from Apple and makes a macOS virtual machine")

                // Import (2026-10-26): here too, because on a new Mac an
                // exported machine is what the user has instead of a wizard.
                Button("Import Virtual Machine…") {
                    MachineArchiveController.shared.importMachine(into: vmStore)
                }
                .accessibilityHint("Brings back a virtual machine AVM exported, from a folder ending in .avmvm")

                if activeSession != nil {
                    Button("Settings") {
                        settingsTarget = activeSession?.configuration
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
            Text("Press Control Command Escape at any time to return to the Mac. Use Enter \(guest) to go back into \(guest).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Helpers

    /// The guest's name for the words above: the running session's, or,
    /// with none, the one every saved VM shares. Windows when they differ
    /// or there are none, as before Ubuntu support.
    private var guest: String {
        if let session = observedSession {
            return session.configuration.guestOS.displayName
        }
        let kinds = Set(vmStore.configurations.map(\.guestOS))
        return kinds.count == 1 ? kinds.first!.displayName : GuestOS.windows.displayName
    }

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
    /// Where a VM stored outside the Mac's usual place lives, for the
    /// spec line (2026-10-25): its drive, or that the drive is missing, so
    /// the problem is heard on the dashboard before Start is pressed.
    private func storageNote(_ config: VMConfiguration) -> String? {
        guard config.isStoredElsewhere else { return nil }
        if config.storageIsMissing {
            return config.storageDriveName.map { "drive \($0) not connected" } ?? "storage folder not found"
        }
        return config.storageDriveName.map { "on \($0)" } ?? "in a folder you chose"
    }

    private func confirmDelete(config: VMConfiguration) {
        // Not while its files are being copied (2026-10-26).
        if MachineArchiveController.shared.refusesWhileBusy(config) { return }
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

        // A drive that isn't connected (2026-10-25): with no folder to see,
        // the dialog would say there are no files and the entry would go,
        // leaving the files on the drive. Refuse, and say what to do.
        if config.storageIsMissing {
            AVMLog.write("AVM: Delete refused for '\(config.name)' — storage folder missing.")
            Announcer.shared.announce(
                "\(config.storageMissingMessage) \(config.name) was not deleted.",
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

    private func shutDown(_ session: VMSession) {
        let guest = session.configuration.guestOS.displayName
        Task {
            // stopGracefully waits until Windows has shut down,
            // so the session (and its VMManager) stays alive the
            // whole time. Throwing it away early is what used to
            // kill QEMU mid-shutdown (fixed 2026-09-27).
            do {
                try await session.stopGracefully()
                // Clear only the session this Stop was for: after
                // a Force Stop, a new VM may already be running.
                if activeSession === session { activeSession = nil }
            } catch {
                // Keep the session, so Force Stop stays available.
                errorMessage = error.localizedDescription
                Announcer.shared.announce(
                    "\(guest) could not be shut down. Reason: \(error.localizedDescription). Next: try Stop again, or use Force Stop.",
                    tone: .failure
                )
            }
        }
    }

    // MARK: Windows and Linux machine rows (2026-10-26, as macOS ones)

    private func qemuStatus(_ session: VMSession) -> String {
        switch session.vmState {
        case .starting: return "Starting"
        case .running: return focusLock.isLocked ? "Running, keyboard in \(session.configuration.guestOS.displayName)" : "Running"
        case .paused: return "Paused"
        case .stopping: return "Shutting down"
        case .stopped: return "Shut down"
        case .error: return "Stopped with an error"
        }
    }

    @ViewBuilder
    private func qemuRowControls(_ config: VMConfiguration, session: VMSession) -> some View {
        let guest = config.guestOS.displayName
        Text(qemuStatus(session))
            .font(.caption)
            .accessibilityLabel("\(config.name): \(qemuStatus(session))")
        if session.vmState == .running || session.vmState == .paused {
            Button("Enter \(guest)") { focusLock.lock() }
                .accessibilityLabel("Enter \(config.name)")
                .accessibilityHint("Gives \(guest) the keyboard. Control-Command-Escape returns to your Mac.")
            if session.canSave {
                Button("Save") { Task { await session.saveAndStop() } }
                    .accessibilityLabel("Save \(config.name)")
                    .accessibilityHint("Keeps it as it is, open apps and all, and stops it. The next Start carries on from there in seconds.")
            }
            Button("Shut Down") { shutDown(session) }
                .accessibilityLabel("Shut down \(config.name)")
        }
    }

    // MARK: macOS machine rows (2026-10-26)

    private func macStatus(_ config: VMConfiguration) -> String {
        if macGuest.runningID == config.id {
            return macGuest.keyboardInGuest ? "Running, keyboard in macOS" : "Running"
        }
        if let folder = try? config.directoryURL(),
           FileManager.default.fileExists(atPath: MacGuestFiles(folder: folder).savedState.path) {
            return "Saved: Start carries on where you left it"
        }
        return "Shut down"
    }

    @ViewBuilder
    private func macRowControls(_ config: VMConfiguration) -> some View {
        Text(macStatus(config))
            .font(.caption)
            .accessibilityLabel("\(config.name): \(macStatus(config))")
        if macGuest.runningID == config.id {
            Button("Enter macOS") { macGuest.enter() }
                .accessibilityLabel("Enter \(config.name)")
                .accessibilityHint("Brings its window forward and gives it the keyboard")
            Button("Shut Down") { macGuest.shutDown() }
                .accessibilityLabel("Shut down \(config.name)")
        } else {
            Button("Start") { startVM(config: config) }
                .accessibilityLabel("Start \(config.name)")
                .accessibilityHint("Starts this macOS virtual machine in its own window")
                .disabled(macGuest.runningID != nil)
            Button("Settings") { openSettings(config) }
                .accessibilityLabel("Settings for \(config.name)")
            exportButton(config)
            Button("Delete") { confirmDelete(config: config) }
                .accessibilityLabel("Delete \(config.name)")
                .accessibilityHint("Moves this virtual machine and all of its files to the Trash. Asks for confirmation first.")
        }
    }

    // MARK: Export (2026-10-26)

    /// Export, in every shut-down machine's row, named for the machine.
    /// Rows only show it while the machine is shut down, so it is never
    /// running here.
    private func exportButton(_ config: VMConfiguration) -> some View {
        Button("Export…") {
            MachineArchiveController.shared.export(config, isRunning: false)
        }
        .accessibilityLabel("Export \(config.name)")
        .accessibilityHint("Copies this virtual machine to a folder or drive you choose, as a backup that Import Virtual Machine brings back")
    }

    /// Settings, except while the machine's files are being copied: a
    /// restore point or a bigger disk then would change them mid-copy.
    private func openSettings(_ config: VMConfiguration) {
        if MachineArchiveController.shared.refusesWhileBusy(config) { return }
        settingsTarget = config
    }

    private func startVM(config: VMConfiguration) {
        // Not while its files are being copied (2026-10-26).
        if MachineArchiveController.shared.refusesWhileBusy(config) { return }
        errorMessage = nil
        // macOS runs on Apple's Virtualization framework, in its own window
        // (MacGuest.swift), not in a QEMU session.
        if config.guestOS == .macOS {
            MacGuestRunner.shared.start(config)
            return
        }
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

// MARK: - Restore point while running (2026-10-27)

/// Asks for a name, then takes a restore point of the running machine,
/// memory and all (VMManager.createRunningRestorePoint). Spoken.
@MainActor
func askRestorePointName(_ session: VMSession) {
    let alert = NSAlert()
    alert.messageText = "Save a restore point for \(session.configuration.name)?"
    alert.informativeText = "It keeps open apps too, and \(session.configuration.guestOS.displayName) keeps running. Give it a name you'll recognize, such as Before the October update."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.stringValue = "Restore point from \(Date().formatted(date: .long, time: .shortened))"
    field.setAccessibilityLabel("Restore point name")
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = typed.isEmpty ? "Restore point from \(Date().formatted(date: .long, time: .shortened))" : typed
    Task { await session.saveRunningRestorePoint(label: name) }
}

// MARK: - Force Stop confirmation (2026-10-25)

    /// The Force Stop question, shared with the VM window's overlay.
func confirmForceStop(guest: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Force stop \(guest)?"
    alert.informativeText = "This turns \(guest) off at once, like pulling the plug. Unsaved work in \(guest) is lost, and if \(guest) is installing or updating, it can be damaged."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Force Stop")
    let confirmed = alert.runModal() == .alertSecondButtonReturn
    AVMLog.write("AVM: Force Stop \(confirmed ? "confirmed" : "cancelled").")
    return confirmed
}

extension Notification.Name {
    /// Opens New macOS Virtual Machine (2026-10-26, MacSetupView.swift).
    static let avmShowMacSetup = Notification.Name("avmShowMacSetup")
}
