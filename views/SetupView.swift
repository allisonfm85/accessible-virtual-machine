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

    // MARK: - Ubuntu (2026-10-19)
    //
    // Picking the ISO decides the guest: AVM reads it (UbuntuInstallPipeline
    // .identify) and, for an Ubuntu installer, shows the account fields
    // Ubuntu's no-questions install needs up front. Any other ISO stays on
    // the Windows path, whose own validation gate speaks to a wrong file at
    // start. The result is spoken as well as shown, because the form
    // changes under the user's focus.

    private enum InstallerKind: Equatable {
        case none
        case checking
        case windows
        case ubuntu(UbuntuISOInfo)
        /// An Ubuntu ISO AVM can't install from, with the reason.
        case unusableUbuntu(String)
        /// AVM couldn't read the ISO at all, with the reason. Never taken
        /// for Windows: that would hide the real problem until Start.
        case unreadable(String)
    }

    @State private var installerKind: InstallerKind = .none
    @State private var ubuntuRealName: String = NSFullUserName()
    @State private var ubuntuUserName: String = UbuntuAccount.suggestedUserName()
    @State private var ubuntuPassword: String = ""
    @State private var ubuntuPasswordConfirm: String = ""
    @State private var ubuntuSignInAutomatically = true

    private var isUbuntu: Bool {
        if case .ubuntu = installerKind { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        // Scrolls (2026-10-25): the window has grown past small screens.
        ScrollView {
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

                // Installer
                VStack(alignment: .leading, spacing: 6) {
                    Text("Installer Image")
                        .font(.headline)
                    Text("Required: an ISO file with the Windows 11 for ARM installer, or Ubuntu Desktop for ARM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let url = installerURL {
                        Text("\(url.lastPathComponent)\(installerKindText.map { ". \($0)" } ?? "")")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Selected installer: \(url.lastPathComponent)\(installerKindText.map { ". \($0)" } ?? "")")
                    } else {
                        Text("No installer selected")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No installer image selected")
                    }

                    Button("Choose Installer Image") {
                        showingFilePicker = true
                    }
                    .accessibilityHint("Opens a file picker to select your Windows or Ubuntu installer ISO")
                }

                if isUbuntu {
                    ubuntuAccountSection
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
        }
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
                if let url = urls.first {
                    identifyInstaller(url)
                }
            case .failure(let error):
                reportFailure(error.localizedDescription)
            }
        }
    }

    // MARK: - Ubuntu account

    private var ubuntuAccountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ubuntu Account")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Ubuntu installs with no questions, so it needs your account now. Orca, Ubuntu's screen reader, will be on when Ubuntu starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Your name", text: $ubuntuRealName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Your name")
                .accessibilityHint("Shown at the Ubuntu login screen")

            TextField("User name", text: $ubuntuUserName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Ubuntu user name")
                .accessibilityHint("Lower-case letters, digits, hyphens and underscores, starting with a letter")

            // The keyboard Ubuntu gets (2026-10-25): the password must type
            // the same in Ubuntu as it does here, so this is said up front.
            Text(ubuntuKeyboardNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $ubuntuPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Ubuntu password")
                .accessibilityHint("Used to sign in and to make changes to Ubuntu. AVM keeps only a scrambled form of it, until Ubuntu is installed.")

            SecureField("Confirm password", text: $ubuntuPasswordConfirm)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Confirm Ubuntu password")

            Toggle("Sign in automatically", isOn: $ubuntuSignInAutomatically)
                .accessibilityHint("When on, Ubuntu starts straight to the desktop with no password prompt")
        }
    }

    private var ubuntuKeyboardNote: String {
        let current = UbuntuKeyboard.current()
        if let layout = current.layout {
            return "Ubuntu's keyboard will be \(layout.name), to match your Mac, so your password types the same in Ubuntu."
        }
        return "Your Mac's keyboard, \(current.macName), isn't one AVM can match, so Ubuntu will use a U.S. keyboard. Choose a password that types the same on a U.S. keyboard, such as one made of letters and digits that sit in the same places."
    }

    /// The installer's kind, as shown and spoken after the file name.
    private var installerKindText: String? {
        switch installerKind {
        case .none: return nil
        case .checking: return "Checking the installer…"
        case .windows: return nil
        case .ubuntu(let info): return "\(info.spokenName) installer"
        case .unusableUbuntu(let reason): return reason
        case .unreadable(let reason): return reason
        }
    }

    /// Read the picked ISO and say what it is. A newer pick wins over a
    /// slower, older read.
    private func identifyInstaller(_ url: URL) {
        installerKind = .checking
        notices = []
        let path = url.path
        Task {
            let identity = await UbuntuInstallPipeline.identify(isoPath: path)
            guard installerURL?.path == path else { return }
            switch identity {
            case .notUbuntu:
                installerKind = .windows
            case .unreadable(let reason):
                installerKind = .unreadable(reason)
                reportFailure(reason)
            case .ubuntu(let info):
                if let problem = UbuntuInstallPipeline.problem(with: info) {
                    installerKind = .unusableUbuntu(problem)
                    reportGuidance(problem)
                    return
                }
                installerKind = .ubuntu(info)
                Announcer.shared.announce(
                    "\(info.spokenName) installer selected. Fill in the Ubuntu account below.",
                    tone: .info
                )
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
            reportGuidance("Please select an installer image.")
            return
        }

        guard !vmName.trimmingCharacters(in: .whitespaces).isEmpty else {
            reportGuidance("Please enter a name for the virtual machine.")
            return
        }

        switch installerKind {
        case .checking:
            reportGuidance("AVM is still checking the installer. Try again in a moment.")
            return
        case .unusableUbuntu(let reason):
            reportGuidance(reason)
            return
        case .unreadable(let reason):
            reportFailure(reason)
            return
        default:
            break
        }

        var ubuntuAccount: UbuntuAccount? = nil
        if isUbuntu {
            let realName = ubuntuRealName.trimmingCharacters(in: .whitespaces)
            if let problem = UbuntuAccount.problem(withRealName: realName) {
                reportGuidance(problem)
                return
            }
            if let problem = UbuntuAccount.problem(withUserName: ubuntuUserName) {
                reportGuidance(problem)
                return
            }
            guard !ubuntuPassword.isEmpty else {
                reportGuidance("Please enter a password for the Ubuntu account.")
                return
            }
            guard ubuntuPassword == ubuntuPasswordConfirm else {
                reportGuidance("The two Ubuntu passwords don't match. Please type them again.")
                return
            }
            let keyboard = UbuntuKeyboard.current().layout
            ubuntuAccount = UbuntuAccount(
                realName: realName,
                userName: ubuntuUserName,
                passwordHash: SHA512Crypt.hash(password: ubuntuPassword),
                signInAutomatically: ubuntuSignInAutomatically,
                keyboardLayout: keyboard?.layout,
                keyboardVariant: keyboard?.variant
            )
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
            // Only the hash is stored, owner-only, until the install media
            // is built (see UbuntuInstallPipeline.swift).
            try ubuntuAccount?.save(inVMDirectory: vmDir)
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
            installISOPath: installerURL.path,
            guestOSName: isUbuntu ? GuestOS.ubuntu.rawValue : nil
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
