// MacSetupView.swift
// AVM — Accessible Virtual Machine
//
// New macOS Virtual Machine (2026-10-26): the setup sheet for a macOS
// machine (MacGuest.swift). macOS comes from Apple, the newest version
// this Mac supports, or from an IPSW file the user already has. AVM
// downloads it, installs it, and says how far it has got throughout; the
// machine joins the dashboard list when the install has finished. macOS's
// own Setup Assistant then runs at the first Start, where VoiceOver is
// offered by macOS itself.

import SwiftUI
import AppKit

struct MacSetupView: View {
    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss

    @State private var name = "macOS"
    @State private var cpuCount = 4
    @State private var ramSizeGB = 8
    @State private var diskSizeGB = 80
    @State private var ipsw: URL?
    @State private var useIPSW = false
    @State private var progress: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    private let maxCores = max(2, ProcessInfo.processInfo.processorCount / 2)
    private let maxMemoryGB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("New macOS Virtual Machine")
                    .font(.title)
                    .accessibilityAddTraits(.isHeader)
                Text("macOS runs on Apple's own virtualization. AVM gets macOS from Apple and installs it, saying how far it has got. macOS's Setup Assistant then runs the first time you start the machine, and offers VoiceOver itself: press Escape when it speaks. To use VoiceOver inside the machine, turn your Mac's VoiceOver off with Command-F5 while you work there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Virtual machine name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Virtual machine name")
                Stepper("Cores: \(cpuCount)", value: $cpuCount, in: 2...maxCores)
                Stepper("Memory: \(ramSizeGB) GB", value: $ramSizeGB, in: 4...maxMemoryGB, step: 2)
                Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: 64...1000, step: 16)
                    .accessibilityHint("The disk file takes only the space macOS uses, up to this size.")

                Text("Where macOS comes from")
                Picker("Where macOS comes from", selection: $useIPSW) {
                    Text("Download the newest macOS this Mac supports, from Apple").tag(false)
                    Text("Use a macOS installer file (IPSW) I have").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityLabel("Where macOS comes from")
                if useIPSW {
                    HStack {
                        Button("Choose IPSW File…") { chooseIPSW() }
                        Text(ipsw?.lastPathComponent ?? "No file chosen")
                    }
                }

                if let progress {
                    Text(progress)
                        .accessibilityAddTraits(.updatesFrequently)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(working)
                    Button(working ? "Installing, please wait…" : "Create macOS Virtual Machine") { create() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(working)
                }
                if working {
                    Text("Keep this window open. A download and install take 20 minutes to over an hour; AVM speaks each step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { nameFocused = true }
    }

    private func chooseIPSW() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Choose a macOS installer file (.ipsw)."
        if panel.runModal() == .OK, let url = panel.url {
            ipsw = url
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            Announcer.shared.announce("Please enter a name for the virtual machine.", tone: .info)
            return
        }
        if useIPSW && ipsw?.pathExtension.lowercased() != "ipsw" {
            Announcer.shared.announce("Please choose a macOS installer file ending in .ipsw, or choose to download macOS from Apple.", tone: .info)
            return
        }
        let id = UUID()
        var config = VMConfiguration(id: id, name: trimmed, cpuCount: cpuCount, ramSizeGB: ramSizeGB,
                                     diskSizeGB: diskSizeGB, guestOSName: GuestOS.macOS.rawValue)
        guard let folder = try? config.directoryURL() else { return }
        config.diskImagePath = MacGuestFiles(folder: folder).disk.path
        working = true
        let installer = MacInstaller()
        installer.onProgress = { progress = $0 }
        Task { @MainActor in
            do {
                try await installer.install(config, ipsw: useIPSW ? ipsw : nil)
                vmStore.save(config)
                Announcer.shared.announce("\(trimmed) is ready. Choose Start on the dashboard; macOS's Setup Assistant runs first.", tone: .success)
                working = false
                dismiss()
            } catch {
                try? FileManager.default.removeItem(at: folder)
                progress = "Not made. Reason: \(error.localizedDescription)"
                Announcer.shared.announce("The macOS machine was not made. Reason: \(error.localizedDescription)", tone: .failure)
                working = false
            }
        }
    }
}

/// Settings for a macOS machine: name, cores, memory and a shared folder.
/// Windows' settings (USB, Secure Boot, restore points and the rest) are
/// QEMU's and don't apply.
struct MacSettingsView: View {
    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss
    let configuration: VMConfiguration
    let isRunning: Bool

    @State private var name = ""
    @State private var cpuCount = 4
    @State private var ramSizeGB = 8
    @State private var sharedFolderPath: String?
    @State private var sharedFolderReadOnly = false

    private let maxCores = max(2, ProcessInfo.processInfo.processorCount / 2)
    private let maxMemoryGB = max(4, Int(ProcessInfo.processInfo.physicalMemory >> 30) / 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings for \(configuration.name)")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            if isRunning || MacGuestRunner.shared.runningID == configuration.id {
                Text("Shut \(configuration.name) down to change its settings.")
                    .foregroundStyle(.secondary)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Virtual machine name")
            Stepper("Cores: \(cpuCount)", value: $cpuCount, in: 2...maxCores)
            Stepper("Memory: \(ramSizeGB) GB", value: $ramSizeGB, in: 4...maxMemoryGB, step: 2)

            Text("Shared Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(sharedFolderPath.map { "Sharing: \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "No folder is shared.")
            HStack {
                Button(sharedFolderPath == nil ? "Choose Folder to Share…" : "Choose a Different Folder…") { chooseFolder() }
                if sharedFolderPath != nil {
                    Button("Stop Sharing") { sharedFolderPath = nil }
                }
            }
            if sharedFolderPath != nil {
                Toggle("macOS in the machine can only read it", isOn: $sharedFolderReadOnly)
            }
            Text("It appears in the machine's Finder as My Shared Files, in Locations.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save Settings") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isRunning || MacGuestRunner.shared.runningID == configuration.id)
            }
        }
        .padding(28)
        .frame(minWidth: 460)
        .onAppear {
            name = configuration.name
            cpuCount = configuration.cpuCount
            ramSizeGB = configuration.ramSizeGB
            sharedFolderPath = configuration.sharedFolderPath
            sharedFolderReadOnly = configuration.sharedFolderIsReadOnly
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Share"
        if panel.runModal() == .OK, let url = panel.url { sharedFolderPath = url.path }
    }

    private func save() {
        var updated = configuration
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmed.isEmpty ? configuration.name : trimmed
        updated.cpuCount = cpuCount
        updated.ramSizeGB = ramSizeGB
        updated.sharedFolderPath = sharedFolderPath
        updated.sharedFolderReadOnly = sharedFolderReadOnly ? true : nil
        vmStore.save(updated)
        Announcer.shared.announce("Settings saved.", tone: .success)
        dismiss()
    }
}
