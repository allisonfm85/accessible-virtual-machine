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
            // No floor above what fits (2026-10-26, code audit): the
            // floor of 40 let a disk bigger than the free space be made, and
            // the install filled the Mac's disk. createVM refuses when even
            // the 40 GB minimum doesn't fit.
            return available / (1024 * 1024 * 1024) - 20
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
    /// NVDA's laptop keyboard layout (2026-10-26): a Mac keyboard has no
    /// Insert key or number pad, which desktop layout leans on.
    @State private var nvdaLaptopLayout = true
    /// Where the VM is stored (2026-10-25, roadmap item 3). nil means on
    /// this Mac, in Application Support, as always. Otherwise a folder the
    /// user chose, usually on an external drive; AVM makes an "AVM Virtual
    /// Machines" folder inside it, and one folder per VM inside that.
    @State private var storageFolder: URL? = nil
    @State private var showingISODownload = false
    /// The Windows download, watched for as long as the wizard is open,
    /// with or without its window (2026-10-27).
    @StateObject private var isoDownloader = WindowsISODownloader()

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

    /// The installer a screen opens with (2026-10-26). Always .none in the
    /// app; the accessibility audit (AccessibilityAudit.swift) also opens
    /// the wizard as it is once a Windows or an Ubuntu ISO is chosen, so
    /// the sections that only appear then are checked too. The file is
    /// never read: the kind is given, as identifyInstaller would find it.
    enum AuditInstaller { case none, windows, ubuntu }

    init(auditInstaller: AuditInstaller = .none) {
        switch auditInstaller {
        case .none:
            break
        case .windows:
            _installerURL = State(initialValue: URL(fileURLWithPath: "/Audit/Win11_25H2_English_Arm64.iso"))
            _installerKind = State(initialValue: .windows)
        case .ubuntu:
            _installerURL = State(initialValue: URL(fileURLWithPath: "/Audit/ubuntu-26.04-desktop-arm64.iso"))
            _installerKind = State(initialValue: .ubuntu(UbuntuISOInfo(
                discInfo: "Ubuntu 26.04 LTS - Release arm64", version: "26.04", isARM64: true, isDesktop: true)))
        }
    }

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

    /// "Ubuntu", "Debian" or "Fedora": the Linux the chosen installer is
    /// (2026-10-26).
    private var linuxName: String {
        linuxGuestOS.displayName
    }

    private var linuxGuestOS: GuestOS {
        guard case .ubuntu(let info) = installerKind else { return .ubuntu }
        switch info.distro {
        case .ubuntu: return .ubuntu
        case .debian: return .debian
        case .fedora: return .fedora
        }
    }

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
                    // The shown words, hidden from VoiceOver (2026-10-27, tester
                    // feedback): the field just after has the same name, and
                    // VoiceOver read the two as plain text and a field it
                    // didn't clearly call a text field. Its hint says to type.
                    Text("Virtual Machine Name")
                        .font(.headline)
                        .accessibilityHidden(true)
                    TextField("For example: My Windows 11", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Virtual machine name")
                        .accessibilityHint("Type a name for this virtual machine, such as My Windows 11.")
                        .accessibilityFocused($isNameFieldFocused)
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
                        .accessibilityHint("Adjust with arrow keys. Minimum 2, maximum \(maxCPUCount)")
                }

                // Memory
                VStack(alignment: .leading, spacing: 6) {
                    Text("Memory: \(ramSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Memory: \(ramSizeGB) gigabytes")
                    Stepper(value: $ramSizeGB, in: 4...maxMemoryInGB, step: 2) { Text("Memory in gigabytes") }
                        .labelsHidden()
                        .accessibilityHint("Adjust with arrow keys. Minimum 4 GB, maximum \(maxMemoryInGB) GB")
                }

                // Disk Size
                VStack(alignment: .leading, spacing: 6) {
                    Text("Disk Size: \(diskSizeGB) GB")
                        .font(.headline)
                        .accessibilityLabel("Disk size: \(diskSizeGB) gigabytes")
                    Stepper(value: $diskSizeGB, in: 40...max(40, maxDiskInGB), step: 10) { Text("Disk size in gigabytes") }
                        .labelsHidden()
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
                    Text("Required: an ISO file with the Windows 11 for ARM installer, Ubuntu Desktop for ARM, the Debian arm64 installer, or the Fedora Everything netinstall for aarch64.")
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
                        .accessibilityHint("Opens a file picker to select your Windows, Ubuntu, Debian or Fedora installer ISO")

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
                // Not while creating (2026-10-26, code audit): the machine
                // was made anyway after the window closed.
                .disabled(isCreating)
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
            ISODownloadView(assistant: isoDownloader) { url in
                installerURL = url
                identifyInstaller(url)
            }
        }
        .onAppear {
            // A download that finishes in the background picks itself.
            isoDownloader.onReady = { url in
                installerURL = url
                identifyInstaller(url)
            }
        }
        .onDisappear { isoDownloader.stop() }
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
            // The picker's own title names it (2026-10-26, accessibility
            // audit): with labelsHidden SwiftUI still speaks the title, and
            // an accessibilityLabel that repeats it was said twice
            // ("Windows edition, Windows edition"). Same for Privacy and
            // Windows account below.
            // A pop-up, not radio buttons (2026-10-27, user feedback): VoiceOver
            // read the radio group with Pro already chosen and nothing saying
            // there was a choice to make. "Pop-up button" says it can be
            // opened, and the hint says what to do.
            Picker("Windows edition", selection: $windowsEdition) {
                ForEach(WindowsEdition.allCases) { edition in
                    Text(edition.imageName).tag(edition)
                }
            }
            .choicePopUp("Opens the list of Windows editions. Choose the one your Windows license is for.")
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
            if installNVDA {
                Toggle("NVDA uses its laptop keyboard layout", isOn: $nvdaLaptopLayout)
                    .accessibilityHint("Recommended on a Mac keyboard, which has no Insert key or number pad. NVDA's key is then Caps Lock.")
            }
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
            .accessibilityHint("Opens the list of regions. Windows uses it for its language, dates and money.")
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
            .accessibilityHint("Opens the list of time zones for Windows' clock.")
            // A shown name for sighted users, who saw only the placeholder;
            // hidden from VoiceOver, which hears the field's own (2026-10-27,
            // tester feedback). Its hint says to type.
            Text("Computer name")
                .accessibilityHidden(true)
            TextField("Computer name", text: $windowsComputerName, prompt: Text(suggestedComputerName))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Computer name")
                .accessibilityHint("Type the name Windows gives this PC: up to 15 letters, digits and hyphens. Leave it empty for \(suggestedComputerName).")

            // The shown words, hidden from VoiceOver (2026-10-26,
            // accessibility audit): the radio group just after has the
            // same name, so VoiceOver said it twice in a row.
            Text("Privacy")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Picker("Privacy", selection: $windowsPrivacy) {
                Text("Most private: send Microsoft no optional data").tag(WindowsSetupAnswers.Privacy.mostPrivate)
                Text("Windows' recommended settings").tag(WindowsSetupAnswers.Privacy.recommended)
            }
            .choicePopUp("Opens the privacy choices. Choose how much Windows sends Microsoft.")

            Text("Windows account")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Picker("Windows account", selection: $windowsLocalAccount) {
                Text("Microsoft account: sign in during setup").tag(false)
                Text("Local account on this PC: no sign-in screens").tag(true)
            }
            .choicePopUp("Opens the account choices. Choose how you'll sign in to Windows.")

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
            privacy: windowsPrivacy,
            nvdaLaptopLayout: installNVDA ? nvdaLaptopLayout : false
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
            Text("\(linuxName) Account")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("\(linuxName) installs with no questions, so it needs your account now. Orca, the screen reader, will be on when \(linuxName) starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Your name", text: $ubuntuRealName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Your name")
                .accessibilityHint("Shown at the \(linuxName) login screen")

            TextField("User name", text: $ubuntuUserName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(linuxName) user name")
                .accessibilityHint("Lower-case letters, digits, hyphens and underscores, starting with a letter")

            // The keyboard Ubuntu gets (2026-10-25): the password must type
            // the same in Ubuntu as it does here, so this is said up front.
            Text(ubuntuKeyboardNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $ubuntuPassword)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(linuxName) password")
                .accessibilityHint("Used to sign in and to make changes to \(linuxName). AVM keeps only a scrambled form of it, until \(linuxName) is installed.")

            SecureField("Confirm password", text: $ubuntuPasswordConfirm)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Confirm \(linuxName) password")

            Toggle("Sign in automatically", isOn: $ubuntuSignInAutomatically)
                .accessibilityHint("When on, \(linuxName) starts straight to the desktop with no password prompt")
        }
    }

    private var ubuntuKeyboardNote: String {
        let current = UbuntuKeyboard.current()
        if let layout = current.layout {
            return "\(linuxName)'s keyboard will be \(layout.name), to match your Mac, so your password types the same in \(linuxName)."
        }
        return "Your Mac's keyboard, \(current.macName), isn't one AVM can match, so \(linuxName) will use a U.S. keyboard. Choose a password that types the same on a U.S. keyboard, such as one made of letters and digits that sit in the same places."
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
                    "\(info.spokenName) installer selected. Fill in the \(linuxName) account below.",
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

        // The disk must fit, with 20 GB to spare for the Mac (2026-10-26,
        // code audit): disks are made sparse, so a too-big one was made
        // without complaint and the install filled the Mac's disk.
        guard maxDiskInGB >= 40 else {
            reportGuidance("There isn't room for a virtual machine on this drive: it needs at least 40 gigabytes, plus 20 to spare. Free some space, or choose another drive for it.")
            return
        }
        if diskSizeGB > maxDiskInGB {
            diskSizeGB = maxDiskInGB
            reportGuidance("The disk is now \(maxDiskInGB) gigabytes, the most that fits on this drive with 20 to spare. Choose Create again to use it.")
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
                reportGuidance("Please enter a password for the \(linuxName) account.")
                return
            }
            guard ubuntuPassword == ubuntuPasswordConfirm else {
                reportGuidance("The two \(linuxName) passwords don't match. Please type them again.")
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

        var config = VMConfiguration(
            id: vmID,
            name: vmName,
            cpuCount: cpuCount,
            ramSizeGB: ramSizeGB,
            diskSizeGB: diskSizeGB,
            diskImagePath: diskPath,
            installISOPath: installerURL.path,
            guestOSName: isUbuntu ? linuxGuestOS.rawValue : nil,
            windowsEditionName: isUbuntu ? nil : windowsEdition.rawValue,
            storageFolderPath: storagePath,
            // Secure Boot for every new Windows VM (2026-10-25): with the
            // TPM AVM already gives it, Windows sees a PC that meets its
            // requirements, Insider builds included.
            secureBoot: isUbuntu ? nil : true,
            windowsScreenReaderNames: isUbuntu ? nil : chosenScreenReaders
        )
        // A disk QEMU can save while the machine runs (2026-10-27).
        config.diskBus = "virtio"

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
                // Nothing left behind (2026-10-26, code audit): the folder
                // already holds the setup answers, the Windows password among
                // them.
                if let folder = try? config.directoryURL() {
                    if config.isStoredElsewhere {
                        // The user's own folder: only AVM's answer files go.
                        for name in [WindowsSetupAnswers.fileName, UbuntuAccount.fileName] {
                            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                        }
                    } else {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
                return
            }

            vmStore.save(config)
            isCreating = false
            // Said, as failures are (2026-10-26, code audit).
            Announcer.shared.announce("\(config.name) is ready. Choose Start on the dashboard to install \(config.guestOS.displayName).", tone: .success)
            dismiss()
        }
    }
}
