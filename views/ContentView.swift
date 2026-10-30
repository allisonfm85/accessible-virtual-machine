// ContentView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import Combine
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
    /// Return Devices to Mac… (2026-10-29, MachineDevicesView.swift), in
    /// place of Detach USB Device….
    static let avmMachineDevices = Notification.Name("avmMachineDevices")

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

/// The machine the Return Devices to Mac window is for.
struct MachineDevicesRequest: Identifiable {
    let id = UUID()
    let machine: VMManager
}

struct USBPickerRequest: Identifiable {
    let id = UUID()
    let mode: USBDevicePickerView.Mode
    let devices: [AVMUSBDeviceIdentity]
    /// The machine it was opened for (2026-10-28, fourth audit): the device
    /// used to go to whichever machine was in front when Attach was pressed.
    weak var machine: VMManager?
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
    @State private var devicesWindow: MachineDevicesRequest? = nil
    @Environment(\.openWindow) private var openWindow
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
            .frame(minWidth: 760, minHeight: 560)
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
                // Said as well (2026-10-28, fourth audit): with VoiceOver off,
                // or focus elsewhere, the beep was all there was.
                if let message = errorMessage { Announcer.shared.announce(message, tone: .info) }
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
            // The list wasn't readable at launch (2026-10-28, fifth audit):
            // AVM didn't look, so it mustn't say it found nothing.
            if vmStore.reclaimIsOff {
                Announcer.shared.announce("AVM couldn't read your list of virtual machines when it opened, so Reclaim Disk Space is off until that's fixed. Next: report the problem from the Help menu.", tone: .failure)
                return
            }
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
            usbPicker = USBPickerRequest(mode: .attach, devices: devices, machine: VMManager.shared)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avmMachineDevices)) { _ in
            // Paused too, as Bluetooth Devices: QEMU lets devices go with the
            // vCPUs stopped.
            guard let manager = VMManager.shared, manager.state == .running || manager.state == .paused else {
                Announcer.shared.announce("The virtual machine is not running, so it has no devices from the Mac.", tone: .info)
                return
            }
            guard MachineDevicesView.hasDevices(manager) else {
                Announcer.shared.announce("No devices are in \(manager.machineName).", tone: .info)
                return
            }
            devicesWindow = MachineDevicesRequest(machine: manager)
        }
        .sheet(item: $devicesWindow) { request in
            MachineDevicesView(machine: request.machine)
        }
        .sheet(item: $usbPicker) { request in
            USBDevicePickerView(mode: request.mode, devices: request.devices, machine: request.machine)
        }
        .onReceive(NotificationCenter.default.publisher(for: .avmBluetoothDevices)) { _ in
            // Paused too (2026-10-28, fifth audit): Return to Mac is in
            // this window, and a device in a paused machine couldn't be got
            // back any other way.
            guard let manager = VMManager.shared, manager.state == .running || manager.state == .paused else {
                Announcer.shared.announce("The virtual machine is not running. Start it, then send a Bluetooth device.", tone: .failure)
                return
            }
            bluetoothWindow = BluetoothWindowRequest(machine: manager)
        }
        .sheet(item: $bluetoothWindow) { request in
            BluetoothDevicesView(machine: request.machine)
        }
        // The machine chosen to start when AVM opens (2026-10-28), once.
        .onAppear {
            MainWindowCloseGuard.openMainWindow = { openWindow(id: "main") }
            // Menu commands chosen while there was no dashboard (2026-10-28).
            DashboardCommand.deliverPending()
            BackgroundMode.shared.autoStartIfChosen(in: vmStore.configurations) { startVM(config: $0, takesKeyboard: $1) }
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
        DashboardStatus.spoken(store: vmStore, machines: machines, focusLock: focusLock)
    }

    /// Same start path as the dashboard's per-VM Start button (see
    /// DashboardContent.startVM). `takesKeyboard` false: the machine's
    /// window opens without taking the Mac's keyboard (a machine started
    /// when AVM opens that has a keyboard for Windows, 2026-10-28).
    private func startVM(config: VMConfiguration, takesKeyboard: Bool = true) {
        // Not while its files are being copied (2026-10-26).
        if MachineArchiveController.shared.refusesWhileBusy(config) { return }
        // Never a template (2026-10-28, fourth audit): the Start menu and
        // Command-Shift-S started one, and every machine made from it later
        // inherited what it did.
        if config.isATemplate {
            Announcer.shared.announce("\(config.name) is a template, so it isn't started. Use New Machine from Template to make a machine from it.", tone: .info)
            return
        }
        errorMessage = nil
        // macOS runs on Apple's Virtualization framework, in its own window
        // (MacGuest.swift), not in a QEMU session.
        if config.guestOS == .macOS {
            MacGuestRunner.shared.start(config)
            return
        }
        MachineSessions.shared.start(config, vmStore: vmStore, focusLock: focusLock, windowless: config.startsWithoutWindow, takesKeyboard: takesKeyboard)
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
///   THE TABLE (2026-10-30, the user's request): the machines are now one
///   real table (MachineTableView, an NSTableView), a row each with Name,
///   Status, System, Cores, Memory, Disk and Drive, which VoiceOver reads
///   as a table. The chosen
///   machine's name is the h2, above its buttons, below the table; the
///   per-machine headings are gone with the per-machine rows.
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
    @ObservedObject private var background = BackgroundMode.shared
    @Binding var errorMessage: String?
    @Binding var showingSetup: Bool
    @Binding var settingsTarget: VMConfiguration?
    /// The machine chosen in the table, whose buttons are below it.
    @State private var selectedID: VMConfiguration.ID?
    /// Counts running machines' changes, so the table redraws for them.
    @State private var sessionChanges = 0

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

                    machineTable

                    // The chosen machine's buttons, below the table.
                    if let config = selectedConfiguration {
                        VStack(alignment: .leading, spacing: 6) {
                            // Not the name again (2026-10-30): the table's
                            // names are the machines' headings now.
                            Text(config.name)
                                .font(.body)
                                .accessibilityLabel("Controls for \(config.name)")
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityHeading(.h3)
                            Text(specLine(config))
                                .font(.caption)
                                .foregroundStyle(config.storageIsMissing ? Color.red : Color.secondary)
                                .accessibilityLabel(spokenSpecs(config))
                            FlowLayout(spacing: 8, lineSpacing: 6) {
                                machineControls(config)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal)
                .onAppear { keepSelection() }
                .onChange(of: vmStore.configurations.map(\.id)) { _ in keepSelection() }
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
                // AVM's own Settings (2026-10-30, AppPreferencesView.swift),
                // where Background and Startup now is. Command-Comma is the
                // AVM menu's Settings item.
                Button("AVM Settings…") {
                    AppPreferences.open()
                }
                .accessibilityHint("Updates, opening AVM at login, running in the background, the Caps Lock key and the USB helper. Command-Comma.")

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
                    // Named (2026-10-28, fifth audit): with two machines
                    // running, which one this opened was anyone's guess.
                    Button("Settings for \(vmStore.configurations.first { $0.id == current.configuration.id }?.name ?? current.configuration.name)") {
                        settingsTarget = current.configuration
                    }
                    .accessibilityHint("Opens this virtual machine's settings. Command-Option-Comma.")
                    // Command-Option-Comma (2026-10-30): Command-Comma is
                    // AVM's own Settings now, as in every Mac app.
                    .keyboardShortcut(",", modifiers: [.command, .option])
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

    // MARK: - The table of machines (2026-10-30)

    /// Every machine, a row each, in a real table (the user's request):
    /// MachineTableView, which VoiceOver reads as one, "Virtual machines,
    /// table", each cell with its column's name. Return or a double-click
    /// starts the chosen machine, or enters it when it's running; its other
    /// actions are in its context menu (VO-Shift-M), and all of them are
    /// buttons below the table.
    private var machineTable: some View {
        _ = sessionChanges   // redrawn as running machines change
        let rows = vmStore.configurations.map(tableRow)
        return MachineTableView(rows: rows, selection: $selectedID,
                                primaryAction: { id in configuration(id).map(primaryAction) },
                                menuItems: { id in configuration(id).map(tableMenu) ?? [] })
            // Tall enough for every row, up to ten; more scroll in the table.
            .frame(height: CGFloat(min(max(rows.count, 1), 10)) * MachineTableView.rowHeight + 32)
            // A running machine's state redraws the table (its row's Status),
            // as the rows below observe theirs. Its state only (2026-10-30
            // cleanup): every change to a session, its console text
            // included, redrew the dashboard and read each machine's files.
            .onReceive(Publishers.MergeMany(machines.sessions.values.map { $0.$vmState.removeDuplicates().dropFirst() })
                .receive(on: RunLoop.main)) { _ in
                sessionChanges &+= 1
            }
    }

    private func configuration(_ id: UUID) -> VMConfiguration? {
        vmStore.configurations.first { $0.id == id }
    }

    private func tableRow(_ config: VMConfiguration) -> MachineTableRow {
        let status: String
        if config.guestOS == .macOS {
            status = macStatus(config)
        } else if let session = machines.session(for: config.id) {
            status = QEMUMachineRow.status(of: session, name: config.name,
                                           keyboardIn: focusLock.isLocked && machines.currentID == config.id)
        } else {
            status = stoppedStatus(config)
        }
        let drive = storageNote(config) ?? "This Mac"
        return MachineTableRow(
            id: config.id,
            // "GB" shown, as seven columns share the dashboard's width;
            // "gigabytes" said (2026-10-30, TableLabelCell), as VoiceOver
            // reads "GB" unreliably.
            cells: [config.name, status, config.guestOS.displayName, "\(config.cpuCount)",
                    "\(config.ramSizeGB) GB", "\(config.diskSizeGB) GB", drive],
            spoken: [4: "\(config.ramSizeGB) gigabytes", 5: "\(config.diskSizeGB) gigabytes"],
            warning: config.storageIsMissing)
    }

    private var selectedConfiguration: VMConfiguration? {
        vmStore.configurations.first { $0.id == selectedID }
    }

    /// One always chosen, so the buttons below are never empty: the first
    /// machine at first, and again when the chosen one is deleted.
    private func keepSelection() {
        if selectedID == nil || !vmStore.configurations.contains(where: { $0.id == selectedID }) {
            selectedID = vmStore.configurations.first?.id
        }
    }

    private func stoppedStatus(_ config: VMConfiguration) -> String {
        if config.isATemplate { return "Template" }
        if QEMUSavedState.looksSaved(config) { return "Saved" }
        return "Shut down"
    }

    private func specLine(_ config: VMConfiguration) -> String {
        "\(config.guestOS.displayName) · \(config.cpuCount) cores · \(config.ramSizeGB) GB RAM · \(config.diskSizeGB) GB disk\(storageNote(config).map { " · \($0)" } ?? "")"
    }

    private func spokenSpecs(_ config: VMConfiguration) -> String {
        "\(config.guestOS.displayName), \(config.cpuCount) cores, \(config.ramSizeGB) gigabytes RAM, \(config.diskSizeGB) gigabytes disk\(storageNote(config).map { ", \($0)" } ?? "")"
    }

    /// Return or a double-click in the table: Enter when it's running,
    /// Start when it's shut down; nothing while it starts or stops, or for
    /// a template, which says what to do instead.
    private func primaryAction(_ config: VMConfiguration) {
        if config.guestOS == .macOS {
            if macGuest.runningID == config.id { macGuest.enter() } else { startVM(config: config) }
            return
        }
        if let session = machines.session(for: config.id) {
            if session.isRunningOrPaused {
                MachineSessions.shared.enter(config.id)
            } else {
                Announcer.shared.announce("\(config.name) is \(session.vmState == .starting ? "starting" : "shutting down").", tone: .info)
            }
            return
        }
        startVM(config: config)
    }

    /// The row's context menu: the common actions; every one is a button
    /// below the table too. A nil title is a separator.
    private func tableMenu(_ config: VMConfiguration) -> [MachineMenuItem] {
        var items: [MachineMenuItem] = []
        let session = config.guestOS == .macOS ? nil : machines.session(for: config.id)
        let running = config.guestOS == .macOS ? macGuest.runningID == config.id
            : session?.isRunningOrPaused ?? false
        if running {
            items.append(MachineMenuItem("Enter \(config.name)") { primaryAction(config) })
        } else if session == nil, !config.isATemplate {
            items.append(MachineMenuItem("Start \(config.name)") { primaryAction(config) })
        }
        items.append(MachineMenuItem("Settings for \(config.name)") { openSettings(config) })
        if running, config.guestOS == .macOS {
            items.append(MachineMenuItem("Shut Down \(config.name)") { macGuest.shutDown() })
        } else if running, let session, !session.isSaving {
            items.append(MachineMenuItem("Shut Down \(config.name)") {
                QEMUMachineRow.shutDown(session, name: config.name) { errorMessage = $0 }
            })
        }
        if !running, session == nil {
            items.append(.separator)
            items.append(MachineMenuItem(config.isATemplate ? "New Machine from \(config.name)…" : "Duplicate \(config.name)…") {
                MachineArchiveController.shared.duplicate(config, isRunning: false, into: vmStore)
            })
            items.append(MachineMenuItem("Export \(config.name)…") { MachineArchiveController.shared.export(config, isRunning: false) })
            items.append(.separator)
            items.append(MachineMenuItem("Delete \(config.name)…") { confirmDelete(config: config) })
        }
        return items
    }

    /// The chosen machine's buttons, as its row had them before the table.
    @ViewBuilder
    private func machineControls(_ config: VMConfiguration) -> some View {
        // macOS machines run beside QEMU, in their own window (2026-10-26):
        // their row says how they are and runs them.
        if config.guestOS == .macOS {
            macRowControls(config)
        } else if let session = machines.session(for: config.id) {
            // The saved name and a Settings button (2026-10-29, sixth audit):
            // a machine renamed while running kept its old name on its row,
            // and a running machine that wasn't the current one had no way to
            // its Settings.
            QEMUMachineRow(session: session, errorMessage: $errorMessage, savedName: config.name,
                           isTemplate: config.isATemplate, openSettings: { openSettings(config) })
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

            if !config.isATemplate {
                autoStartToggle(config)
            }
            exportButton(config)
            duplicateButton(config)

            Button("Delete") {
                confirmDelete(config: config)
            }
            .accessibilityLabel("Delete \(config.name)")
            .accessibilityHint("Moves this virtual machine and all of its files to the Trash. Asks for confirmation first.")
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
        // A macOS machine counts too (2026-10-28, fourth audit), and only
        // machines that are running, not starting or stopping.
        let running = machines.sessions.values.filter { $0.vmState == .running || $0.vmState == .paused }.count
            + (MacGuestRunner.shared.runningID == nil ? 0 : 1)
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
            // Started under the question (2026-10-29, sixth audit): avmctl can
            // start it while the alert is open.
            if machines.session(for: config.id).map({ $0.vmState != .stopped }) ?? false || macGuest.runningID == config.id {
                Announcer.shared.announce("\(config.name) started while you were asked, so it was not deleted. Shut it down first.", tone: .failure)
                return
            }
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
                // Not dimmed with no reason (2026-10-29, sixth audit): with
                // another macOS machine running, Start says why it can't.
                Button("Start") { startVM(config: config) }
                    .accessibilityLabel("Start \(config.name)")
                    .accessibilityHint(macGuest.runningID != nil
                        ? "Another macOS machine is running; one macOS machine runs at a time"
                        : "Starts this macOS virtual machine in its own window")
                autoStartToggle(config)
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

    // MARK: Start when AVM opens (2026-10-28, BackgroundMode.swift)

    private func autoStartToggle(_ config: VMConfiguration) -> some View {
        Toggle("Start When AVM Opens", isOn: Binding(
            get: { background.autoStartID == config.id },
            set: { BackgroundMode.shared.setAutoStart(config, $0) }))
        .lineLimit(1)
        .fixedSize()
        .accessibilityLabel("Start \(config.name) when AVM opens")
        .accessibilityHint("One machine at most. With Open AVM When You Log In, in AVM Settings, it starts when you log in.")
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
        if config.isATemplate {
            Announcer.shared.announce("\(config.name) is a template, so it isn't started. Use New Machine from Template to make a machine from it.", tone: .info)
            return
        }
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
    let savedName: String
    /// A template isn't saved with open apps (2026-10-29, seventh audit):
    /// saved, nothing could start or copy it.
    let isTemplate: Bool
    let openSettings: () -> Void
    @EnvironmentObject var focusLock: FocusLockManager
    @ObservedObject private var machines = MachineSessions.shared

    private var name: String { savedName }

    private var status: String {
        Self.status(of: session, name: name, keyboardIn: focusLock.isLocked && machines.currentID == session.configuration.id)
    }

    /// Also the table's Status column.
    static func status(of session: VMSession, name: String, keyboardIn: Bool) -> String {
        switch session.vmState {
        case .starting: return "Starting"
        case .running: return keyboardIn ? "Running, keyboard in \(name)" : "Running"
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
            Button("Return Devices to Mac…") {
                MachineSessions.shared.makeCurrent(session.configuration.id)
                NotificationCenter.default.post(name: .avmMachineDevices, object: nil)
            }
            .accessibilityLabel("Return devices in \(name) to the Mac")
            .accessibilityHint("Lists the USB and Bluetooth devices in \(name), each with a button to give it back. Command Shift M.")
        }
        // Not during a save (sixth audit): pausing in the middle of one.
        if session.vmState == .running, !session.isSaving {
            Button("Pause") {
                Task {
                    // Said either way (2026-10-28, fourth audit): the button
                    // went away and nothing was said.
                    do {
                        try await session.pause()
                        Announcer.shared.announce("\(name) is paused.", tone: .info)
                    } catch {
                        errorMessage = error.localizedDescription
                        Announcer.shared.announce("\(name) couldn't be paused. Reason: \(error.localizedDescription)", tone: .failure)
                    }
                }
            }
            .accessibilityLabel("Pause \(name)")
        }
        if session.vmState == .paused {
            Button("Resume") {
                Task {
                    do {
                        try await session.resume()
                        Announcer.shared.announce("\(name) is running again.", tone: .success)
                    } catch {
                        errorMessage = error.localizedDescription
                        Announcer.shared.announce("\(name) couldn't be resumed. Reason: \(error.localizedDescription)", tone: .failure)
                    }
                }
            }
            .accessibilityLabel("Resume \(name)")
            // A paused machine's devices too (sixth audit): its window
            // opens for them, but the row had no way to it.
            Button("Bluetooth Devices…") {
                MachineSessions.shared.makeCurrent(session.configuration.id)
                NotificationCenter.default.post(name: .avmBluetoothDevices, object: nil)
            }
            .accessibilityLabel("Bluetooth devices for \(name)")
            .accessibilityHint("Lists the Bluetooth devices sent to \(name). Command Shift B.")
            Button("Return Devices to Mac…") {
                MachineSessions.shared.makeCurrent(session.configuration.id)
                NotificationCenter.default.post(name: .avmMachineDevices, object: nil)
            }
            .accessibilityLabel("Return devices in \(name) to the Mac")
            .accessibilityHint("Lists the USB and Bluetooth devices in \(name), each with a button to give it back. Command Shift M.")
        }
        if session.vmState == .running || session.vmState == .paused {
            Button("Settings") { openSettings() }
                .accessibilityLabel("Settings for \(name)")
                .accessibilityHint("Opens settings for this virtual machine. Some settings change only while it's shut down.")
        }
        if session.canSave, !isTemplate {
            Button("Save") { Task { await session.saveAndStop() } }
                .accessibilityLabel("Save \(name)")
                .accessibilityHint("Keeps it as it is, open apps and all, and stops it. The next Start carries on from there in seconds.")
            Button("Save Restore Point…") { askRestorePointName(session) }
                .accessibilityLabel("Save a restore point for \(name)")
                .accessibilityHint("Saves it as it is now, open apps and all, as a restore point you can go back to from Settings. It keeps running.")
        }
        // Not during a save (2026-10-28, fifth audit): the power-off landed
        // between the snapshot and QEMU's quit.
        if session.vmState == .running || session.vmState == .paused, !session.isSaving {
            Button("Shut Down") { shutDown() }
                .accessibilityLabel("Shut down \(name)")
        }
        // Force Stop while shutting down too (2026-10-25, code audit): a
        // guest that ignores the power button would otherwise leave nothing
        // to press. Asks first, Cancel the default.
        // And while starting (2026-10-28, fourth audit): a slow first start,
        // building the install media, had no button and no menu item.
        if session.vmState == .running || session.vmState == .paused || session.vmState == .stopping || session.vmState == .starting {
            Button("Force Stop") {
                let wasStarting = session.vmState == .starting
                if confirmForceStop(guest: name) {
                    // Finished starting under the question (2026-10-28, fifth
                    // audit): its window came up and took the keyboard while
                    // the alert was read, and a Force Stop now would kill the
                    // machine the user was just put into.
                    if wasStarting, session.vmState == .running {
                        Announcer.shared.announce("\(name) finished starting while you were asked. It's running; use Force Stop again if you still want to turn it off.", tone: .info)
                        return
                    }
                    // Stopped, or started again, under the question (sixth
                    // audit): the old machine's clean-up then removed the new
                    // session's sockets.
                    let stoppedMeanwhile: Bool = {
                        if case .error = session.vmState { return true }
                        return session.vmState == .stopped
                    }()
                    if stoppedMeanwhile || MachineSessions.shared.session(for: session.configuration.id) !== session {
                        Announcer.shared.announce("\(name) stopped while you were asked, so there was nothing to turn off.", tone: .info)
                        return
                    }
                    session.forceStop()
                    Announcer.shared.announce("\(name) was turned off.", tone: .info)
                }
            }
            .accessibilityLabel("Force stop \(name)")
            .accessibilityHint("Turns it off at once, without shutting down. Asks first.")
        }
    }

    private func shutDown() {
        Self.shutDown(session, name: name) { errorMessage = $0 }
    }

    /// Also the table's menu (2026-10-30 cleanup: its own copy had drifted).
    static func shutDown(_ session: VMSession, name: String, failed: @escaping (String) -> Void) {
        Task {
            // stopGracefully waits until the machine has shut down, so its
            // session stays alive the whole time (fixed 2026-09-27); the
            // session ends when it stops (MachineSessions).
            do {
                try await session.stopGracefully()
            } catch {
                failed(error.localizedDescription)
                Announcer.shared.announce(
                    "\(name) could not be shut down. Reason: \(error.localizedDescription.hasSuffix(".") ? String(error.localizedDescription.dropLast()) : error.localizedDescription). Next: try Shut Down again, or use Force Stop.",
                    tone: .failure
                )
            }
        }
    }
}

// MARK: - The dashboard's table (2026-10-30)

/// One machine's row: what each column shows, which VoiceOver reads, and
/// by column what it says instead where the two differ.
struct MachineTableRow: Equatable {
    let id: UUID
    let cells: [String]
    var spoken: [Int: String] = [:]
    /// Its drive isn't connected: the Drive cell is red.
    let warning: Bool
}

/// An item in a row's context menu; a separator has no title.
struct MachineMenuItem {
    let title: String?
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    private init() { title = nil; action = {} }
    static let separator = MachineMenuItem()
}

/// The dashboard's machines in an NSTableView (2026-10-30, the user's
/// request for a real table). SwiftUI's Table was tried first: VoiceOver
/// met it as an outline, with every cell "dimmed". This one is a table,
/// "Virtual machines, table", with a header VoiceOver reads for each cell,
/// rows by VO-Up and VO-Down and cells by VO-Left and VO-Right. Return or a
/// double-click is the row's main action; its menu (VO-Shift-M, or a
/// right-click) has the rest.
struct MachineTableView: NSViewRepresentable {
    static let columns = ["Name", "Status", "System", "Cores", "Memory", "Disk", "Drive"]
    /// Each column's share of the table's width (FittingScrollView).
    static let widths: [CGFloat] = [150, 140, 90, 50, 70, 75, 95]
    static let rowHeight: CGFloat = 24

    var rows: [MachineTableRow]
    @Binding var selection: UUID?
    var primaryAction: (UUID) -> Void
    var menuItems: (UUID) -> [MachineMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ReturnKeyTableView()
        for (index, title) in Self.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column\(index)"))
            column.title = title
            column.width = Self.widths[index]
            column.minWidth = 50
            table.addTableColumn(column)
        }
        table.rowHeight = Self.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .fullWidth
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.activateSelected() }
        context.coordinator.table = table
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityLabel("Virtual machines")
        let scroll = FittingScrollView()
        scroll.shares = Self.widths
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        if coordinator.rows != rows {
            coordinator.rows = rows
            table.reloadData()
        }
        if let index = rows.firstIndex(where: { $0.id == selection }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MachineTableView
        var rows: [MachineTableRow] = []
        weak var table: NSTableView?

        init(_ parent: MachineTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn), row < rows.count else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = tableColumn.identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.translatesAutoresizingMaskIntoConstraints = false
                // Each machine's name a heading (2026-10-30, a tester: with
                // headings there, a VoiceOver user goes by them first), so
                // VO-Command-H goes machine to machine in the table too;
                // VO-Space on one chooses it.
                // Set on its cell: a label's accessibility is its cell's, and
                // a role or value set on the field itself didn't reach VoiceOver.
                let label = TableLabelCell(textCell: "")
                label.isEditable = false
                label.isSelectable = false
                label.isHeading = column == 0
                field.cell = label
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let item = rows[row]
            cell.textField?.stringValue = item.cells[column]
            (cell.textField?.cell as? TableLabelCell)?.spoken = item.spoken[column]
            cell.textField?.textColor = item.warning && column == MachineTableView.columns.count - 1 ? .systemRed : .labelColor
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
            let id = rows[table.selectedRow].id
            // Not during SwiftUI's own update of the view.
            DispatchQueue.main.async { if self.parent.selection != id { self.parent.selection = id } }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0, sender.clickedRow < rows.count else { return }
            parent.primaryAction(rows[sender.clickedRow].id)
        }

        func activateSelected() {
            guard let table, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
            parent.primaryAction(rows[table.selectedRow].id)
        }

        /// Built as it opens, for the row clicked, or the chosen one when
        /// VoiceOver opened it from the keyboard.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard row >= 0, row < rows.count else { return }
            for item in parent.menuItems(rows[row].id) {
                guard let title = item.title else { menu.addItem(.separator()); continue }
                let menuItem = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = ActionBox(item.action)
                menu.addItem(menuItem)
            }
        }

        @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? ActionBox)?.action() }
    }

    final class ActionBox: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}

