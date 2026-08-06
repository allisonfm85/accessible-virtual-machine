// SettingsView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    // MARK: - Environment

    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss

    // MARK: - Session

    let session: VMSession

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

    private var maxDiskInGB: Int {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            return max(40, available / (1024 * 1024 * 1024) - 20)
        }
        return 500
    }

    // MARK: - State

    @State private var vmName: String = ""
    @State private var cpuCount: Int = 4
    @State private var ramSizeGB: Int = 8
    @State private var diskSizeGB: Int = 64
    @State private var sharedFolderURL: URL? = nil
    @State private var showingFolderPicker = false
    @State private var validationErrors: [String] = []
    @State private var isSaving = false
    @State private var saveSuccess = false

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
                        .accessibilityHint("Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount). Changes take effect after restarting Windows.")
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
                        .accessibilityHint("Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB. Changes take effect after restarting Windows.")
                }

                // Disk Size
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disk Size: \(diskSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Disk size: \(diskSizeGB) gigabytes")
                    Stepper("Disk Size", value: $diskSizeGB, in: 40...maxDiskInGB, step: 10)
                        .labelsHidden()
                        .accessibilityLabel("Disk size in gigabytes")
                        .accessibilityValue("\(diskSizeGB) gigabytes")
                        .accessibilityHint("Adjust with arrow keys. Minimum 40 GB, maximum \(maxDiskInGB) GB. Disk size can only be increased, not reduced.")
                }

                // Shared Folder
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared Folder")
                        .font(.headline)
                    Text("Files placed in this folder will be accessible from both Mac and Windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = sharedFolderURL {
                        Text(url.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Current shared folder: \(url.path)")
                    } else {
                        Text("No shared folder selected.")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No shared folder selected.")
                    }
                    HStack(spacing: 12) {
                        Button("Choose Folder") {
                            showingFolderPicker = true
                        }
                        .accessibilityHint("Opens a folder picker to select a folder to share between Mac and Windows")
                        if sharedFolderURL != nil {
                            Button("Remove Shared Folder") {
                                sharedFolderURL = nil
                            }
                            .accessibilityHint("Removes the shared folder. Files will no longer be shared between Mac and Windows.")
                        }
                    }
                }

                if saveSuccess {
                    Text("Settings saved. Restart Windows for changes to take effect.")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Settings saved successfully. Restart Windows for changes to take effect.")
                }
            }
            .padding(.horizontal)

            if !validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationErrors, id: \.self) { error in
                        Text(error)
                            .foregroundStyle(.red)
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
                .accessibilityHint("Saves your changes. Restart Windows for changes to take effect.")
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
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                sharedFolderURL = urls.first
            case .failure(let error):
                validationErrors = [error.localizedDescription]
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
        let config = session.configuration
        vmName = config.name
        cpuCount = config.cpuCount
        ramSizeGB = config.ramSizeGB
        diskSizeGB = config.diskSizeGB
        if let path = config.sharedFolderPath {
            sharedFolderURL = URL(fileURLWithPath: path)
        }
    }

    // MARK: - Save Settings

    private func saveSettings() {
        guard !vmName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationErrors = ["Virtual machine name cannot be empty."]
            return
        }
        validationErrors = []
        isSaving = true

        var updated = session.configuration
        updated.name = vmName
        updated.cpuCount = cpuCount
        updated.ramSizeGB = ramSizeGB
        updated.diskSizeGB = diskSizeGB
        updated.sharedFolderPath = sharedFolderURL?.path

        vmStore.save(updated)
        isSaving = false
        saveSuccess = true
    }
}
