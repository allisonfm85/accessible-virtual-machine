// SettingsView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import AppKit

/// Settings for one virtual machine, running or stopped.
///
/// OPENED FROM A CONFIGURATION (2026-09-26): this view used to take a running
/// VMSession, so Settings existed only while a VM was started. With the VM
/// stopped there was no way in at all. It now takes the saved configuration
/// plus whether that VM is running. ContentView offers it from each stopped
/// VM's row and from the running VM's Settings button.
///
/// HONEST CONTROLS (2026-09-26): every control here must do what it says.
///   - Name, CPU cores, memory: saved, and read by VMManager at the next start.
///   - Disk size: grows the real disk with qemu-img (VMManager.growDiskImage),
///     stopped VMs only, verified before the new size is saved. Before this,
///     the stepper saved a number and nothing resized the disk, so the
///     dashboard showed a size that was not true.
///   - USB (increment 2b): plug-in mode and remembered devices, saved with
///     the configuration. "USB changes apply right away" holds only because
///     the hot-plug watcher reads the SAVED configuration at each plug-in,
///     never a copy taken when the VM started. Keep it that way.
///   - Shared folder: REMOVED. Nothing in AVM ever read it, so choosing a
///     folder "saved" and Windows never saw it. A path already saved stays in
///     the configuration, untouched, for when the feature exists.
struct SettingsView: View {

    // MARK: - Environment

    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss

    // MARK: - Input

    let configuration: VMConfiguration

    /// This VM's SAVED configuration, read from VMStore each time it's needed.
    /// `configuration` is the copy handed over when the sheet opened, and it
    /// can be older than what is saved. Reading the copy made Settings show
    /// "Ask each time" after the USB choice had been saved as something else
    /// (found 2026-10-11), and a save that started from the copy could write
    /// old values back. Falls back to the copy only if the VM is not in the
    /// store.
    private var saved: VMConfiguration {
        vmStore.configurations.first(where: { $0.id == configuration.id }) ?? configuration
    }
    /// True only when this VM is the one currently running.
    let isRunning: Bool

    // MARK: - Focus

    @AccessibilityFocusState private var isFirstFieldFocused: Bool

    // MARK: - System Limits

    private var maxCPUCount: Int {
        ProcessInfo.processInfo.processorCount / 2
    }

    private var maxMemoryInGB: Int {
        let totalGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        return max(4, totalGB / 2)
    }