/// Fits the table's columns to its width, in their shares, whenever it's
/// laid out, so no column runs off the edge or is cut to a letter.
final class FittingScrollView: NSScrollView {
    /// Each column's share of the width, in the table's column order.
    var shares: [CGFloat] = []

    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView, !shares.isEmpty else { return }
        let width = contentSize.width - table.intercellSpacing.width * CGFloat(table.tableColumns.count)
        let total = shares.reduce(0, +)
        guard width > 0, total > 0 else { return }
        for (column, share) in zip(table.tableColumns, shares) {
            let fitted = max((width * share / total).rounded(.down), column.minWidth)
            if abs(column.width - fitted) >= 1 { column.width = fitted }
        }
    }
}

/// A table label as VoiceOver should meet it: a heading for a machine's
/// name, and the words to say where they differ from those shown.
final class TableLabelCell: NSTextFieldCell {
    var isHeading = false
    var spoken: String?

    override func accessibilityRole() -> NSAccessibility.Role? {
        isHeading ? NSAccessibility.Role(rawValue: "AXHeading") : super.accessibilityRole()
    }
    /// A heading's words are its label; a label's text was its value.
    override func accessibilityLabel() -> String? { isHeading ? stringValue : super.accessibilityLabel() }
    override func accessibilityValue() -> Any? { spoken ?? super.accessibilityValue() }
}

