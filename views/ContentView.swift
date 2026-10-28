// ContentView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import AppKit

// MARK: - Menu-to-dashboard requests

/// Posted by the Virtual Machine menu (AVMApp.swift) when the user invokes
/// Start Virtual Machine (Cmd-Shift-S). ContentView listens and starts the
/// configured VM if exactly one exists and nothing is running. The menu cannot
/// call startVM directly: the start path creates a VMSession into
/// MachineSessions, which holds every running machine.
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
    /// Bluetooth Devices… (2026-10-27, BluetoothDevices.swift).
    static let avmBluetoothDevices = Notification.Name("avmBluetoothDevices")
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
/// The machine the Bluetooth Devices window is for.
struct BluetoothWindowRequest: Identifiable {
    let id = UUID()
    let machine: VMManager
}

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
    // child view that takes the session as an @ObservedObject (QEMUMachineRow
    // below), otherwise the UI never updates when the VM
    // transitions (e.g. starting -> running) and the status stays stuck.
    /// Every running Windows or Linux machine (2026-10-27): several can
    /// run at once, each in its own window (MachineSessions).
    @ObservedObject private var machines = MachineSessions.shared
    @State private var showingSetup = false
    @State private var showingMacSetup = false
    /// The VM whose Settings sheet is open; nil means closed. Replaces the old
    /// show-Settings flag, which could only open Settings for a running VM.
    @State private var settingsTarget: VMConfiguration? = nil
    @State private var showingReclaim = false
    @State private var usbPicker: USBPickerRequest? = nil
    @State private var bluetoothWindow: BluetoothWindowRequest? = nil
    @State private var errorMessage: String? = nil

    // MARK: - Body

    var body: some View {
        Group {
            ScrollView {
                VStack(spacing: 24) {
                    DashboardContent(
                        errorMessage: $errorMessage,
                        showingSetup: $showingSetup,
                        settingsTarget: $settingsTarget
                    )
                }
                .padding(32)
            }
            .frame(minWidth: 480, minHeight: 560)
        }
        // Inject the environment objects HERE, on the outermost Group, so they
        // flow to EVERY descendant (DashboardContent, the machine rows, and
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
                    isRunning: machines.session(for: config.id) != nil
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
        .onReceive(NotificationCenter.default.publisher(for: .avmBluetoothDevices)) { _ in
            guard let manager = VMManager.shared, case .running = manager.state else {
                Announcer.shared.announce("The virtual machine is not running. Start it, then send a Bluetooth device.", tone: .failure)
                return
            }
            bluetoothWindow = BluetoothWindowRequest(machine: manager)
        }
        .sheet(item: $bluetoothWindow) { request in
            BluetoothDevicesView(machine: request.machine)
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
            let running = machines.session(for: id) != nil || MacGuestRunner.shared.runningID == id
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
        let running = machines.sessions.values.sorted { $0.configuration.name < $1.configuration.name }
        guard !running.isEmpty else {
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

        var parts: [String] = macPart.map { [$0] } ?? []
        for session in running {
            let name = session.configuration.name
            switch session.vmState {
            case .stopped:            parts.append("\(name) is stopped.")
            case .starting:
                parts.append("\(name) is starting.")
                if let install = session.manager.spokenInstallStatus() { parts.append(install) }
            case .running:            parts.append("\(name) is running.")
            case .paused:             parts.append("\(name) is paused.")
            case .stopping:           parts.append("\(name) is shutting down.")
            case .error(let message): parts.append("\(name) stopped with an error: \(message)")
            }
            if session.vmState == .running || session.vmState == .paused,
               let install = session.manager.spokenInstallStatus() {
                parts.append(install)
            }
        }
        if running.contains(where: { $0.vmState == .running || $0.vmState == .paused }) {
            if focusLock.isLocked, let current = machines.current {
                parts.append("The keyboard is in \(current.configuration.name).")
            } else {
                parts.append("The keyboard is on the Mac.")
            }
            let devices = USBRedirectController.shared.redirectedDevices.map(\.displayName)
            switch devices.count {
            case 0:  parts.append("No USB devices are attached.")
            case 1:  parts.append("One USB device is attached: \(devices[0]).")
            default: parts.append("\(devices.count) USB devices are attached: \(devices.joined(separator: ", ")).")
            }
        }
        return parts.joined(separator: " ")
    }

    /// Same start path as the dashboard's per-VM Start button (see
    /// DashboardContent.startVM).
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
        MachineSessions.shared.start(config, vmStore: vmStore, focusLock: focusLock, windowless: config.startsWithoutWindow)
    }
}

// MARK: - Dashboard Content

