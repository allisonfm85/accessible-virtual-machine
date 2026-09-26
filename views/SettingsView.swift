// SettingsView.swift
// AVM — Accessible Virtual Machine

import SwiftUI

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
///   - Shared folder: REMOVED. Nothing in AVM ever read it, so choosing a
///     folder "saved" and Windows never saw it. A path already saved stays in
///     the configuration, untouched, for when the feature exists.
struct SettingsView: View {

    // MARK: - Environment

    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss

    // MARK: - Input

    let configuration: VMConfiguration
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
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            return max(40, available / (1024 * 1024 * 1024) - 20)
        }
        return 500
    }

    /// Disks grow but never shrink, so the stepper starts at the current size.
    private var currentDiskGB: Int { configuration.diskSizeGB }

    /// Never below the current size: free space can drop under it, and a
    /// stepper range whose top is below its bottom is invalid.
    private var diskGrowthCeilingGB: Int { max(currentDiskGB, maxDiskInGB) }

    /// When CPU and memory changes land, worded for this VM's state.
    private var timingSentence: String {
        isRunning
            ? "Changes take effect after restarting Windows."
            : "Changes take effect the next time you start Windows."
    }

    // MARK: - State

    @State private var vmName: String = ""
    @State private var cpuCount: Int = 4
    @State private var ramSizeGB: Int = 8
    @State private var diskSizeGB: Int = 64
    @State private var validationErrors: [String] = []
    @State private var isSaving = false
    @State private var saveMessage: String? = nil

    // MARK: - Body

    var body: some View {
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
                    Stepper("CPU Cores", value: $cpuCount, in: 2...maxCPUCount)
                        .labelsHidden()
                        .accessibilityLabel("CPU cores")
                        .accessibilityValue("\(cpuCount) cores")
                        .accessibilityHint("Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount). \(timingSentence)")
                }

                // Memory
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory: \(ramSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
                    Stepper("Memory", value: $ramSizeGB, in: 4...maxMemoryInGB, step: 2)
                        .labelsHidden()
                        .accessibilityLabel("Memory in gigabytes")
                        .accessibilityValue("\(ramSizeGB) gigabytes")
                        .accessibilityHint("Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB. \(timingSentence)")
                }

                // Disk Size: grow only, stopped VMs only.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disk Size: \(diskSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Disk size: \(diskSizeGB) gigabytes")
                    if isRunning {
                        Text("Stop Windows to make the disk larger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if diskGrowthCeilingGB <= currentDiskGB {
                        Text("There isn't enough free space on your Mac to make the disk larger.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Stepper("Disk Size", value: $diskSizeGB, in: currentDiskGB...diskGrowthCeilingGB, step: 10)
                            .labelsHidden()
                            .accessibilityLabel("Disk size in gigabytes")
                            .accessibilityValue("\(diskSizeGB) gigabytes")
                            .accessibilityHint("Adjust with arrow keys. The disk can grow but never shrink. Minimum \(currentDiskGB) GB, maximum \(diskGrowthCeilingGB) GB. After it grows, extend drive C inside Windows to use the new space.")
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

            // USB Devices
            usbSection

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
        .frame(minWidth: 480, minHeight: 600)
        .onAppear {
            loadCurrentSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFirstFieldFocused = true
            }
        }
    }

    // MARK: - USB Section

    private var usbSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("USB Devices")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("USB pass-through will be available in a future update.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Load Current Settings

    private func loadCurrentSettings() {
        vmName = configuration.name
        cpuCount = configuration.cpuCount
        ramSizeGB = configuration.ramSizeGB
        diskSizeGB = configuration.diskSizeGB
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

            var updated = configuration
            updated.name = vmName
            updated.cpuCount = cpuCount
            updated.ramSizeGB = ramSizeGB
            if let growTo {
                updated.diskSizeGB = growTo
            }
            vmStore.save(updated)

            let message: String
            if let growTo {
                message = "Settings saved. The disk is now \(growTo) GB. The next time you start Windows, extend drive C to use the new space. The README explains how."
            } else if isRunning {
                message = "Settings saved. Restart Windows for changes to take effect."
            } else {
                message = "Settings saved. Changes take effect the next time you start Windows."
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
