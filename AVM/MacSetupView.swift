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
                Text("macOS runs on Apple's own virtualization. AVM gets macOS from Apple and installs it, saying how far it has got. macOS's Setup Assistant then runs the first time you start the machine, and offers VoiceOver itself: give macOS the keyboard, wait about a minute on its first screen, and press Escape when it speaks. macOS keeps VoiceOver on after that. To use VoiceOver inside the machine, turn your Mac's VoiceOver off with Command-F5 while you work there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Virtual machine name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Virtual machine name")
                // Each stepper said its words twice (2026-10-26, accessibility
                // audit): SwiftUI shows a stepper's title as text and also
                // names the stepper with it ("Cores: 4", then "Cores: 4, 4,
                // stepper"). The text keeps the number; the stepper is named
                // without it, and gigabytes are said in full, as in the
                // Setup Wizard.
                Stepper(value: $cpuCount, in: 2...maxCores) { Text("Cores: \(cpuCount)") }
                    .accessibilityLabel("Cores")
                Stepper(value: $ramSizeGB, in: 4...maxMemoryGB, step: 2) {
                    Text("Memory: \(ramSizeGB) GB").accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
                }
                .accessibilityLabel("Memory in gigabytes")
                Stepper(value: $diskSizeGB, in: 64...1000, step: 16) {
                    Text("Disk: \(diskSizeGB) GB").accessibilityLabel("Disk: \(diskSizeGB) gigabytes")
                }
                .accessibilityLabel("Disk size in gigabytes")
                .accessibilityHint("The disk file takes only the space macOS uses, up to this size.")

                // The radio group is named by its own title (2026-10-26,
                // accessibility audit): an accessibilityLabel repeating it
                // was said twice, and so was this text just before it,
                // which stays on screen but is hidden from VoiceOver.
                Text("Where macOS comes from")
                    .accessibilityHidden(true)
                Picker("Where macOS comes from", selection: $useIPSW) {
                    Text("Download the newest macOS this Mac supports, from Apple").tag(false)
                    Text("Use a macOS installer file (IPSW) I have").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
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
                    Text("Keep this window open. The download is large (26 GB for macOS 27) and is kept for your next macOS machine; the install itself takes a few minutes. AVM speaks each step.")
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
        config.macVoiceOverOffered = false
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
    @State private var shareClipboard = true
    @State private var restorePoints: [MacRestorePoint] = []
    @State private var newPointName = ""
    @State private var restoreMessage: String?

    private var files: MacGuestFiles? {
        (try? configuration.directoryURL()).map { MacGuestFiles(folder: $0) }
    }
    private var running: Bool { isRunning || MacGuestRunner.shared.runningID == configuration.id }
    /// Saved with Save and Quit: its disk is mid-session, its memory in the
    /// saved file (MacGuestRunner.saveAndStop).
    private var saved: Bool {
        files.map { FileManager.default.fileExists(atPath: $0.savedState.path) } ?? false
    }

    /// Asked at the moment of acting, not when the sheet opened (2026-10-26,
    /// code audit): the machine can start while Settings is open, and a
    /// restore under a running machine swaps its disk from under it.
    private func refusedWhileRunningOrSaved() -> Bool {
        if MacGuestRunner.shared.runningID == configuration.id {
            say("Shut \(configuration.name) down first.", .failure)
            return true
        }
        if saved {
            say("\(configuration.name) is saved with its apps open, so its disk is mid-session. Start it and shut it down first.", .failure)
            return true
        }
        return false
    }

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
            // Named once, as in New macOS Virtual Machine (2026-10-26).
            Stepper(value: $cpuCount, in: 2...maxCores) { Text("Cores: \(cpuCount)") }
                .accessibilityLabel("Cores")
            Stepper(value: $ramSizeGB, in: 4...maxMemoryGB, step: 2) {
                Text("Memory: \(ramSizeGB) GB").accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
            }
            .accessibilityLabel("Memory in gigabytes")

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
            Text(shareClipboard
                 ? "It appears in the machine's Finder in Locations, My Shared Files, under its own name."
                 : "It appears in the machine's Finder as My Shared Files, in Locations.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Clipboard")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Toggle("Share the clipboard with \(configuration.name)", isOn: $shareClipboard)
            Text("Text copied on the Mac can be pasted in macOS, and the other way round. Once, in macOS: open Finder, Locations, My Shared Files, AVM Clipboard, and open Install Clipboard Sharing. Takes effect at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            restorePointsSection

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
            shareClipboard = configuration.sharesClipboard
            reloadPoints()
        }
    }

    // MARK: Restore points (2026-10-26)

    private var restorePointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Restore Points")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(running
                 ? "Shut \(configuration.name) down to take or use a restore point."
                 : "A restore point keeps \(configuration.name)'s disk as it is now. Taking one is instant and uses space only for what changes afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Name for a new restore point", text: $newPointName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name for a new restore point")
                Button("Take Restore Point") { takePoint() }
                    .disabled(running)
            }
            if restorePoints.isEmpty {
                Text("No restore points yet.")
            }
            ForEach(restorePoints) { point in
                HStack {
                    Text("\(point.name), \(point.date.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Button("Restore") { restore(point) }
                        .disabled(running)
                        .accessibilityLabel("Restore \(point.name)")
                    Button("Delete") { delete(point) }
                        .accessibilityLabel("Delete \(point.name)")
                }
                .accessibilityElement(children: .contain)
            }
            if let restoreMessage {
                Text(restoreMessage)
                    .accessibilityAddTraits(.updatesFrequently)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reloadPoints() {
        restorePoints = files.map(MacRestorePoints.list) ?? []
    }

    private func say(_ message: String, _ tone: Announcer.Tone) {
        restoreMessage = message
        Announcer.shared.announce(message, tone: tone)
    }

    private func takePoint() {
        guard let files, !refusedWhileRunningOrSaved() else { return }
        let trimmed = newPointName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "Restore point" : trimmed
        do {
            try MacRestorePoints.take(files, name: name)
            newPointName = ""
            reloadPoints()
            say("Restore point \(name) taken.", .success)
        } catch {
            say("The restore point wasn't taken. Reason: \(error.localizedDescription)", .failure)
        }
    }

    private func restore(_ point: MacRestorePoint) {
        guard let files, !refusedWhileRunningOrSaved() else { return }
        let alert = NSAlert()
        alert.messageText = "Put \(configuration.name) back to \(point.name)?"
        alert.informativeText = "Everything done in \(configuration.name) since then is lost, unless you take a restore point of it first. The restore point itself is kept."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try MacRestorePoints.restore(point, into: files)
            say("\(configuration.name) is back to \(point.name).", .success)
        } catch {
            say("\(configuration.name) wasn't restored. Reason: \(error.localizedDescription)", .failure)
        }
    }

    private func delete(_ point: MacRestorePoint) {
        let alert = NSAlert()
        alert.messageText = "Delete the restore point \(point.name)?"
        alert.informativeText = "\(configuration.name) itself isn't changed; you just can't go back to this point afterwards."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try MacRestorePoints.delete(point)
            reloadPoints()
            say("Restore point \(point.name) deleted.", .success)
        } catch {
            say("The restore point wasn't deleted. Reason: \(error.localizedDescription)", .failure)
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
        guard MacGuestRunner.shared.runningID != configuration.id else {
            Announcer.shared.announce("Shut \(configuration.name) down to change its settings.", tone: .failure)
            return
        }
        // A saved machine resumes only on the configuration it was saved
        // with (2026-10-26, code audit): asked first, and the saved session
        // let go of, so the next Start is a plain start, not a failed resume.
        let changesMachine = cpuCount != configuration.cpuCount || ramSizeGB != configuration.ramSizeGB
            || sharedFolderPath != configuration.sharedFolderPath
            || (sharedFolderReadOnly ? true : nil) != configuration.sharedFolderReadOnly
            || shareClipboard != configuration.sharesClipboard
        if saved && changesMachine, let files {
            let alert = NSAlert()
            alert.messageText = "\(configuration.name) is saved with its apps open. Change its settings anyway?"
            alert.informativeText = "These changes mean it can't carry on where it was: its next Start is a normal start, as after a power cut, and anything unsaved in its apps is lost. To keep it, choose Cancel, start it, and shut it down from macOS first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Change Settings")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            try? FileManager.default.removeItem(at: files.savedState)
        }
        var updated = vmStore.configurations.first { $0.id == configuration.id } ?? configuration
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        updated.name = trimmed.isEmpty ? configuration.name : trimmed
        updated.cpuCount = cpuCount
        updated.ramSizeGB = ramSizeGB
        updated.sharedFolderPath = sharedFolderPath
        updated.sharedFolderReadOnly = sharedFolderReadOnly ? true : nil
        updated.shareClipboard = shareClipboard ? nil : false
        vmStore.save(updated)
        Announcer.shared.announce("Settings saved.", tone: .success)
        dismiss()
    }
}