/// The main dashboard: every machine, each running one with its own
/// controls (QEMUMachineRow), whatever the others are doing.
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

    /// Every running Windows or Linux machine; each row observes its own
    /// session (QEMUMachineRow), so it redraws as that machine changes.
    @ObservedObject private var machines = MachineSessions.shared
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
                            } else if let session = machines.session(for: config.id) {
                                QEMUMachineRow(session: session, errorMessage: $errorMessage)
                            } else {
                                // Saved (2026-10-27): its Start carries on.
                                if QEMUSavedState.looksSaved(config) {
                                    Text("Saved: Start carries on where you left it")
                                        .font(.caption)
                                        .accessibilityLabel("\(config.name): Saved. Start carries on where you left it")
                                }
                                if config.isATemplate {
                                    templateButton(config)
                                } else {
                                    Button("Start") {
                                        startVM(config: config)
                                    }
                                    .accessibilityLabel("Start \(config.name)")
                                    .accessibilityHint(QEMUSavedState.looksSaved(config) ? "Carries on from where it was saved" : "Starts this virtual machine")
                                }

                                Button("Settings") {
                                    openSettings(config)
                                }
                                .accessibilityLabel("Settings for \(config.name)")
                                .accessibilityHint("Opens settings for this virtual machine")

                                exportButton(config)
                                duplicateButton(config)

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
                if let error = errorMessage ?? machines.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(error)")
                }
            }
            .padding()

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

                // Restart USB Helper (2026-10-27): for a USB device that stays
                // on the Mac when it shouldn't.
                Button("Restart USB Helper") {
                    Task { await USBRedirectController.shared.restartHelper() }
                }
                .accessibilityHint("Returns USB devices to the Mac and restarts the part of AVM that sends them to a virtual machine. Use it if a device won't go across.")

                // Import (2026-10-26): here too, because on a new Mac an
                // exported machine is what the user has instead of a wizard.
                Button("Import Virtual Machine…") {
                    MachineArchiveController.shared.importMachine(into: vmStore)
                }
                .accessibilityHint("Brings back a virtual machine AVM exported, from a folder ending in .avmvm")

                if let current = machines.current {
                    Button("Settings") {
                        settingsTarget = current.configuration
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
        if let session = machines.current {
            return session.configuration.guestOS.displayName
        }
        let kinds = Set(vmStore.configurations.map(\.guestOS))
        return kinds.count == 1 ? kinds.first!.displayName : GuestOS.windows.displayName
    }

    private var statusMessage: String {
        let running = machines.sessions.count
        switch running {
        case 0: return "No virtual machine running"
        case 1: return "One virtual machine running"
        default: return "\(running) virtual machines running"
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
    ///     for a machine with no session, so this cannot fire while it runs.
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
        if let session = machines.session(for: config.id),
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
            if config.isATemplate {
                templateButton(config)
            } else {
                Button("Start") { startVM(config: config) }
                    .accessibilityLabel("Start \(config.name)")
                    .accessibilityHint("Starts this macOS virtual machine in its own window")
                    .disabled(macGuest.runningID != nil)
            }
            Button("Settings") { openSettings(config) }
                .accessibilityLabel("Settings for \(config.name)")
            exportButton(config)
            duplicateButton(config)
            Button("Delete") { confirmDelete(config: config) }
                .accessibilityLabel("Delete \(config.name)")
                .accessibilityHint("Moves this virtual machine and all of its files to the Trash. Asks for confirmation first.")
        }
    }

    // MARK: Duplicate and templates (2026-10-27)

    /// Duplicate…, in every shut-down machine's row (MachineArchiveController).
    private func duplicateButton(_ config: VMConfiguration) -> some View {
        Button("Duplicate…") {
            MachineArchiveController.shared.duplicate(config, isRunning: false, into: vmStore)
        }
        .accessibilityLabel("Duplicate \(config.name)")
        .accessibilityHint("Makes a second machine just like this one, which can run at the same time. Asks for its name.")
    }

    /// A template's row: it says so, and makes new machines from it
    /// instead of starting.
    @ViewBuilder
    private func templateButton(_ config: VMConfiguration) -> some View {
        Text("Template")
            .font(.caption)
            .accessibilityLabel("\(config.name) is a template")
        Button("New Machine from Template…") {
            MachineArchiveController.shared.duplicate(config, isRunning: false, into: vmStore)
        }
        .accessibilityLabel("New machine from \(config.name)")
        .accessibilityHint("Makes a new machine just like this template, which stays as it is. Asks for its name. To change the template itself, turn off Use as a Template in its Settings.")
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
        MachineSessions.shared.start(config, vmStore: vmStore, focusLock: focusLock, windowless: config.startsWithoutWindow)
    }
}

// MARK: - A running Windows or Linux machine's row (2026-10-27)