    /// Free space on the Mac minus 20 GB (the rule the Setup Wizard also uses).
    private var maxDiskInGB: Int {
        // The drive the VM is on (2026-10-25, code audit), not always the
        // Mac's own disk: an external drive can be much fuller or emptier.
        let fileURL = configuration.storageIsMissing
            ? URL(fileURLWithPath: NSHomeDirectory())
            : ((try? configuration.directoryURL()) ?? URL(fileURLWithPath: NSHomeDirectory()))
        if let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            // What fits: the disk as it is plus the free space, less 20 GB
            // for the Mac (2026-10-26, code audit: a floor of 40 let it grow
            // past the free space). The disk already holds its own size at
            // most, so growing to this never needs more than is free.
            return saved.diskSizeGB + max(0, available / (1024 * 1024 * 1024) - 20)
        }
        return 500
    }

    /// Disks grow but never shrink, so the stepper starts at the current size.
    private var currentDiskGB: Int { saved.diskSizeGB }

    /// Never below the current size: free space can drop under it, and a
    /// stepper range whose top is below its bottom is invalid.
    private var diskGrowthCeilingGB: Int { max(currentDiskGB, maxDiskInGB) }

    /// "Windows" or "Ubuntu".
    private var guest: String { configuration.guestOS.displayName }

    /// What the user does inside the guest after the disk grows. Windows
    /// has drive C extended by hand (the README explains how); Ubuntu's
    /// main partition has to be made larger in the same way.
    private var diskGrowthFollowUp: String {
        configuration.guestOS.isLinux
            ? "After it grows, make \(configuration.guestOS.displayName)'s main partition larger to use the new space."
            : "After it grows, extend drive C inside Windows to use the new space."
    }

    private func savedDiskMessage(_ growTo: Int) -> String {
        configuration.guestOS.isLinux
            ? "Settings saved. The disk is now \(growTo) GB. The next time you start \(configuration.guestOS.displayName), make its main partition larger to use the new space."
            : "Settings saved. The disk is now \(growTo) GB. The next time you start Windows, extend drive C to use the new space. The README explains how."
    }

    /// When CPU and memory changes land, worded for this VM's state.
    private var timingSentence: String {
        isRunning
            ? "Changes take effect after restarting \(guest)."
            : "Changes take effect the next time you start \(guest)."
    }

    // MARK: - State

    @State private var vmName: String = ""
    @State private var cpuCount: Int = 4
    @State private var ramSizeGB: Int = 8
    @State private var diskSizeGB: Int = 64
    @State private var validationErrors: [String] = []
    @State private var isSaving = false
    @State private var saveMessage: String? = nil
    @State private var usbMode: USBPlugMode = .ask
    @State private var rememberedDevices: [RememberedUSBDevice] = []
    /// The list as it was when the sheet opened, to tell whether the user
    /// changed it here.
    @State private var rememberedDevicesAtOpen: [RememberedUSBDevice] = []
    @State private var secureBoot = false
    @State private var shareClipboard = true
    @State private var sharedFolderPath: String?
    @State private var sharedFolderReadOnly = false
    @State private var brailleFollowsBack = true
    @State private var lowAudioLatency = false
    @State private var restorePoints: [RestorePoint] = []
    @State private var restorePointsBusy = false
    @State private var restorePointsLoaded = false

    // MARK: - Body

    var body: some View {
        // Scrolls (2026-10-25): the window has grown past small screens.
        ScrollView {
        VStack(spacing: 24) {
            Text("Settings")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 20) {

                // VM Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Virtual Machine Name")
                        .font(.headline)
                    TextField("Virtual machine name", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Virtual machine name")
                        .accessibilityHint("The name used to identify this virtual machine")
                        .accessibilityFocused($isFirstFieldFocused)
                }

                // CPU Count
                VStack(alignment: .leading, spacing: 6) {
                    Text("CPU Cores: \(cpuCount)")
                        .font(.headline)
                        .accessibilityLabel("CPU cores: \(cpuCount)")
                    // Labelled once (2026-10-26, accessibility audit): SwiftUI
                    // speaks a stepper's hidden title and then its
                    // accessibilityLabel, which made "CPU Cores, CPU cores";
                    // the label is now the title. accessibilityValue went:
                    // SwiftUI on macOS doesn't pass it on for a stepper, which
                    // VoiceOver reads as its number, so the unit is in the label.
                    Stepper(value: $cpuCount, in: 2...maxCPUCount) { Text("CPU cores") }
                        .labelsHidden()
                        .accessibilityHint("Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount). \(timingSentence)")
                }

                // Memory
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory: \(ramSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
                    Stepper(value: $ramSizeGB, in: 4...maxMemoryInGB, step: 2) { Text("Memory in gigabytes") }
                        .labelsHidden()
                        .accessibilityHint("Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB. \(timingSentence)")
                }

                // Disk Size: grow only, stopped VMs only.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disk Size: \(diskSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Disk size: \(diskSizeGB) gigabytes")
                    if isRunning {
                        Text("Stop \(guest) to make the disk larger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if diskGrowthCeilingGB <= currentDiskGB {
                        Text("There isn't enough free space on your Mac to make the disk larger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Stepper(value: $diskSizeGB, in: currentDiskGB...diskGrowthCeilingGB, step: 10) { Text("Disk size in gigabytes") }
                            .labelsHidden()
                            .accessibilityHint("Adjust with arrow keys. The disk can grow but never shrink. Minimum \(currentDiskGB) GB, maximum \(diskGrowthCeilingGB) GB. \(diskGrowthFollowUp)")
                    }
                }

                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)

            if !validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Error: \(error)")
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal)
            }

            // Clipboard (2026-10-25)
            VStack(alignment: .leading, spacing: 6) {
                Text("Clipboard")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Toggle("Share the clipboard with \(guest)", isOn: $shareClipboard)
                    .accessibilityHint("When on, text and images you copy on the Mac can be pasted in \(guest), and the other way round")
                Text("Copy on the Mac, enter \(guest), and paste. What you copy in \(guest) is ready to paste on the Mac straight away. AVM never records what's copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // Shared folder (Windows only, 2026-10-26)
            if configuration.guestOS == .windows {
                sharedFolderSection
            }

            // Keyboard for Windows (2026-10-26)
            if configuration.guestOS == .windows {
                windowsKeyboardSection
            }

            // Sound (2026-10-26)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sound")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Toggle("Shorter speech delay (experimental)", isOn: $lowAudioLatency)
                    .accessibilityHint("Keeps less sound waiting, so speech from \(guest) follows your keys more closely")
                Text("Keeps speech from falling behind during long sessions. If sound crackles, turn it off. Takes effect the next time \(guest) starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)

            // Secure Boot (Windows only)
            if configuration.guestOS == .windows {
                secureBootSection
            }

            // USB Devices
            usbSection

            // Restore Points (2026-10-25)
            restorePointsSection

            // Reinstall Windows (2026-10-26)
            if configuration.guestOS == .windows {
                reinstallSection
            }

            // Actions
            HStack(spacing: 16) {
                Button("Close") {
                    dismiss()
                }
                .accessibilityHint("Closes settings without saving")
                .keyboardShortcut(.escape, modifiers: [])

                Button(isSaving ? "Saving..." : "Save Settings") {
                    saveSettings()
                }
                .disabled(isSaving)
                .accessibilityLabel(isSaving ? "Saving, please wait" : "Save Settings")
                .accessibilityHint("Saves your changes.")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(32)
        }
        .frame(minWidth: 480, minHeight: 600)
        .onAppear {
            loadCurrentSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFirstFieldFocused = true
            }
        }
    }

    // MARK: - Restore Points Section (2026-10-25)

    /// Saving and using restore points (RestorePoints in VMStore.swift).
    /// Only while the VM is stopped, and not while its drive is missing.
    private var restorePointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore Points")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if isRunning {
                Text("Stop \(guest) to save or use a restore point.")
                    .foregroundStyle(.secondary)
            } else if saved.storageIsMissing {
                Text(saved.storageMissingMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text("A restore point saves this virtual machine as it is now, so you can put it back later, before a big update for example. Each one takes more disk space as \(guest) changes afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !restorePointsLoaded {
                    Text("Reading restore points…")
                } else if restorePoints.isEmpty {
                    Text("No restore points yet.")
                }
                ForEach(restorePoints) { point in
                    HStack {
                        Text("\(point.label), \(restorePointDate(point.date))")
                        Spacer()
                        Button("Restore") { restoreTo(point) }
                            .accessibilityLabel("Restore \(point.label)")
                            .accessibilityHint("Puts the virtual machine back as it was then. Asks first.")
                            .disabled(restorePointsBusy)
                        Button("Delete") { deleteRestorePoint(point) }
                            .accessibilityLabel("Delete restore point \(point.label)")
                            .accessibilityHint("Frees the disk space it uses. Asks first.")
                            .disabled(restorePointsBusy)
                    }
                }
                Button(restorePointsBusy ? "Working…" : "Save a Restore Point…") { saveRestorePoint() }
                    .disabled(restorePointsBusy)
                    .accessibilityHint("Saves the virtual machine as it is now, under a name you choose")
            }
        }
        .padding(.horizontal)
        .task { await loadRestorePoints() }
    }

    private func restorePointDate(_ date: Date) -> String {
        date.formatted(date: .long, time: .shortened)
    }

    private func loadRestorePoints() async {
        guard !isRunning, !saved.storageIsMissing,
              let dir = try? vmStore.vmDirectoryURL(for: saved),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("disk.qcow2").path) else {
            restorePointsLoaded = true
            return
        }
        restorePoints = (try? await RestorePoints.list(vmDirectory: dir)) ?? []
        restorePointsLoaded = true
    }

    private func saveRestorePoint() {
        let alert = NSAlert()
        alert.messageText = "Save a restore point for \(saved.name)?"
        alert.informativeText = "Give it a name you'll recognize, such as Before the October update."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = "Restore point from \(restorePointDate(Date()))"
        field.setAccessibilityLabel("Restore point name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.isEmpty ? "Restore point from \(restorePointDate(Date()))" : label
        guard let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        restorePointsBusy = true
        Announcer.shared.announce("Saving the restore point.", tone: .info)
        Task { @MainActor in
            do {
                _ = try await RestorePoints.create(vmDirectory: dir, label: name, secureBoot: saved.usesSecureBoot)
                await loadRestorePoints()
                Announcer.shared.announce("Restore point saved: \(name).", tone: .success)
            } catch {
                Announcer.shared.announce("The restore point was not saved. Reason: \(error.localizedDescription)", tone: .failure)
            }
            restorePointsBusy = false
        }
    }

    // MARK: - Keyboard for Windows (2026-10-26)

    @State private var windowsKeyboardID: String?
    @State private var windowsKeyboardName: String?
    @State private var windowsKeyboardAppleISO = false
    @State private var connectedKeyboards: [(id: String, name: String)] = []
    @State private var keyboardsMessage: String?

    private var windowsKeyboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard for Windows")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Choose a second keyboard, USB or Bluetooth, to type only into \(guest) while it runs, whichever app is in front. Your Mac's keyboard stays with the Mac and VoiceOver, so there's nothing to switch. Takes effect the next time \(guest) starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Keyboard for Windows", selection: $windowsKeyboardID) {
                Text("None: every keyboard types on the Mac").tag(String?.none)
                ForEach(connectedKeyboards, id: \.id) { keyboard in
                    Text(keyboard.name).tag(Optional(keyboard.id))
                }
                if let id = windowsKeyboardID, !connectedKeyboards.contains(where: { $0.id == id }) {
                    Text("\(windowsKeyboardName ?? "Keyboard") (not connected now)").tag(Optional(id))
                }
            }
            .onChange(of: windowsKeyboardID) { id in
                if let id, let keyboard = connectedKeyboards.first(where: { $0.id == id }) {
                    windowsKeyboardName = keyboard.name
                }
            }
            if windowsKeyboardID != nil {
                Toggle("It's an Apple keyboard with a § key (ISO)", isOn: $windowsKeyboardAppleISO)
                    .accessibilityHint("Swaps the § key and the ` key back, as macOS does for these keyboards. Leave off for other keyboards.")
            }
            HStack {
                Button("Look Again") { Task { await loadKeyboards() } }
                    .accessibilityHint("Lists the keyboards connected now. Wake a Bluetooth keyboard by pressing a key first.")
                if let keyboardsMessage {
                    Text(keyboardsMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal)
        .task { await loadKeyboards() }
    }

    private func loadKeyboards() async {
        switch await USBHelperClient.shared.listKeyboards() {
        case .success(let list):
            connectedKeyboards = list.compactMap { entry in
                guard (entry["builtIn"] as? NSNumber)?.boolValue != true,
                      let id = entry["id"] as? String else { return nil }
                return (id, entry["name"] as? String ?? "Keyboard")
            }
            keyboardsMessage = connectedKeyboards.isEmpty
                ? "No second keyboard is connected. Connect one, or wake it by pressing a key, then choose Look Again."
                : nil
        case .failure:
            connectedKeyboards = []
            keyboardsMessage = "AVM's helper didn't answer, so keyboards can't be listed. Allow it in System Settings, General, Login Items, then choose Look Again."
        }
    }

    // MARK: - Reinstall Windows (2026-10-26)

    @State private var reinstalling = false

    private var reinstallSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reinstall Windows")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(isRunning
                 ? "Stop \(guest) to reinstall it."
                 : "Erases Windows on this machine and installs it again at the next Start, from the same installer and with the same setup answers. A Fresh install restore point is quicker, if you have one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(reinstalling ? "Preparing…" : "Reinstall Windows…") { reinstallWindows() }
                .disabled(isRunning || reinstalling || saved.storageIsMissing)
                .accessibilityHint("Asks first. Everything in Windows on this machine is erased.")
        }
        .padding(.horizontal)
    }

    private func reinstallWindows() {
        let alert = NSAlert()
        alert.messageText = "Erase Windows on \(saved.name) and install it again?"
        alert.informativeText = "Everything in Windows on this machine is erased: files, apps, settings and restore points. When you next start it, Windows installs as it did the first time, from the same installer and with the same setup answers. This can't be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase and Reinstall")
        var passwordField: NSSecureTextField? = nil
        if WindowsReinstall.needsPassword(saved) {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.placeholderString = "Password"
            field.setAccessibilityLabel("Password for the Windows account \(WindowsReinstall.localUserName(saved) ?? "")")
            alert.accessoryView = field
            alert.informativeText += " Type the Windows account's password again below; leave it empty for no password."
            passwordField = field
            alert.window.initialFirstResponder = field
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        reinstalling = true
        let configuration = saved
        let password = passwordField?.stringValue
        Task { @MainActor in
            do {
                try await WindowsReinstall.prepare(configuration, password: password)
                restorePoints = []
                Announcer.shared.announce("\(configuration.name) is ready to reinstall. Choose Start, and Windows installs as it did the first time.", tone: .success)
            } catch {
                Announcer.shared.announce("\(configuration.name) was not reinstalled. Reason: \(error.localizedDescription)", tone: .failure)
            }
            reinstalling = false
        }
    }

    private func restoreTo(_ point: RestorePoint) {
        let alert = NSAlert()
        alert.messageText = "Put \(saved.name) back to \(point.label)?"
        alert.informativeText = "Everything since \(restorePointDate(point.date)) is lost: files, settings and installed updates. AVM keeps the restore point, so you can use it again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore")
        guard alert.runModal() == .alertSecondButtonReturn,
              let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        restorePointsBusy = true
        Task { @MainActor in
            do {
                try await RestorePoints.restore(point, vmDirectory: dir, currentSecureBoot: saved.usesSecureBoot)
                // The disk's size comes back with it, if it has grown since.
                var sizeNote = ""
                if let size = try? await RestorePoints.diskSizeGB(vmDirectory: dir), size > 0, size != saved.diskSizeGB {
                    var updated = saved
                    updated.diskSizeGB = size
                    vmStore.save(updated)
                    diskSizeGB = size
                    sizeNote = " Its disk is \(size) gigabytes again, as it was then."
                }
                Announcer.shared.announce("\(saved.name) is back to \(point.label).\(sizeNote) Start it when you're ready.", tone: .success)
            } catch {
                Announcer.shared.announce("\(saved.name) was not restored. Reason: \(error.localizedDescription)", tone: .failure)
            }
            restorePointsBusy = false
        }
    }

    private func deleteRestorePoint(_ point: RestorePoint) {
        let alert = NSAlert()
        alert.messageText = "Delete the restore point \(point.label)?"
        alert.informativeText = "This frees the disk space it uses. It can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn,
              let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        restorePointsBusy = true
        Task { @MainActor in
            do {
                try await RestorePoints.delete(point, vmDirectory: dir)
                await loadRestorePoints()
                Announcer.shared.announce("Restore point \(point.label) deleted.", tone: .success)
            } catch {
                Announcer.shared.announce("The restore point was not deleted. Reason: \(error.localizedDescription)", tone: .failure)
            }
            restorePointsBusy = false
        }
    }

    // MARK: - Shared Folder Section (2026-10-26)

    private var sharedFolderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shared Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(sharedFolderPath.map { "Sharing: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "No folder is shared.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(sharedFolderPath == nil ? "Choose Folder to Share…" : "Choose a Different Folder…") {
                    chooseSharedFolder()
                }
                .accessibilityHint("Picks a folder on the Mac that \(guest) can open")
                if sharedFolderPath != nil {
                    Button("Stop Sharing") {
                        sharedFolderPath = nil
                    }
                }
            }
            if sharedFolderPath != nil {
                Toggle("\(guest) can only read it, not change it", isOn: $sharedFolderReadOnly)
            }
            Text("\(guest) shows the folder in File Explorer as a network drive. Changes take effect the next time \(guest) starts. Windows installed by this version of AVM is ready for it; for an older Windows, install spice-webdavd from spice-space.org in Windows first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    private func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Share"
        panel.message = "Choose a folder for \(guest) to open."
        if panel.runModal() == .OK, let url = panel.url {
            sharedFolderPath = url.path
        }
    }

    // MARK: - Secure Boot Section (2026-10-25)

    private var secureBootSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secure Boot")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Secure Boot", isOn: $secureBoot)
                .disabled(isRunning)
                .accessibilityHint(isRunning
                    ? "Stop \(guest) to change Secure Boot"
                    : "Windows needs Secure Boot for Insider preview builds and some updates")
            Text(isRunning
                 ? "Stop \(guest) to change Secure Boot."
                 : "Windows needs Secure Boot for Insider preview builds. Turning it on resets the firmware settings, keeping a copy; Windows normally starts again on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    /// Asks before switching Secure Boot on a VM that has already started.
    /// Cancel is the default, as for every change that can stop a machine
    /// booting the way it did.
    private func confirmSecureBootSwitch(on: Bool) -> Bool {
        let alert = NSAlert()
        if on {
            alert.messageText = "Turn on Secure Boot for \(saved.name)?"
            alert.informativeText = "AVM resets this virtual machine's firmware settings, keeping a copy, so Secure Boot can start with Microsoft's keys. Windows normally starts again on its own. If BitLocker or device encryption is on in Windows, it may ask for your recovery key, so have it ready. Turning Secure Boot off again puts the old settings back."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Turn On Secure Boot")
        } else {
            alert.messageText = "Turn off Secure Boot for \(saved.name)?"
            alert.informativeText = "AVM puts back the firmware settings from before Secure Boot, keeping a copy of the Secure Boot ones. Windows Update stops offering Insider preview builds. If BitLocker or device encryption is on, Windows may ask for your recovery key."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Turn Off Secure Boot")
        }
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - USB Section

    private var usbSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("USB Devices")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("When a USB device is plugged in while this virtual machine is running:")
                .fixedSize(horizontal: false, vertical: true)
            // Short group name with its label hidden: the same pattern as the
            // 2a device picker. With the long sentence as the Picker label,
            // VoiceOver repeated it on every radio button (heard 2026-09-26).
            Picker("When plugged in", selection: $usbMode) {
                Text("Ask each time").tag(USBPlugMode.ask)
                Text("Always use in \(guest)").tag(USBPlugMode.always)
                Text("Keep on the Mac").tag(USBPlugMode.keepOnMac)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("Keyboards, braille displays, and other input devices always ask, even with Always use in \(guest). You can still attach any device from the Virtual Machine menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Braille follow-through (2026-10-26). Same short-label pattern
            // as the picker above.
            Text("When a braille display comes back within a minute of leaving \(guest):")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Braille display comes back", selection: $brailleFollowsBack) {
                Text("Send it back to \(guest)").tag(true)
                Text("Ask first").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Some displays, such as the Monarch, disconnect for a moment when they switch modes; Send it back keeps them in \(guest). Choose Ask first if you unplug your display to bring it back to the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Remembered devices")
                .font(.subheadline)
                .accessibilityAddTraits(.isHeader)
            if rememberedDevices.isEmpty {
                Text("No remembered devices.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rememberedDevices) { device in
                    HStack(spacing: 12) {
                        Text("\(device.name): \(decisionText(for: device))")
                        Button("Forget") {
                            rememberedDevices.removeAll { $0.id == device.id }
                        }
                        .accessibilityLabel("Forget \(device.name)")
                        .accessibilityHint("AVM will follow the setting above for this device again. Takes effect when you save.")
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// Plain words for a remembered decision. An unknown word from a newer
    /// AVM is said plainly, and callers treat it as not remembered.
    private func decisionText(for device: RememberedUSBDevice) -> String {
        switch device.usesWindows {
        case .some(true): return "use in \(guest)"
        case .some(false): return "keep on the Mac"
        case .none: return "unknown choice, AVM will ask"
        }
    }

    // MARK: - Load Current Settings

    private func loadCurrentSettings() {
        let saved = self.saved
        vmName = saved.name
        cpuCount = saved.cpuCount
        ramSizeGB = saved.ramSizeGB
        diskSizeGB = saved.diskSizeGB
        usbMode = saved.effectiveUSBMode
        rememberedDevices = saved.usbRememberedDevices ?? []
        rememberedDevicesAtOpen = rememberedDevices
        secureBoot = saved.usesSecureBoot
        shareClipboard = saved.sharesClipboard
        sharedFolderPath = saved.sharedFolderPath
        sharedFolderReadOnly = saved.sharedFolderIsReadOnly
        brailleFollowsBack = saved.brailleFollowsBack
        lowAudioLatency = saved.usesLowAudioLatency
        windowsKeyboardID = saved.windowsKeyboardID
        windowsKeyboardName = saved.windowsKeyboardName
        windowsKeyboardAppleISO = saved.windowsKeyboardAppleISO == true
    }

    // MARK: - Save Settings

    /// Disk growth runs FIRST. If it fails, nothing is saved: the other edits
    /// stay on screen so the user can retry or Close. The configuration's
    /// disk size changes only after VMManager.growDiskImage has verified the
    /// real disk. sharedFolderPath is carried over untouched by copying the
    /// configuration.
    private func saveSettings() {
        guard !vmName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationErrors = ["Virtual machine name cannot be empty."]
            return
        }
        validationErrors = []
        saveMessage = nil
        isSaving = true

        let growTo: Int? = (!isRunning && diskSizeGB > currentDiskGB) ? diskSizeGB : nil

        // The disk can't grow on a drive that isn't connected (2026-10-25).
        if growTo != nil, configuration.storageIsMissing {
            let message = "\(configuration.storageMissingMessage) Nothing was saved."
            validationErrors = [message]
            Announcer.shared.announce(message, tone: .failure)
            isSaving = false
            return
        }

        // The Secure Boot question comes first (2026-10-25, code audit), before
        // anything changes: asked after the disk had grown, a Cancel left the
        // disk larger with nothing saved and nothing said. A machine that has
        // never started has nothing to switch, so no question.
        let secureBootChanged = !isRunning && secureBoot != saved.usesSecureBoot
        if secureBootChanged {
            let started = ((try? vmStore.vmDirectoryURL(for: saved))?.appendingPathComponent("nvram.fd").path)
                .map { FileManager.default.fileExists(atPath: $0) } ?? false
            if started, !confirmSecureBootSwitch(on: secureBoot) {
                secureBoot = saved.usesSecureBoot
                isSaving = false
                Announcer.shared.announce("Secure Boot left as it was. Nothing was saved.", tone: .info)
                return
            }
        }

        Task { @MainActor in
            if let growTo {
                do {
                    let diskPath = try vmStore.vmDirectoryURL(for: configuration)
                        .appendingPathComponent("disk.qcow2").path
                    try await VMManager().growDiskImage(at: diskPath, toGB: growTo)
                } catch {
                    let message = "The disk could not be made larger. Nothing was saved. \(error.localizedDescription)"
                    validationErrors = [message]
                    Announcer.shared.announce(message, tone: .failure)
                    isSaving = false
                    return
                }
            }

            // The firmware switch comes after the disk, which may already have
            // grown, so a failed switch still saves everything else and says
            // exactly what didn't change.
            var secureBootFailure: String? = nil
            if secureBootChanged {
                do {
                    try vmStore.switchSecureBoot(saved, on: secureBoot)
                } catch {
                    secureBootFailure = error.localizedDescription
                }
            }

            var updated = saved
            if secureBootChanged && secureBootFailure == nil {
                updated.secureBoot = secureBoot
            }
            updated.name = vmName
            updated.cpuCount = cpuCount
            updated.ramSizeGB = ramSizeGB
            if let growTo {
                updated.diskSizeGB = growTo
            }
            updated.shareClipboard = shareClipboard ? nil : false
            updated.sharedFolderPath = sharedFolderPath
            updated.sharedFolderReadOnly = sharedFolderReadOnly ? true : nil
            updated.brailleFollowThrough = brailleFollowsBack ? nil : "ask"
            updated.lowAudioLatency = lowAudioLatency ? true : nil
            updated.windowsKeyboardID = windowsKeyboardID
            updated.windowsKeyboardName = windowsKeyboardID == nil ? nil : windowsKeyboardName
            updated.windowsKeyboardAppleISO = windowsKeyboardID != nil && windowsKeyboardAppleISO ? true : nil
            updated.usbMode = usbMode.rawValue
            // Only if changed here (2026-10-26, code audit): a device
            // remembered from a plug-in prompt while this sheet was open
            // was otherwise erased by Save.
            if rememberedDevices != rememberedDevicesAtOpen {
                updated.usbRememberedDevices = rememberedDevices.isEmpty ? nil : rememberedDevices
            }
            vmStore.save(updated)
            // A running VM follows the clipboard setting straight away.
            AVMPasteboard.shared.refreshEnabled()

            let message: String
            if let growTo {
                message = savedDiskMessage(growTo)
            } else if isRunning {
                message = "Settings saved. USB changes apply right away. Other changes take effect after you restart \(guest)."
            } else {
                message = "Settings saved. Changes take effect the next time you start \(guest)."
            }
            if let secureBootFailure {
                let full = "\(message) But Secure Boot was not changed. Reason: \(secureBootFailure)"
                saveMessage = full
                validationErrors = [full]
                Announcer.shared.announce(full, tone: .failure)
                secureBoot = saved.usesSecureBoot
                isSaving = false
                return
            }
            saveMessage = message
            Announcer.shared.announce(message, tone: .info)
            isSaving = false
            // CLOSE ON SUCCESS (2026-09-26): this view works from the
            // configuration it was opened with. After a save that copy is
            // stale, and a second save from the still-open sheet would write
            // old values back (found live: the disk size could have been
            // saved as 254 GB while the real disk was 264). Closing means
            // reopening reads the saved configuration fresh. The announcement
            // above comes from Announcer, not this sheet, so closing does not
            // cut it off. Failures return early and keep the sheet open.
            dismiss()
        }
    }
}