/// Return is the row's main action, as a double-click is.
final class ReturnKeyTableView: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), selectedRow >= 0 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Send a file (2026-10-27)

/// Asks which file, then sends it into the machine's Downloads
/// (VMManager.sendFile). Spoken.
@MainActor
func chooseFileToSend(_ session: VMSession) {
    let panel = NSOpenPanel()
    let machine = VMStore.shared?.configurations.first { $0.id == session.configuration.id }?.name ?? session.configuration.name
    panel.title = "Send a File to \(machine)"
    panel.message = "Choose a file. It goes into Downloads in \(machine)."
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
    alert.messageText = "Save a restore point for \(VMStore.shared?.configurations.first { $0.id == session.configuration.id }?.name ?? session.configuration.name)?"
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

/// Lays its views out left to right, wrapping onto more lines as needed
/// (2026-10-28, fourth audit): a running machine's row, nine buttons in one
/// line of fixed width, ran off the window, and Shut Down and Force Stop
/// couldn't be clicked. VoiceOver reads them in the same order.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// The Speak Status line, from the dashboard or without one (2026-10-28,
/// fifth audit: DashboardCommand answers it when there's no dashboard to
/// open, as with only a machine's window up).
@MainActor
enum DashboardStatus {
    static func spoken() -> String {
        guard let store = VMStore.shared, let focusLock = FocusLockManager.shared else { return "AVM is still opening." }
        return spoken(store: store, machines: MachineSessions.shared, focusLock: focusLock)
    }

    static func spoken(store vmStore: VMStore, machines: MachineSessions, focusLock: FocusLockManager) -> String {
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
                // A template isn't started (2026-10-29, sixth audit).
                let only = vmStore.configurations[0]
                return only.isATemplate
                    ? "No virtual machine is running. \(only.name) is a template; use New Machine from Template to make one from it."
                    : "No virtual machine is running. \(only.name) is ready to start."
            case let n:
                return "No virtual machine is running. \(n) virtual machines are set up."
            }
        }

        var parts: [String] = macPart.map { [$0] } ?? []
        for session in running {
            // The saved name (2026-10-29, seventh audit): a machine renamed
            // while running kept its old one here.
            let name = VMStore.shared?.configurations.first { $0.id == session.configuration.id }?.name ?? session.configuration.name
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
}