/// Everything for one running machine, in its row of the list: how it is,
/// and Enter, Pause or Resume, Save, Save Restore Point, Shut Down and
/// Force Stop. Several machines can run at once, each with its own row and
/// window, so each row observes its own session.
private struct QEMUMachineRow: View {
    @ObservedObject var session: VMSession
    @Binding var errorMessage: String?
    @EnvironmentObject var focusLock: FocusLockManager
    @ObservedObject private var machines = MachineSessions.shared

    private var name: String { session.configuration.name }

    private var status: String {
        switch session.vmState {
        case .starting: return "Starting"
        case .running:
            return focusLock.isLocked && machines.currentID == session.configuration.id ? "Running, keyboard in \(name)" : "Running"
        case .paused: return "Paused"
        case .stopping: return "Shutting down"
        case .stopped: return "Shut down"
        case .error: return "Stopped with an error"
        }
    }

    var body: some View {
        Text(status)
            .font(.caption)
            .accessibilityLabel("\(name): \(status)")
        if session.vmState == .running || session.vmState == .paused {
            Button("Enter") { MachineSessions.shared.enter(session.configuration.id) }
                .accessibilityLabel("Enter \(name)")
                .accessibilityHint("Brings its window forward and gives it the keyboard. Control-Command-Escape returns to your Mac.")
        }
        if session.vmState == .running {
            Button("Send File…") { chooseFileToSend(session) }
                .accessibilityLabel("Send a file to \(name)")
                .accessibilityHint("Copies a file from your Mac into Downloads in \(name)")
            // On the row too (2026-10-27): a device that stayed on the Mac
            // can be sent without unplugging it.
            Button("Attach USB Device…") {
                MachineSessions.shared.makeCurrent(session.configuration.id)
                NotificationCenter.default.post(name: .avmAttachUSBFromMenu, object: nil)
            }
            .accessibilityLabel("Attach a USB device to \(name)")
            .accessibilityHint("Lists the USB devices plugged into your Mac and sends the one you choose. Command Shift U.")
            Button("Bluetooth Devices…") {
                MachineSessions.shared.makeCurrent(session.configuration.id)
                NotificationCenter.default.post(name: .avmBluetoothDevices, object: nil)
            }
            .accessibilityLabel("Bluetooth devices for \(name)")
            .accessibilityHint("Sends a Bluetooth braille display, game controller or other device to \(name). Command Shift B.")
            Button("Pause") {
                Task {
                    do { try await session.pause() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            .accessibilityLabel("Pause \(name)")
        }
        if session.vmState == .paused {
            Button("Resume") {
                Task {
                    do { try await session.resume() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            .accessibilityLabel("Resume \(name)")
        }
        if session.canSave {
            Button("Save") { Task { await session.saveAndStop() } }
                .accessibilityLabel("Save \(name)")
                .accessibilityHint("Keeps it as it is, open apps and all, and stops it. The next Start carries on from there in seconds.")
            Button("Save Restore Point…") { askRestorePointName(session) }
                .accessibilityLabel("Save a restore point for \(name)")
                .accessibilityHint("Saves it as it is now, open apps and all, as a restore point you can go back to from Settings. It keeps running.")
        }
        if session.vmState == .running || session.vmState == .paused {
            Button("Shut Down") { shutDown() }
                .accessibilityLabel("Shut down \(name)")
        }
        // Force Stop while shutting down too (2026-10-25, code audit): a
        // guest that ignores the power button would otherwise leave nothing
        // to press. Asks first, Cancel the default.
        if session.vmState == .running || session.vmState == .paused || session.vmState == .stopping {
            Button("Force Stop") {
                if confirmForceStop(guest: name) {
                    session.forceStop()
                }
            }
            .accessibilityLabel("Force stop \(name)")
            .accessibilityHint("Turns it off at once, without shutting down. Asks first.")
        }
    }

    private func shutDown() {
        Task {
            // stopGracefully waits until the machine has shut down, so its
            // session stays alive the whole time (fixed 2026-09-27); the
            // session ends when it stops (MachineSessions).
            do {
                try await session.stopGracefully()
            } catch {
                errorMessage = error.localizedDescription
                Announcer.shared.announce(
                    "\(name) could not be shut down. Reason: \(error.localizedDescription). Next: try Shut Down again, or use Force Stop.",
                    tone: .failure
                )
            }
        }
    }
}

// MARK: - Send a file (2026-10-27)

/// Asks which file, then sends it into the machine's Downloads
/// (VMManager.sendFile). Spoken.
@MainActor
func chooseFileToSend(_ session: VMSession) {
    let panel = NSOpenPanel()
    panel.title = "Send a File to \(session.configuration.name)"
    panel.message = "Choose a file. It goes into Downloads in \(session.configuration.name)."
    panel.prompt = "Send"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let files = panel.urls
    Task {
        for file in files {
            await session.manager.sendFile(file)
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
