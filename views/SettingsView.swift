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
    /// The category it opens on (2026-10-30); the accessibility audit opens
    /// each in turn.
    var startCategory: SettingsCategory = .general

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
            ? "Shut down \(guest) to change this."
            : "Changes take effect the next time you start \(guest)."
    }

    /// While the machine runs, its cores, memory, microphone, camera and 3D
    /// don't change (2026-10-29, sixth audit): changed then, a Save with open
    /// apps made a saved state the next Start, with the new values, couldn't
    /// load, and the unsaved work was lost.
    private var shapeChanged: Bool {
        cpuCount != saved.cpuCount || ramSizeGB != saved.ramSizeGB
            || shareMicrophone != saved.sharesMicrophone || shareCamera != saved.sharesCamera
            || gpu3D != (saved.gpu3D == true)
            // Secure Boot and the disk too (2026-10-29, seventh audit): they
            // were dropped without a word.
            || secureBoot != saved.usesSecureBoot || diskSizeGB != saved.diskSizeGB
    }

    /// Started while this sheet, or one of its questions, was open
    /// (2026-10-29, seventh audit): avmctl or the Virtual Machine menu can
    /// start it meanwhile, and its disk or settings were then changed under
    /// the running machine.
    private var startedMeanwhile: Bool { MachineSessions.shared.session(for: saved.id) != nil }

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
    @State private var shareMicrophone = false
    @State private var soundSmoothness: SoundSmoothness = .balanced
    @State private var soundOutputUID: String?
    @State private var soundOutputName: String?
    @State private var soundOutputs: [SoundOutputDevices.Device] = []
    @State private var isTemplate = false
    @State private var noWindow = false
    @State private var sharePrinters = false
    @State private var shareCamera = false
    @State private var gpu3D = false
    @State private var sharedFolderPath: String?
    @State private var sharedFolderReadOnly = false
    @State private var brailleFollowsBack = true
    @State private var restorePoints: [RestorePoint] = []
    @State private var restorePointsBusy = false
    @State private var restorePointsLoaded = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // The categories (2026-10-30, the user's request): one long page
            // of 22 sections became five, chosen in a toolbar VoiceOver reads
            // as one (SettingsCategoryBar).
            SettingsCategoryBar(selection: Binding(get: { category }, set: { chosenCategory = $0 }),
                                categories: SettingsCategory.allCases)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            // Scrolls (2026-10-25): the window has grown past small screens.
            ScrollView {
            VStack(spacing: 24) {
                Text(category.title)
                    .font(.largeTitle)
                    .accessibilityLabel("Settings: \(category.title)")
                    .accessibilityAddTraits(.isHeader)

                // Whatever category is showing: a refusal or a save's answer
                // may be about another one.
                if let saveMessage {
                    Text(saveMessage)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }
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

                categoryContent
            }
            .padding(32)
            }
            Divider()
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
            .padding(.vertical, 14)
        }
        .frame(minWidth: 520, minHeight: 600)
        .onAppear {
            loadCurrentSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFirstFieldFocused = true
            }
        }
    }

    // MARK: - Categories (2026-10-30)

    @State private var chosenCategory: SettingsCategory?
    private var category: SettingsCategory { chosenCategory ?? startCategory }

    /// Each category's sections, in the order they were on the one page.
    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .general:
            basicsSection
            templateSection
            windowSection
            commandTabSection
            if configuration.guestOS == .windows { windowsAppsSection }
        case .sharing:
            clipboardSection
            if configuration.guestOS != .macOS { sharedFolderSection }
            printersSection
            remoteDesktopSection
        case .devices:
            microphoneSection
            cameraSection
            if configuration.guestOS == .windows { windowsKeyboardSection }
            if configuration.guestOS != .macOS { trackpadSection }
            usbSection
        case .displayAndSound:
            displaySection
            gpuSection
            soundSection
        case .startupAndRecovery:
            if configuration.guestOS == .windows { secureBootSection }
            if configuration.guestOS != .macOS { saveWithAppsSection }
            restorePointsSection
            if configuration.guestOS == .windows { reinstallSection }
        }
    }

    // MARK: - Sections, by category (2026-10-30)

    /// Name, cores, memory and disk.
    @ViewBuilder
    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 20) {

            // VM Name
            VStack(alignment: .leading, spacing: 6) {
                // The shown words, hidden from VoiceOver (2026-10-27, tester
                // feedback): the field just after has the same name, and
                // VoiceOver read the two as plain text and a field it
                // didn't clearly call a text field. Its hint says to type.
                Text("Virtual Machine Name")
                    .font(.headline)
                    .accessibilityHidden(true)
                TextField("Virtual machine name", text: $vmName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Virtual machine name")
                    .accessibilityHint("Type a new name for this virtual machine, then choose Save Settings.")
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
                    .disabled(isRunning)
                    .accessibilityHint(isRunning ? timingSentence : "Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount). \(timingSentence)")
            }

            // Memory
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory: \(ramSizeGB) GB")
                    .font(.headline)
                    .accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
                Stepper(value: $ramSizeGB, in: 4...maxMemoryInGB, step: 2) { Text("Memory in gigabytes") }
                    .labelsHidden()
                    .disabled(isRunning)
                    .accessibilityHint(isRunning ? timingSentence : "Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB. \(timingSentence)")
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
        }
        .padding(.horizontal)
    }

    /// Printers (2026-10-27).
    @ViewBuilder
    private var printersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Printers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Add my Mac's printers to \(guest)", isOn: $sharePrinters)
                .accessibilityHint("When on, each Start adds your Mac's network printers in \(guest)")
            Text("Network printers your Mac uses appear in \(guest) with (Mac) after their names, ready to print with no driver to install. A printer plugged into your Mac by USB isn't included; attach it to \(guest) with Attach USB Device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// Without a window (2026-10-27).
    @ViewBuilder
    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Start without a window", isOn: $noWindow)
                .accessibilityHint("When on, \(guest) runs in the background after Start; Enter in its row opens its window")
            Text("For a machine you reach over the network or with avmctl, or one that just needs to run. Its sound still plays. The clipboard, shared folder and keyboard for Windows join it once its window opens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// Template (2026-10-27).
    @ViewBuilder
    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Template")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Use as a template", isOn: $isTemplate)
                .accessibilityHint("When on, this machine stays as it is, and its row makes new machines from it instead of starting it")
            Text("Set up a machine the way you like, with your screen reader and apps, then make it a template: each new machine from it starts out just like it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// Sound (2026-10-28, SoundSmoothness).
    @ViewBuilder
    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sound")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Picker("Sound", selection: $soundSmoothness) {
                ForEach(SoundSmoothness.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .choicePopUp("Chooses between hearing speech from \(guest) sooner and sound that doesn't crackle when your Mac is busy")
            Text("If sound or speech from \(guest) crackles, choose Smoothest. Fastest gets speech to you about 40 milliseconds sooner, but can crackle while your Mac is busy. Takes effect at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Sound Output (2026-10-30, SoundOutputDevices.swift).
            Picker("Sound Output", selection: $soundOutputUID) {
                Text("Same as the Mac").tag(String?.none)
                ForEach(soundOutputs) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let uid = soundOutputUID, !soundOutputs.contains(where: { $0.uid == uid }) {
                    Text("\(soundOutputName ?? "Chosen output") (not connected now)").tag(Optional(uid))
                }
            }
            .choicePopUp("Chooses where sound from \(guest) plays: the same output as the Mac, or one of its own, such as headphones")
            .onChange(of: soundOutputUID) { uid in
                if let uid, let device = soundOutputs.first(where: { $0.uid == uid }) { soundOutputName = device.name }
            }
            .onAppear { soundOutputs = SoundOutputDevices.list() }
            Text("To keep \(guest)'s screen reader apart from VoiceOver, play \(guest) through its own output, headphones say, and leave the Mac's on the speakers. When the chosen output isn't connected, \(guest) plays through the Mac's. Takes effect at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// Microphone (2026-10-27).
    @ViewBuilder
    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microphone")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Let \(guest) use your Mac's microphone", isOn: $shareMicrophone)
                .disabled(isRunning)
                .accessibilityHint(isRunning ? timingSentence : "When on, \(guest) hears your Mac's microphone while an app in it records")
            Text("For dictation, calls and recordings in \(guest). The microphone is only open while something in \(guest) records, and macOS asks once for permission. Takes effect at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// Camera (2026-10-27).
    @ViewBuilder
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Let \(guest) use your Mac's camera", isOn: $shareCamera)
                .disabled(isRunning)
                .accessibilityHint(isRunning ? timingSentence : "When on, \(guest) has a camera that shows what your Mac's camera sees, while an app in it uses it")
            Text("For video calls and apps that read with the camera in \(guest), where it's called Mac Camera. Your Mac's camera is only on while an app in \(guest) uses it, and AVM says when it turns on and off. macOS asks once for permission. Takes effect at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    /// 3D graphics (2026-10-27), Linux only.
    @ViewBuilder
    private var gpuSection: some View {
        if configuration.guestOS.isLinux && VMManager.supports3D {
            VStack(alignment: .leading, spacing: 6) {
                Text("3D Graphics")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Toggle("Draw \(guest) with your Mac's graphics chip", isOn: $gpu3D)
                    .disabled(isRunning)
                    .accessibilityHint(isRunning ? timingSentence : "When on, \(guest)'s desktop and 3D apps use your Mac's GPU")
                Text("Makes \(guest)'s desktop smoother and lets apps that need 3D run. While it's on, \(guest) can't be saved with its apps open, and restore points are taken with \(guest) stopped: QEMU can't save 3D graphics yet. Takes effect at the next Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)
        }
    }

    /// Clipboard (2026-10-25).
    @ViewBuilder
    private var clipboardSection: some View {
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
    }

    // MARK: - Restore Points Section (2026-10-25)

    /// Saving and using restore points (RestorePoints in VMStore.swift).
    /// Only while the VM is stopped, and not while its drive is missing.
    /// Save and restore points with open apps need the virtio disk
    /// (VMManager's disk switch); older machines can move to it here.
    @ViewBuilder
    private var saveWithAppsSection: some View {
        let guest = configuration.guestOS.displayName
        VStack(alignment: .leading, spacing: 6) {
            Text("Save with Open Apps")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if saved.uses3D && VMManager.supports3D {
                Text("Off while 3D Graphics is on: QEMU can't save 3D graphics yet. Shut \(guest) down instead; restore points can still be taken with it stopped.")
                    .fixedSize(horizontal: false, vertical: true)
            } else if saved.usesVirtioDisk && saved.diskBusSwitch == nil {
                Text("On. Save keeps \(guest) as it is, open apps and all, and restore points taken while it runs keep open apps too.")
                    .fixedSize(horizontal: false, vertical: true)
            } else if saved.diskBusSwitch != nil {
                Text(saved.usesVirtioDisk
                     ? "Turning on: the next Start of \(guest) finishes it."
                     : "Turning on: the next Start of \(guest) gets it ready, which takes a minute once \(guest) is up. The Start after that turns it on.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off for this machine, which was made before AVM could save open apps. Turning it on moves its disk to a faster connection that QEMU can save. AVM does it over the next two Starts, and switches back by itself if \(guest) doesn't start.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On Save with Open Apps") {
                    var updated = saved
                    updated.diskBusSwitch = "pending"
                    vmStore.save(updated)
                    Announcer.shared.announce("Save with open apps turns on over the next two Starts of \(guest).", tone: .info)
                }
                // The reason when dimmed (2026-10-29, sixth audit).
                .accessibilityHint(isRunning
                    ? "Shut down \(guest) to turn this on"
                    : "Gets \(guest) ready at its next Start, and turns it on at the Start after")
                .disabled(isRunning)
            }
        }
        .padding(.horizontal)
    }

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
                        Text("\(point.label), \(restorePointDate(point.date))\(point.withMemory ? ", with open apps" : "")")
                        Spacer()
                        Button("Restore") { restoreTo(point) }
                            .accessibilityLabel("Restore \(point.label)")
                            .accessibilityHint(point.withMemory ? "Puts the virtual machine back as it was then, open apps and all; its next Start carries on from there. Asks first." : "Puts the virtual machine back as it was then. Asks first.")
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
        // Again when the machine starts or stops (2026-10-28, fourth audit):
        // loaded once while it ran, the list stayed "No restore points yet."
        .task(id: isRunning) { await loadRestorePoints() }
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
        if MachineArchiveController.shared.refusesWhileBusy(saved) { return }
        // A saved machine's disk is mid-session (2026-10-27), as on macOS
        // machines: a restore point of it would start as after a power cut.
        // Or one waiting to resume a restore point (fifth audit).
        if QEMUSavedState.looksSavedOrWaiting(saved) {
            Announcer.shared.announce("\(saved.name) is saved with its apps open, so its disk is mid-session. Start it and shut it down first.", tone: .failure)
            return
        }
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
        if startedMeanwhile {
            Announcer.shared.announce("\(saved.name) started while you were asked, so no restore point was saved. Use Save Restore Point in its row while it runs, or shut it down first.", tone: .failure)
            return
        }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.isEmpty ? "Restore point from \(restorePointDate(Date()))" : label
        guard let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        restorePointsBusy = true
        Announcer.shared.announce("Saving the restore point.", tone: .info)
        Task { @MainActor in
            do {
                _ = try await RestorePoints.create(vmDirectory: dir, label: name, secureBoot: saved.usesSecureBoot, diskBus: saved.diskBus ?? "nvme")
                await loadRestorePoints()
                Announcer.shared.announce("Restore point saved: \(name).", tone: .success)
            } catch {
                Announcer.shared.announce("The restore point was not saved. Reason: \(error.localizedDescription)", tone: .failure)
            }
            restorePointsBusy = false
        }
    }

    // MARK: - Display (2026-10-28, MachineDisplays.swift)

    @State private var displayID: String?
    @State private var displayName: String?
    @State private var connectedDisplays: [MachineDisplays.Display] = []

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monitor")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Choose the monitor the \(guest) window always opens on, filling it, every time it starts. If that monitor isn't connected, the window opens on another one and moves back as soon as you connect it. While AVM is in the background, a window on a monitor without the menu bar stays there for someone to watch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Monitor", selection: $displayID) {
                Text("Wherever it was last").tag(String?.none)
                ForEach(connectedDisplays) { display in
                    Text(display.choiceName).tag(Optional(display.id))
                }
                if let id = displayID, !connectedDisplays.contains(where: { $0.id == id }) {
                    Text("\(displayName ?? "Monitor") (not connected now)").tag(Optional(id))
                }
            }
            .choicePopUp("Opens the list of monitors connected to your Mac. The \(guest) window always opens on the one you choose.")
            .onChange(of: displayID) { id in
                if let id, let display = connectedDisplays.first(where: { $0.id == id }) {
                    displayName = display.name
                }
            }
            Button("Look Again") { connectedDisplays = MachineDisplays.connected }
                .accessibilityLabel("Look again for monitors")
                .accessibilityHint("Lists the monitors connected now")
        }
        .padding(.horizontal)
        .onAppear { connectedDisplays = MachineDisplays.connected }
    }

    // MARK: - Keyboard for Windows (2026-10-26)

    @State private var windowsKeyboardID: String?
    @State private var windowsKeyboardName: String?
    @State private var windowsKeyboardAppleISO = false
    @State private var windowsAppsInCommandTab = true
    @State private var trackpadAndMouseOn = true
    @State private var inCommandTab = true

    // MARK: - Command-Tab (2026-10-30)

    private var commandTabSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command-Tab")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("This machine in Command-Tab", isOn: $inCommandTab)
                .accessibilityHint("While it runs, it's in your Mac's Command-Tab list under its own name. Switching to it puts your keyboard in it.")
            Text("While it runs, the machine is an app in Command-Tab, and in the Dock, named for it. Switch to it and your keyboard goes straight in. Changes take effect at once.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    // MARK: - Trackpad and mouse (2026-10-30)

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trackpad and Mouse")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Trackpad and mouse work in \(guest)", isOn: $trackpadAndMouseOn)
                .accessibilityHint("Turn off so a stray touch can't move or click in \(guest). They still work on your Mac.")
            Text("Off: while your keyboard is in \(guest), the trackpad and mouse do nothing, so a stray touch can't move the pointer or click there. They work on your Mac as always. Changes take effect at once.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

    // MARK: - Windows apps on the Mac (2026-10-29)

    private var windowsAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Windows Apps on the Mac")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Windows apps in Command-Tab", isOn: $windowsAppsInCommandTab)
                .accessibilityHint("Each app open in \(guest) is in your Mac's Command-Tab list. Switch to one, then press Command-Shift-E to type in it.")
            Text("Each app open in \(guest) is an app in Command-Tab, and in the Dock, while it's open. Switch to one and press Command-Shift-E: it comes forward and your keyboard goes into \(guest). AVM puts a small helper in \(guest) for this.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal)
    }

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
            .accessibilityHint("Opens the list of keyboards connected to your Mac. The one you choose types only into Windows.")
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
                Button("Look Again") { Task { await loadKeyboards(registering: true) } }
                    .accessibilityHint("Lists the keyboards connected now. Wake a Bluetooth keyboard by pressing a key first.")
                if let keyboardsMessage {
                    Text(keyboardsMessage)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal)
        .task { await loadKeyboards(registering: false) }
    }

    private func loadKeyboards(registering: Bool) async {
        switch await USBHelperClient.shared.listKeyboards(registering: registering) {
        case .success(let list):
            connectedKeyboards = list.compactMap { entry in
                guard (entry["builtIn"] as? NSNumber)?.boolValue != true,
                      let id = entry["id"] as? String else { return nil }
                return (id, entry["name"] as? String ?? "Keyboard")
            }
            keyboardsMessage = connectedKeyboards.isEmpty
                ? "No second keyboard is connected. Connect one, or wake it by pressing a key, then choose Look Again."
                : nil
        case .failure(.notEnabled) where !registering:
            connectedKeyboards = []
            keyboardsMessage = "Keyboards are listed by AVM's helper, which isn't set up yet. Choose Look Again to set it up; macOS may ask you to allow it in Login Items."
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
                // The reason when dimmed (2026-10-29, sixth audit).
                .accessibilityHint(saved.storageIsMissing && !isRunning
                    ? saved.storageMissingMessage
                    : "Asks first. Everything in Windows on this machine is erased.")
        }
        .padding(.horizontal)
    }

    private func reinstallWindows() {
        if MachineArchiveController.shared.refusesWhileBusy(saved) { return }
        let alert = NSAlert()
        alert.messageText = "Erase Windows on \(saved.name) and install it again?"
        alert.informativeText = "Everything in Windows on this machine is erased: files, apps, settings and restore points. When you next start it, Windows installs as it did the first time, from the same installer and with the same setup answers. This can't be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase and Reinstall")
        var passwordField: NSSecureTextField? = nil
        var confirmField: NSSecureTextField? = nil
        if WindowsReinstall.needsPassword(saved) {
            // Asked twice, as the wizard asks (2026-10-28, fourth audit): a
            // typo went into the one automatic sign-in, and the next sign-in
            // locked the user out of the only administrator account.
            let account = WindowsReinstall.localUserName(saved) ?? ""
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            field.placeholderString = "Password"
            field.setAccessibilityLabel("Password for the Windows account \(account)")
            let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            again.placeholderString = "Password again"
            again.setAccessibilityLabel("The password again, to check it")
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            fields.addSubview(field)
            fields.addSubview(again)
            field.nextKeyView = again
            alert.accessoryView = fields
            alert.informativeText += " Type the Windows account's password below, twice; leave both empty for no password."
            passwordField = field
            confirmField = again
            alert.window.initialFirstResponder = field
        }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if startedMeanwhile {
            Announcer.shared.announce("\(saved.name) started while you were asked, so Windows wasn't reinstalled. Shut it down first.", tone: .failure)
            return
        }
        if let passwordField, let confirmField, passwordField.stringValue != confirmField.stringValue {
            Announcer.shared.announce("The two passwords aren't the same, so Windows wasn't reinstalled. Choose Reinstall Windows again.", tone: .failure)
            return
        }
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
        if MachineArchiveController.shared.refusesWhileBusy(saved) { return }
        let alert = NSAlert()
        alert.messageText = "Put \(saved.name) back to \(point.label)?"
        alert.informativeText = "Everything since \(restorePointDate(point.date)) is lost: files, settings and installed updates. AVM keeps the restore point, so you can use it again."
        let wasSaved = QEMUSavedState.looksSaved(saved)
        if wasSaved {
            alert.informativeText += " \(saved.name) is saved with its apps open; that is lost too."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore")
        guard alert.runModal() == .alertSecondButtonReturn,
              let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        if startedMeanwhile {
            Announcer.shared.announce("\(saved.name) started while you were asked, so it wasn't restored. Shut it down first.", tone: .failure)
            return
        }
        restorePointsBusy = true
        Task { @MainActor in
            do {
                // The saved session goes only once the restore can't refuse
                // (2026-10-29, sixth audit): a Secure Boot mismatch or a
                // failed copy said "not restored", with the session gone.
                let toDiscard = wasSaved ? saved : nil
                try await RestorePoints.restore(point, vmDirectory: dir, currentSecureBoot: saved.usesSecureBoot) {
                    if let toDiscard { await QEMUSavedState.discard(configuration: toDiscard) }
                }
                // The disk bus comes back with it (2026-10-28, code review):
                // a point from before the move to the virtio disk has no
                // virtio driver, and would not boot on it.
                var busNote = ""
                if let bus = point.diskBus, bus != (saved.diskBus ?? "nvme") {
                    var updated = saved
                    updated.diskBus = bus == "nvme" ? nil : bus
                    updated.diskBusSwitch = nil
                    vmStore.save(updated)
                    busNote = bus == "nvme"
                        ? " It's back on its original disk connection too; Save with Open Apps is off until you turn it on again."
                        : " It's on the virtio disk again, as it was then."
                }
                // The disk's size comes back with it, if it has grown since.
                var sizeNote = ""
                if let size = try? await RestorePoints.diskSizeGB(vmDirectory: dir), size > 0, size != saved.diskSizeGB {
                    var updated = saved
                    updated.diskSizeGB = size
                    vmStore.save(updated)
                    diskSizeGB = size
                    sizeNote = " Its disk is \(size) gigabytes again, as it was then."
                }
                Announcer.shared.announce("\(saved.name) is back to \(point.label).\(sizeNote)\(busNote) Start it when you're ready.", tone: .success)
            } catch {
                Announcer.shared.announce("\(saved.name) was not restored. Reason: \(error.localizedDescription)", tone: .failure)
            }
            restorePointsBusy = false
        }
    }

    private func deleteRestorePoint(_ point: RestorePoint) {
        // Not while its files are being copied (sixth audit).
        if MachineArchiveController.shared.refusesWhileBusy(saved) { return }
        let alert = NSAlert()
        alert.messageText = "Delete the restore point \(point.label)?"
        alert.informativeText = "This frees the disk space it uses. It can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn,
              let dir = try? vmStore.vmDirectoryURL(for: saved) else { return }
        if startedMeanwhile {
            Announcer.shared.announce("\(saved.name) started while you were asked, so the restore point wasn't deleted. Shut it down first.", tone: .failure)
            return
        }
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

    // MARK: - Remote Desktop (2026-10-28, RemoteDesktop.swift)

    @State private var remoteDesktopOn = false
    @State private var remoteDesktopUser = ""
    @State private var remoteDesktopPassword = ""
    @State private var remoteDesktopShowPassword = false
    @State private var remoteDesktopReach = "mac"

    private var windowsIsHome: Bool {
        configuration.guestOS == .windows && (saved.windowsEdition == .home || saved.windowsEdition == .homeSingleLanguage)
    }

    private var remoteDesktopSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remote Desktop")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if windowsIsHome {
                Text("This Windows is the Home edition, which has no Remote Desktop host built in. Remote Desktop needs Windows 11 Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("Let the Windows App connect to \(guest)", isOn: $remoteDesktopOn)
                    .accessibilityHint("Microsoft's Windows App, from the App Store, can then open \(guest) by Remote Desktop with the account below")
                if remoteDesktopOn {
                    TextField("User name", text: $remoteDesktopUser)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("User name for Remote Desktop")
                        .accessibilityHint("The account the Windows App signs in with. AVM makes it in \(guest), or sets this password on it if it's there already.")
                    if remoteDesktopShowPassword {
                        TextField("Password", text: $remoteDesktopPassword)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Password for Remote Desktop, shown")
                    } else {
                        SecureField("Password", text: $remoteDesktopPassword)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Password for Remote Desktop")
                    }
                    Toggle("Show the password", isOn: $remoteDesktopShowPassword)
                    Text("Reachable from")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Picker("Reachable from", selection: $remoteDesktopReach) {
                        Text("This Mac only").tag("mac")
                        Text("My whole network: iPad, phone, other Macs").tag("network")
                    }
                    .choicePopUp("Chooses whether only this Mac, or every device on your network, can open \(guest) by Remote Desktop")
                    Text(remoteDesktopAddressWords)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(configuration.guestOS == .windows
                     ? "AVM keeps the password in your Mac's keychain and makes the account in \(guest). If you give the name of an account \(guest) already has, its password becomes this one, once; a password you change later inside \(guest) is left alone unless you type a new one here."
                     : "AVM keeps the password in your Mac's keychain and makes the account in \(guest), with xrdp. The session has sound where the distribution has xrdp's sound module (Debian 13, Ubuntu 24.04 and newer). Use a different account from the one signed in at \(guest)'s own screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
    }

    private var remoteDesktopAddressWords: String {
        var preview = saved
        preview.remoteDesktopUser = remoteDesktopUser
        preview.remoteDesktopReach = remoteDesktopReach
        let port = RemoteDesktop.port(for: preview, among: vmStore.configurations)
        let addresses = RemoteDesktop.addresses(for: preview, port: port)
        return "In the Windows App, add a PC named \(addresses.name), or \(addresses.ip), and sign in as \(remoteDesktopUser.isEmpty ? "the user name above" : remoteDesktopUser). The name works while \(guest) is running."
    }

    /// After Save: the keychain, the forwarding and the account in a
    /// running machine. Spoken as it goes.
    private func applyRemoteDesktop(_ updated: VMConfiguration, wasOn: Bool, oldPort: Int?) {
        let id = updated.id
        if updated.remoteDesktopOn, let port = updated.remoteDesktopPort {
            // A failed keychain save is said (2026-10-29, seventh audit): the
            // promise below was made, and the next start then skipped in silence.
            if !remoteDesktopPassword.isEmpty, !RemoteDesktop.savePassword(remoteDesktopPassword, for: id) {
                Announcer.shared.announce("The Remote Desktop password couldn't be kept in your keychain, so Remote Desktop isn't set up. Next: unlock your keychain, then save the settings again.", tone: .failure)
                return
            }
            guard isRunning, let manager = MachineSessions.shared.session(for: id)?.manager else {
                Announcer.shared.announce("Remote Desktop is set up the next time \(guest) starts.", tone: .info)
                return
            }
            let user = updated.remoteDesktopUser ?? ""
            let password = remoteDesktopPassword.isEmpty ? (RemoteDesktop.password(for: id) ?? "") : remoteDesktopPassword
            // The account's password is set when it's new to this machine or
            // typed anew (2026-10-28); an existing account's is otherwise kept.
            let mark = RemoteDesktop.mark(for: password)
            let setPassword = updated.remoteDesktopPasswordMark != mark
            Task { @MainActor in
                if let oldPort, oldPort != port { await manager.stopForwardingRemoteDesktop(port: oldPort) }
                let forwarded = await manager.forwardRemoteDesktopNow(configuration: updated, port: port)
                RemoteDesktopAdvertiser.shared.publish(updated, port: port)
                Announcer.shared.announce("Setting up Remote Desktop in \(guest). This takes a minute.", tone: .info)
                switch await manager.setUpRemoteDesktop(configuration: updated, user: user, password: password, setPassword: setPassword) {
                case .ready(let words):
                    if setPassword { RemoteDesktop.recordPasswordMark(mark, for: id) }
                    let addresses = RemoteDesktop.addresses(for: updated, port: port)
                    Announcer.shared.announce("\(words) In the Windows App, add a PC named \(addresses.name), or \(addresses.ip).\(forwarded ? "" : " The Mac's port couldn't be forwarded yet; restart \(guest) if the Windows App can't reach it.")", tone: .success)
                case .unsupported(let words), .failed(let words):
                    Announcer.shared.announce(words, tone: .failure)
                }
            }
        } else if wasOn {
            RemoteDesktop.forgetPassword(for: id)
            RemoteDesktopAdvertiser.shared.unpublish(id)
            if isRunning, let manager = MachineSessions.shared.session(for: id)?.manager, let oldPort {
                Task { await manager.stopForwardingRemoteDesktop(port: oldPort) }
            }
            Announcer.shared.announce("Remote Desktop is off for \(guest). The account stays in it.", tone: .info)
        }
    }

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
                        // Said (2026-10-29, seventh audit): the form changed
                        // without a word.
                        Announcer.shared.announce("No folder is shared now. Takes effect when you save.", tone: .info)
                    }
                }
            }
            if sharedFolderPath != nil {
                Toggle("\(guest) can only read it, not change it", isOn: $sharedFolderReadOnly)
            }
            Text(configuration.guestOS == .windows
                 ? "\(guest) shows the folder in File Explorer as a network drive. Changes take effect the next time \(guest) starts. Windows installed by this version of AVM is ready for it; for an older Windows, install spice-webdavd from spice-space.org in Windows first."
                 : "\(guest) shows the folder in Files as Mac shared folder, in the sidebar. Changes take effect the next time \(guest) starts. \(guest) installed by this version of AVM is ready for it.")
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
            Announcer.shared.announce("Sharing \(url.lastPathComponent). Takes effect when you save.", tone: .info)
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
            .choicePopUp("Opens the choices for a USB device plugged in while \(guest) runs.")

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
            .choicePopUp("Opens the choices for a braille display that comes back within a minute.")
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
                            Announcer.shared.announce("\(device.name) forgotten. AVM asks about it again at its next plug-in, once you save.", tone: .info)
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
        shareMicrophone = saved.sharesMicrophone
        soundSmoothness = saved.soundSmoothness
        soundOutputUID = saved.soundOutputUID
        soundOutputName = saved.soundOutputName
        isTemplate = saved.isATemplate
        noWindow = saved.startsWithoutWindow
        sharePrinters = saved.sharesPrinters
        shareCamera = saved.sharesCamera
        gpu3D = saved.gpu3D == true
        sharedFolderPath = saved.sharedFolderPath
        sharedFolderReadOnly = saved.sharedFolderIsReadOnly
        brailleFollowsBack = saved.brailleFollowsBack
        windowsKeyboardID = saved.windowsKeyboardID
        windowsKeyboardName = saved.windowsKeyboardName
        windowsKeyboardAppleISO = saved.windowsKeyboardAppleISO == true
        windowsAppsInCommandTab = saved.windowsAppsInCommandTab != false
        trackpadAndMouseOn = saved.trackpadAndMouseOff != true
        inCommandTab = saved.inCommandTab != false
        displayID = saved.displayID
        displayName = saved.displayName
        remoteDesktopOn = saved.remoteDesktopOn
        remoteDesktopUser = saved.remoteDesktopUser ?? ""
        remoteDesktopReach = saved.remoteDesktopReach ?? "mac"
        remoteDesktopPassword = saved.remoteDesktopOn ? (RemoteDesktop.password(for: saved.id) ?? "") : ""
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
            // Said, as every other refusal here is (2026-10-28, fourth audit).
            Announcer.shared.announce("The virtual machine's name can't be empty. Type a name, then save again.", tone: .failure)
            return
        }
        // Names stay different (2026-10-28, fourth audit): two machines of
        // the same name read the same everywhere, Delete included.
        let trimmedName = vmName.trimmingCharacters(in: .whitespaces)
        if vmStore.configurations.contains(where: { $0.id != configuration.id && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            validationErrors = ["Another virtual machine is already called \(trimmedName)."]
            Announcer.shared.announce("Another virtual machine is already called \(trimmedName). Choose a different name, then save again.", tone: .failure)
            return
        }
        if remoteDesktopOn, !windowsIsHome {
            let user = remoteDesktopUser.trimmingCharacters(in: .whitespaces)
            if user.isEmpty || user.count > 20 || user.rangeOfCharacter(from: CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@'\u{2018}\u{2019}\u{201A}\u{201B}\u{201C}\u{201D}")) != nil || user.hasSuffix(".") {
                validationErrors = ["Remote Desktop needs a user name of up to 20 characters, without quotes, slashes, colons or brackets."]
                Announcer.shared.announce(validationErrors[0], tone: .failure)
                return
            }
            // Linux's useradd takes less (2026-10-28, second review).
            if configuration.guestOS != .windows, user.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) == nil {
                validationErrors = ["On Linux, the Remote Desktop user name must be lowercase letters, digits, dashes and underscores, starting with a letter."]
                Announcer.shared.announce(validationErrors[0], tone: .failure)
                return
            }
            if remoteDesktopPassword.isEmpty, RemoteDesktop.password(for: saved.id) == nil {
                validationErrors = ["Remote Desktop needs a password."]
                Announcer.shared.announce(validationErrors[0], tone: .failure)
                return
            }
        }
        // Started while this sheet was open (sixth audit): the controls are
        // off now, so their changed values go back to the saved ones, the
        // rest is saved, and that is said.
        // Not a template while saved (2026-10-29, sixth audit): a template
        // can't start, and a saved machine can't be copied until it has.
        if isTemplate, !saved.isATemplate, QEMUSavedState.looksSavedOrWaiting(saved) {
            let message = "\(saved.name) is saved with its apps open, so it can't be a template yet. Nothing was saved. Next: start it, shut it down, then make it a template."
            validationErrors = [message]
            Announcer.shared.announce(message, tone: .failure)
            return
        }
        // Nor while it runs (seventh audit): saved with open apps as a
        // template, nothing could start or copy it.
        if isTemplate, !saved.isATemplate, isRunning || startedMeanwhile {
            let message = "\(saved.name) is running, so it can't be a template yet. Nothing was saved. Next: shut it down, then make it a template."
            validationErrors = [message]
            Announcer.shared.announce(message, tone: .failure)
            return
        }
        let keptShape = isRunning && shapeChanged
        if keptShape {
            cpuCount = saved.cpuCount
            ramSizeGB = saved.ramSizeGB
            shareMicrophone = saved.sharesMicrophone
            shareCamera = saved.sharesCamera
            gpu3D = saved.gpu3D == true
            secureBoot = saved.usesSecureBoot
            diskSizeGB = saved.diskSizeGB
        }
        // Not while its files are being copied (sixth audit): Settings was
        // checked only as it opened, and an export could be changed mid-copy.
        if MachineArchiveController.shared.refusesWhileBusy(saved) { return }
        validationErrors = []
        saveMessage = nil
        isSaving = true

        let growTo: Int? = (!isRunning && diskSizeGB > currentDiskGB) ? diskSizeGB : nil

        // A saved machine carries on only with the memory, cores and disk it
        // was saved with (2026-10-27, code audit), as on macOS machines:
        // asked first, and the saved session let go of, so the next Start is
        // a plain start, not a failed resume. A larger disk can't take a
        // snapshot along anyway.
        let changesMachine = cpuCount != saved.cpuCount || ramSizeGB != saved.ramSizeGB || growTo != nil
            || secureBoot != saved.usesSecureBoot || shareMicrophone != saved.sharesMicrophone
            || shareCamera != saved.sharesCamera || gpu3D != (saved.gpu3D == true)
        var discardSaved: VMConfiguration?
        // A restore point with open apps waiting to be carried on counts
        // too (2026-10-28, fourth audit): its next Start loaded that memory
        // into the changed machine, failed, and lost the unsaved work.
        let resumeNote = (try? saved.directoryURL())?.appendingPathComponent(QEMUSavedState.resumeFile)
        if !isRunning, changesMachine, QEMUSavedState.looksSavedOrWaiting(saved) {
            let alert = NSAlert()
            alert.messageText = "\(saved.name) is saved with its apps open. Change its settings anyway?"
            alert.informativeText = "These changes mean it can't carry on where it was: its next Start is a normal start, as after a power cut, and anything unsaved in its apps is lost. To keep it, choose Cancel, start it, and shut it down first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Change Settings")
            guard alert.runModal() == .alertSecondButtonReturn else {
                isSaving = false
                return
            }
            if startedMeanwhile {
                Announcer.shared.announce("\(saved.name) started while you were asked, so nothing was saved. Shut it down first.", tone: .failure)
                isSaving = false
                return
            }
            discardSaved = saved
        }

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
            if started, startedMeanwhile {
                secureBoot = saved.usesSecureBoot
                isSaving = false
                Announcer.shared.announce("\(saved.name) started while you were asked, so nothing was saved. Shut it down first.", tone: .failure)
                return
            }
        }

        Task { @MainActor in
            // Before the disk is touched, so the two never run at once.
            if let discardSaved {
                await QEMUSavedState.discard(configuration: discardSaved)
                if let resumeNote { try? FileManager.default.removeItem(at: resumeNote) }
            }
            if let growTo {
                do {
                    let diskPath = try vmStore.vmDirectoryURL(for: configuration)
                        .appendingPathComponent("disk.qcow2").path
                    try await VMManager().growDiskImage(at: diskPath, toGB: growTo)
                } catch {
                    // Truthful when the saved session already went (sixth
                    // audit): growing needs it gone first.
                    let message = discardSaved != nil
                        ? "The disk could not be made larger, and no other setting was saved. \(saved.name)'s saved session was already let go of, so its next Start is a normal start. \(error.localizedDescription)"
                        : "The disk could not be made larger. Nothing was saved. \(error.localizedDescription)"
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
            updated.name = vmName.trimmingCharacters(in: .whitespaces)
            updated.cpuCount = cpuCount
            updated.ramSizeGB = ramSizeGB
            if let growTo {
                updated.diskSizeGB = growTo
            }
            updated.shareClipboard = shareClipboard ? nil : false
            updated.shareMicrophone = shareMicrophone ? true : nil
            updated.soundBuffer = soundSmoothness == .balanced ? nil : soundSmoothness.rawValue
            updated.soundOutputUID = soundOutputUID
            updated.soundOutputName = soundOutputUID == nil ? nil : soundOutputName
            updated.isTemplate = isTemplate ? true : nil
            updated.noWindow = noWindow ? true : nil
            updated.sharePrinters = sharePrinters ? true : nil
            updated.shareCamera = shareCamera ? true : nil
            updated.gpu3D = gpu3D ? true : nil
            updated.sharedFolderPath = sharedFolderPath
            updated.sharedFolderReadOnly = sharedFolderReadOnly ? true : nil
            updated.brailleFollowThrough = brailleFollowsBack ? nil : "ask"
            updated.windowsKeyboardID = windowsKeyboardID
            updated.windowsKeyboardName = windowsKeyboardID == nil ? nil : windowsKeyboardName
            updated.windowsKeyboardAppleISO = windowsKeyboardID != nil && windowsKeyboardAppleISO ? true : nil
            updated.windowsAppsInCommandTab = windowsAppsInCommandTab ? nil : false
            updated.trackpadAndMouseOff = trackpadAndMouseOn ? nil : true
            updated.inCommandTab = inCommandTab ? nil : false
            updated.displayID = displayID
            updated.displayName = displayID == nil ? nil : displayName
            let remoteDesktopWasOn = saved.remoteDesktopOn
            let remoteDesktopOldPort = saved.remoteDesktopPort
            if remoteDesktopOn, !windowsIsHome {
                updated.remoteDesktopUser = remoteDesktopUser.trimmingCharacters(in: .whitespaces)
                updated.remoteDesktopReach = remoteDesktopReach == "network" ? "network" : nil
                updated.remoteDesktopPort = RemoteDesktop.port(for: updated, among: vmStore.configurations)
            } else {
                updated.remoteDesktopUser = nil
                updated.remoteDesktopReach = nil
                updated.remoteDesktopPort = nil
                updated.remoteDesktopPasswordMark = nil
            }
            updated.usbMode = usbMode.rawValue
            // Only if changed here (2026-10-26, code audit): a device
            // remembered from a plug-in prompt while this sheet was open
            // was otherwise erased by Save.
            if rememberedDevices != rememberedDevicesAtOpen {
                updated.usbRememberedDevices = rememberedDevices.isEmpty ? nil : rememberedDevices
            }
            let displayBefore = saved.displayID
            vmStore.save(updated)
            // A running VM follows the clipboard setting straight away.
            AVMPasteboard.shared.refreshEnabled()
            // And its display (2026-10-28).
            if updated.displayID != displayBefore {
                MachineSessions.shared.displayChosen(updated.id)
            }
            // Remote Desktop (2026-10-28): the keychain, the port, the account.
            // Only when something of it changed (fourth audit): every save of
            // any setting re-ran the setup in the machine and said so again.
            let remoteDesktopChanged = updated.remoteDesktopOn != remoteDesktopWasOn
                || updated.remoteDesktopUser != saved.remoteDesktopUser
                || updated.remoteDesktopReach != saved.remoteDesktopReach
                || updated.remoteDesktopPort != remoteDesktopOldPort
                || (remoteDesktopOn && remoteDesktopPassword != (RemoteDesktop.password(for: updated.id) ?? ""))
            if (remoteDesktopOn || remoteDesktopWasOn) && remoteDesktopChanged {
                applyRemoteDesktop(updated, wasOn: remoteDesktopWasOn, oldPort: remoteDesktopOldPort)
            }

            let message: String
            if let growTo {
                message = savedDiskMessage(growTo)
            } else if isRunning {
                // Not "restart" (sixth audit): a restart inside the machine
                // keeps the same virtual hardware.
                message = "Settings saved. USB changes apply right away; the others take effect when \(guest) next starts after shutting down."
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
            let said = keptShape
                ? "\(message) \(saved.name) started while Settings was open, so its processor cores, memory, microphone, camera, 3D graphics, Secure Boot and disk size stay as they were; shut it down to change them."
                : message
            saveMessage = said
            Announcer.shared.announce(said, tone: .info)
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

// MARK: - Settings categories (2026-10-30)

/// A machine's settings in five categories, the user's request: one page
/// of 22 sections was long to move through with VoiceOver.
/// A category a SettingsCategoryBar shows: a machine's Settings
/// (SettingsCategory) or AVM's own (PreferencesCategory, 2026-10-30).
protocol SettingsCategoryItem: Hashable {
    var title: String { get }
    var symbol: String { get }
}

enum SettingsCategory: String, CaseIterable, Identifiable, SettingsCategoryItem {
    case general, sharing, devices, displayAndSound, startupAndRecovery

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .sharing: return "Sharing"
        case .devices: return "Devices"
        case .displayAndSound: return "Display and Sound"
        case .startupAndRecovery: return "Startup and Recovery"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sharing: return "square.and.arrow.up.on.square"
        case .devices: return "keyboard"
        case .displayAndSound: return "display"
        case .startupAndRecovery: return "arrow.counterclockwise"
        }
    }
}

/// The categories as a toolbar VoiceOver reads as one: "Categories,
/// toolbar". VO-Shift-Down goes into it, VO-Left and VO-Right go through
/// its buttons, and VO-Space chooses one; the one showing is "selected".
/// Command-1, Command-2 and on choose them from anywhere in Settings.
struct SettingsCategoryBar<Category: SettingsCategoryItem>: View {
    @Binding var selection: Category
    let categories: [Category]

    var body: some View {
        AccessibilityToolbar(label: "Categories") {
            HStack(spacing: 4) {
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    Button { selection = category } label: {
                        VStack(spacing: 3) {
                            Image(systemName: category.symbol)
                                .font(.title2)
                                .accessibilityHidden(true)
                            Text(category.title)
                                .font(.caption)
                        }
                        .frame(minWidth: 84)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(selection == category ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.title)
                    .accessibilityAddTraits(selection == category ? .isSelected : [])
                    // Said, too: "General, selected, button".
                    .accessibilityValue(selection == category ? "selected" : "")
                    .accessibilityHint("Shows the \(category.title) settings. Command-\(index + 1).")
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        .fixedSize()
    }
}

/// SwiftUI content VoiceOver meets as a toolbar, with its own name.
/// SwiftUI has no toolbar role for a view, and a sheet has no window
/// toolbar, so the hosting view says it.
struct AccessibilityToolbar<Content: View>: NSViewRepresentable {
    let label: String
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ToolbarHostingView<Content> {
        let view = ToolbarHostingView(rootView: content())
        view.toolbarLabel = label
        return view
    }

    func updateNSView(_ view: ToolbarHostingView<Content>, context: Context) {
        view.rootView = content()
    }
}

final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
    var toolbarLabel = ""
    override func isAccessibilityElement() -> Bool { true }
    /// Not "dimmed": a hosting view reads as disabled otherwise.
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .toolbar }
    override func accessibilityLabel() -> String? { toolbarLabel }
}
