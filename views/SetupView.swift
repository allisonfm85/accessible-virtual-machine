// SetupView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {

    // MARK: - Environment

    @EnvironmentObject var vmStore: VMStore
    @Environment(\.dismiss) var dismiss

    // MARK: - Focus

    @AccessibilityFocusState private var isNameFieldFocused: Bool

    // MARK: - Notices
    //
    // Two kinds of spoken-and-shown message (decision of record, 2026-08-06),
    // mirroring the Stage D precedent ("no log to save yet" is .info, not
    // .failure — nothing is broken):
    //   - guidance: the form is incomplete and the user needs to know what is
    //     still required. Tone .info (Tink, enqueued). Rendered in the
    //     standard secondary style, spoken and labelled WITHOUT an "Error"
    //     prefix — it is not an error, and the visuals must tell sighted and
    //     low-vision users the same story the sounds tell.
    //   - failure: the user did everything right and creation still failed
    //     (directory creation, qemu-img, file picker). Tone .failure (Basso,
    //     interrupt-and-flush). Rendered red with the "Error:" prefix.
    // Every path routes through one helper per kind so the on-screen text and
    // the spoken text can never disagree. This replaced the silent red-text
    // rendering that predated 2026-08-06 — the exact failure mode
    // Announcer.swift exists to prevent (see the 2026-07-11 wrong-ISO
    // incident in its header).

    private struct Notice: Identifiable {
        enum Kind {
            case guidance
            case failure
        }
        let message: String
        let kind: Kind
        var id: String { message }
    }

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

    // ISO only. .ipsw was removed 2026-08-06: an IPSW is a macOS restore
    // image AVM can never install; offering it in the picker set up a late,
    // confusing pipeline failure in place of never presenting the file.
    private var allowedInstallerTypes: [UTType] {
        [UTType(filenameExtension: "iso") ?? .data]
    }

    // MARK: - State

    @State private var vmName: String = ""
    @State private var cpuCount: Int = 4
    @State private var ramSizeGB: Int = 8
    @State private var diskSizeGB: Int = 64
    @State private var installerURL: URL? = nil
    @State private var showingFilePicker = false
    @State private var notices: [Notice] = []
    @State private var isCreating = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {

            Text("Setup Wizard")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 20) {

                // VM Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Virtual Machine Name")
                        .font(.headline)
                    TextField("For example: My Windows 11", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Virtual machine name")
                        .accessibilityHint("Enter a name to identify this virtual machine")
                        .accessibilityFocused($isNameFieldFocused)
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
                        .accessibilityHint("Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount)")
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
                        .accessibilityHint("Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB")
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
                        .accessibilityHint("Adjust with arrow keys. Minimum 40 GB, maximum \(maxDiskInGB) GB based on available space")
                }

                // Graphics section removed 2026-08-06: its text promised that
                // "Windows guest drivers will provide improved display
                // performance after installation," but AVM bundles no display
                // driver (proven with positive controls, Handoff 25) — Windows
                // runs Basic Display. The wizard must not promise what never
                // happens, and an inert informational stub is noise under
                // VoiceOver in an otherwise all-controls window.

                // Windows Installer
                VStack(alignment: .leading, spacing: 6) {
                    Text("Windows Installer Image")
                        .font(.headline)
                    Text("Required: ISO file containing the Windows installer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let url = installerURL {
                        Text(url.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Selected installer: \(url.lastPathComponent)")
                    } else {
                        Text("No installer selected")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No Windows installer image selected")
                    }

                    Button("Choose Installer Image") {
                        showingFilePicker = true
                    }
                    .accessibilityHint("Opens a file picker to select your Windows installer ISO")
                }
            }
            .padding(.horizontal)

            // Notices (guidance and failures — see MARK: Notices)
            if !notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(notices) { notice in
                        switch notice.kind {
                        case .guidance:
                            Text(notice.message)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(notice.message)
                        case .failure:
                            Text(notice.message)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Error: \(notice.message)")
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.horizontal)
            }

            // Actions
            HStack(spacing: 16) {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityHint("Closes this window without creating a virtual machine")
                .keyboardShortcut(.escape, modifiers: [])

                Button(isCreating ? "Creating…" : "Create Virtual Machine") {
                    createVM()
                }
                .disabled(isCreating)
                .accessibilityLabel(isCreating ? "Creating virtual machine, please wait" : "Create Virtual Machine")
                .accessibilityHint("Saves your settings and creates the virtual machine. You can start it from the main screen.")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 600)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isNameFieldFocused = true
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: allowedInstallerTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                installerURL = urls.first
            case .failure(let error):
                reportFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Notice Reporting

    /// The form is incomplete — say what is still needed. Tone .info; no
    /// "Error" framing anywhere, because nothing is broken.
    private func reportGuidance(_ message: String) {
        notices = [Notice(message: message, kind: .guidance)]
        Announcer.shared.announce(message, tone: .info)
    }

    /// Creation actually failed. Tone .failure (Basso, interrupt) — the user
    /// acted, everything was in order, and no virtual machine resulted.
    private func reportFailure(_ message: String) {
        notices = [Notice(message: message, kind: .failure)]
        Announcer.shared.announce(message, tone: .failure)
    }

    // MARK: - Create VM

    private func createVM() {
        guard let installerURL else {
            reportGuidance("Please select a Windows installer image.")
            return
        }

        guard !vmName.trimmingCharacters(in: .whitespaces).isEmpty else {
            reportGuidance("Please enter a name for the virtual machine.")
            return
        }

        // Build the disk image path in Application Support/AVM/vms/<uuid>/disk.qcow2.
        // VMManager.createDiskImage will create the actual file when the user starts
        // the VM for the first time.
        let vmID = UUID()
        let diskPath: String
        do {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let vmDir = appSupport
                .appendingPathComponent("AVM")
                .appendingPathComponent("vms")
                .appendingPathComponent(vmID.uuidString)
            try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
            diskPath = vmDir.appendingPathComponent("disk.qcow2").path
        } catch {
            reportFailure(error.localizedDescription)
            return
        }

        let config = VMConfiguration(
            id: vmID,
            name: vmName,
            cpuCount: cpuCount,
            ramSizeGB: ramSizeGB,
            diskSizeGB: diskSizeGB,
            diskImagePath: diskPath,
            installISOPath: installerURL.path
        )

        isCreating = true
        notices = []

        Task {
            // Create the qcow2 disk image via qemu-img.
            let manager = VMManager()
            do {
                try await manager.createDiskImage(at: diskPath, sizeGB: diskSizeGB)
            } catch {
                reportFailure(error.localizedDescription)
                isCreating = false
                return
            }

            vmStore.save(config)
            isCreating = false
            dismiss()
        }
    }
}
