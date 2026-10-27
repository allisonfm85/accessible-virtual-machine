// SetupView.swift
// AVM — Accessible Virtual Machine

import SwiftUI
import AppKit
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
        // The disk lives where the VM is stored (2026-10-25), so the limit
        // follows the chosen drive's free space.
        let fileURL = storageFolder ?? URL(fileURLWithPath: NSHomeDirectory())
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
    /// Which Windows edition Setup installs (2026-10-25). Shown once a
    /// Windows installer is picked. Pro is the default, as it was when AVM
    /// chose without asking.
    @State private var windowsEdition: WindowsEdition = .pro
    /// Screen readers installed during Windows setup (2026-10-26). NVDA is
    /// on by default: it's free, so Windows talks from the first sign-in.
    /// JAWS needs the user's own license, so it's their choice.
    @State private var installNVDA = true
    @State private var installJAWS = false
    /// Where the VM is stored (2026-10-25, roadmap item 3). nil means on
    /// this Mac, in Application Support, as always. Otherwise a folder the
    /// user chose, usually on an external drive; AVM makes an "AVM Virtual
    /// Machines" folder inside it, and one folder per VM inside that.
    @State private var storageFolder: URL? = nil
    @State private var showingISODownload = false

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

    // Windows Setup answers (2026-10-26): what goes in this machine's
    // answer file (WindowsSetupAnswers.swift), each filled in from the Mac.
    // nil means "Let Windows ask".
    @State private var windowsLocale: String? = WindowsRegion.current().locale
    @State private var windowsKeyboard: String? = WindowsRegion.current().inputLocale
    @State private var windowsComputerName: String = ""
    @State private var windowsTimeZone: String? = WindowsSetupAnswers.windowsTimeZone(for: TimeZone.current.identifier)
    @State private var windowsPrivacy: WindowsSetupAnswers.Privacy = .mostPrivate
    @State private var windowsLocalAccount = false
    @State private var windowsDisplayName: String = NSFullUserName()
    @State private var windowsUserName: String = NSUserName()
    @State private var windowsPassword: String = ""
    @State private var windowsPasswordConfirm: String = ""

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

                storageSection

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

                    HStack {
                        Button("Choose Installer Image") {
                            showingFilePicker = true
                        }
                        .accessibilityHint("Opens a file picker to select your Windows or Ubuntu installer ISO")

                        // 2026-10-25, roadmap item 9.
                        Button("Download Windows 11 for ARM…") {
                            showingISODownload = true
                        }
                        .accessibilityHint("Opens Microsoft's download page, then tells you how the download is going and picks the file for you")
                    }
                }

                if installerKind == .windows {
                    windowsEditionSection
                    screenReaderSection
                    windowsSetupSection
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
        .sheet(isPresented: $showingISODownload) {
            ISODownloadView { url in
                installerURL = url
                identifyInstaller(url)
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

    // MARK: - Storage location

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where to Store It")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(storageDescription)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stored: \(storageDescription)")
            HStack {
                Button("Choose a Folder or Drive…") {
                    chooseStorageFolder()
                }
                .accessibilityHint("Opens a folder picker, to store this virtual machine on an external drive or in another folder")
                if storageFolder != nil {
                    Button("Store on This Mac") {
                        storageFolder = nil
                        Announcer.shared.announce("The virtual machine will be stored on this Mac.", tone: .info)
                    }
                    .accessibilityHint("Goes back to storing this virtual machine on the Mac's own disk")
                }
            }
        }
    }

    private var storageDescription: String {
        guard let folder = storageFolder else { return "On this Mac." }
        if let drive = Self.driveName(of: folder) {
            return "On the drive \(drive), in \(folder.lastPathComponent)."
        }
        return "In the folder \(folder.path)."
    }

    /// The drive's name for a folder under /Volumes, or nil on the Mac's
    /// own disk.
    private static func driveName(of url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : nil
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Store Here"
        panel.message = "Choose a drive or folder to store this virtual machine in. Windows needs 64 gigabytes or more."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storageFolder = url
        // Keep the disk size within what the new drive can hold.
        diskSizeGB = min(diskSizeGB, maxDiskInGB)
        Announcer.shared.announce("The virtual machine will be stored \(storageDescription.prefix(1).lowercased() + storageDescription.dropFirst())", tone: .info)
    }

    // MARK: - Windows edition

    private var windowsEditionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Windows Edition")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Choose the edition your Windows license is for. If you're not sure, choose Pro. AVM checks that the installer has it before installing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Windows edition", selection: $windowsEdition) {
                ForEach(WindowsEdition.allCases) { edition in
                    Text(edition.imageName).tag(edition)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Windows edition")
        }
    }

    // MARK: - Windows screen readers

    private var chosenScreenReaders: [String] {
        var names: [String] = []
        if installNVDA { names.append(ScreenReader.nvda.rawValue) }
        if installJAWS { names.append(ScreenReader.jaws.rawValue) }
        return names
    }

    private var screenReaderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Readers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Windows Setup speaks with Narrator. AVM can also install these, downloaded from their makers, so one is talking when you first sign in. If you choose both, NVDA starts at sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Install NVDA (free, from NV Access)", isOn: $installNVDA)
            Toggle("Install JAWS for ARM (from Freedom Scientific)", isOn: $installJAWS)
                .accessibilityHint("A 1.5 gigabyte download. Without a license, JAWS runs for 40 minutes at a time; activate it in Windows with your own license.")
        }
    }

    // MARK: - Windows Setup answers

    /// Regions Windows knows, by name in the Mac's language.
    private static let windowsRegions: [(id: String, name: String)] = {
        var seen = Set<String>()
        return Locale.availableIdentifiers.compactMap { WindowsRegion.windowsLocale(fromMac: $0) }
            .filter { seen.insert($0).inserted }
            .map { id in (id, Locale.current.localizedString(forIdentifier: id.replacingOccurrences(of: "-", with: "_")) ?? id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    private var suggestedComputerName: String {
        WindowsSetupAnswers.suggestedComputerName(from: vmName.isEmpty ? "AVM PC" : vmName)
    }

    private var windowsSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows Setup Answers")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Windows Setup won't ask these, so you reach your desktop sooner. Each one is filled in from your Mac; choose Let Windows ask to answer it in Windows instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Region", selection: $windowsLocale) {
                Text("Let Windows ask").tag(String?.none)
                ForEach(Self.windowsRegions, id: \.id) { region in
                    Text(region.name).tag(Optional(region.id))
                }
            }
            Picker("Keyboard", selection: $windowsKeyboard) {
                Text("Let Windows ask").tag(String?.none)
                ForEach(WindowsRegion.windowsKeyboards, id: \.id) { keyboard in
                    Text(keyboard.name).tag(Optional(keyboard.id))
                }
            }
            .accessibilityHint("The keyboard layout Windows uses. Your password types with it.")
            Picker("Time zone", selection: $windowsTimeZone) {
                Text("Let Windows set it").tag(String?.none)
                ForEach(WindowsSetupAnswers.allWindowsTimeZones, id: \.self) { zone in
                    Text(zone).tag(Optional(zone))
                }
            }
            TextField("Computer name", text: $windowsComputerName, prompt: Text(suggestedComputerName))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Computer name")
                .accessibilityHint("Up to 15 letters, digits and hyphens. Leave it empty for \(suggestedComputerName).")

            Text("Privacy")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Privacy", selection: $windowsPrivacy) {
                Text("Most private: send Microsoft no optional data").tag(WindowsSetupAnswers.Privacy.mostPrivate)
                Text("Windows' recommended settings").tag(WindowsSetupAnswers.Privacy.recommended)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Privacy")

            Text("Windows account")
                .fixedSize(horizontal: false, vertical: true)
            Picker("Windows account", selection: $windowsLocalAccount) {
                Text("Microsoft account: sign in during setup").tag(false)
                Text("Local account on this PC: no sign-in screens").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("Windows account")

            if windowsLocalAccount {
                TextField("Your name", text: $windowsDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Your name in Windows")
                TextField("User name", text: $windowsUserName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Windows user name")
                    .accessibilityHint("Up to 20 characters")
                SecureField("Password", text: $windowsPassword)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Windows password")
                    .accessibilityHint("Leave it empty to sign in with no password. AVM keeps only a scrambled form of it, until Windows is installed.")
                SecureField("Confirm password", text: $windowsPasswordConfirm)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Confirm Windows password")
                Text("Windows signs in by itself the first time, so NVDA can install and start. You can sign in to a Microsoft account later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The wizard's Windows answers, or the reason they can't be used.
    private func windowsSetupAnswers() -> Result<WindowsSetupAnswers, SetupProblem> {
        let computerName = windowsComputerName.trimmingCharacters(in: .whitespaces).isEmpty
            ? suggestedComputerName
            : windowsComputerName.trimmingCharacters(in: .whitespaces)
        if let problem = WindowsSetupAnswers.problem(withComputerName: computerName) {
            return .failure(SetupProblem(message: problem))
        }
        var answers = WindowsSetupAnswers(
            locale: windowsLocale,
            inputLocale: windowsKeyboard,
            computerName: computerName,
            timeZone: windowsTimeZone,
            privacy: windowsPrivacy
        )
        if windowsLocalAccount {
            let userName = windowsUserName.trimmingCharacters(in: .whitespaces)
            if let problem = WindowsSetupAnswers.problem(withUserName: userName, computerName: computerName) {
                return .failure(SetupProblem(message: problem))
            }
            guard windowsPassword == windowsPasswordConfirm else {
                return .failure(SetupProblem(message: "The two Windows passwords don't match. Please type them again."))
            }
            let displayName = windowsDisplayName.trimmingCharacters(in: .whitespaces)
            answers.localAccount = .init(
                userName: userName,
                displayName: displayName.isEmpty ? userName : displayName,
                encodedPassword: WindowsSetupAnswers.encode(password: windowsPassword)
            )
        }
        return .success(answers)
    }

    struct SetupProblem: Error { let message: String }

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

        var windowsAnswers: WindowsSetupAnswers? = nil
        if installerKind == .windows {
            switch windowsSetupAnswers() {
            case .success(let answers): windowsAnswers = answers
            case .failure(let problem):
                reportGuidance(problem.message)
                return
            }
        }

        // Build the disk image path in Application Support/AVM/vms/<uuid>/disk.qcow2.
        // VMManager.createDiskImage will create the actual file when the user starts
        // the VM for the first time.
        let vmID = UUID()
        let diskPath: String
        // A chosen folder gets "AVM Virtual Machines/<uuid>" inside it, so
        // the drive shows plainly what the folder is for. nil keeps the
        // Application Support layout (VMConfiguration.directoryURL).
        let storagePath = storageFolder?
            .appendingPathComponent("AVM Virtual Machines", isDirectory: true)
            .appendingPathComponent(vmID.uuidString, isDirectory: true)
            .path
        do {
            let vmDir = try VMConfiguration(id: vmID, storageFolderPath: storagePath).directoryURL()
            try FileManager.default.createDirectory(at: vmDir, withIntermediateDirectories: true)
            diskPath = vmDir.appendingPathComponent("disk.qcow2").path
            // Only the hash is stored, owner-only, until the install media
            // is built (see UbuntuInstallPipeline.swift).
            try ubuntuAccount?.save(inVMDirectory: vmDir)
            // Windows' answers, owner-only, until the media is built.
            try windowsAnswers?.save(inVMDirectory: vmDir)
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
            guestOSName: isUbuntu ? GuestOS.ubuntu.rawValue : nil,
            windowsEditionName: isUbuntu ? nil : windowsEdition.rawValue,
            storageFolderPath: storagePath,
            // Secure Boot for every new Windows VM (2026-10-25): with the
            // TPM AVM already gives it, Windows sees a PC that meets its
            // requirements, Insider builds included.
            secureBoot: isUbuntu ? nil : true,
            windowsScreenReaderNames: isUbuntu ? nil : chosenScreenReaders
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
