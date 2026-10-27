// UbuntuInstallPipeline.swift
// AVM — Accessible Virtual Machine
//
// Builds the install media for an Ubuntu desktop ARM64 virtual machine, so
// Ubuntu installs with no questions and starts with Orca speaking, at the
// login screen and after. The counterpart of WindowsInstallPipeline, and it
// produces the SAME TWO FILES under the same names, so everything that keys
// on them works unchanged for Ubuntu:
//   - install-avm.iso   the user's installer with the answers added
//   - autounattend.img  the 8 MB FAT volume labeled UNATTEND, the home of
//                       the AVMDONE.TAG install-complete marker. The
//                       REINSTALL GUARD (VMManager.checkInstallCompleteMarker)
//                       reads it exactly as it does for Windows.
// Debian (preseed) and Fedora (kickstart) installers go through the same
// pipeline with their own answer files; see their MARK sections below.
//
// HOW UBUNTU INSTALLS WITH NO QUESTIONS (approach proven first in Parallels
// Manager's install-ubuntu.sh, then in AVM's own QEMU set-up, 2026-10-19):
//   Ubuntu's desktop installer reads an autoinstall answer file (cloud-init
//   NoCloud format) when the kernel is started with
//   `autoinstall ds=nocloud;s=/cdrom/nocloud/`. The pipeline adds a
//   /nocloud folder to a copy of the ISO and edits /boot/grub/grub.cfg to
//   boot the first entry at once with those words. No ISO extraction: the
//   bundled xorriso maps the two changes onto the original image and
//   replays its boot records (`-boot_image any replay`), so the build takes
//   seconds and needs scratch space only for the output.
//
// THE DESKTOP INSTALLER, NOT THE SERVER ONE (lesson carried over from
// Parallels Manager): only the desktop image brings the desktop, Firefox and
// Orca. The validation gate hard-stops on a server image with a spoken
// reason, instead of an install that ends at a text console a blind user
// cannot be told about.
//
// THE REINSTALL HAZARD IS WORSE THAN WINDOWS', AND IS CLOSED TWICE:
//   Windows Setup needs a key press to boot from the install media, so a
//   reboot after the install falls through to the disk. Ubuntu's boot menu
//   needs nothing — it would start the answer file again and wipe the disk
//   it just installed. So:
//   1. The answer file ends with `shutdown: poweroff`, never a reboot.
//      VMManager sees the clean exit with the marker present and starts the
//      machine again itself; that start finds the marker and attaches no
//      install media (the existing REINSTALL GUARD).
//   2. The edited boot menu's FIRST line looks for AVMDONE.TAG and, when it
//      finds it, hands back to the firmware, which boots the disk. Even if
//      the install media were somehow attached after an install, the
//      answer file never runs again.
//   The marker is written by the answer file's last step (late-commands),
//   after everything else has succeeded, the same "the OS is on the disk"
//   meaning it has for Windows. A failed install writes AVMFAIL.TAG and
//   powers off instead (failureScript), so a failure is announced rather
//   than left on a silent error screen.
//
// THE ACCOUNT: Ubuntu's answer file needs the user name and the password
// hash up front (the Windows path leaves the account to OOBE, which Narrator
// reads; Ubuntu's own first-run screens are not something AVM can count on
// Orca reading). The Setup Wizard collects them, hashes the password at once
// (SHA512Crypt) and stores only the hash, in ubuntu-account.json in the VM's
// folder, owner-only. The pipeline reads it, writes it into the answer file
// and deletes the JSON. The hash then lives only inside install-avm.iso,
// which VMManager deletes once the install is complete — Ubuntu's media is
// never needed again, and that also gives back 4 GB.
//
// ACCESSIBILITY SET IN THE ANSWER FILE (late-commands, setup.sh):
//   - Orca on at the login screen and in the user's session.
//   - Orca's laptop layout, whose Orca key is Caps Lock. A Mac has no
//     Insert key, and AVM already delivers a genuine held Caps Lock to the
//     guest (CapsLockRemapper), so Caps Lock is the Orca key that works.
//     Orca 50 (Ubuntu 26.04) keeps it at
//     /org/gnome/orca/default/keybindings/keyboard-layout, a relocatable
//     schema; a key anywhere else is silently ignored (proven in the
//     guest with gsettings, 2026-10-19).
//   - Sign in automatically, when the user asked for it in the wizard.
//   - No screen lock, no idle blanking, no automatic suspend: a locked or
//     suspended guest is silent, and silence reads as broken. Ubuntu does
//     not know it runs in a VM under AVM's HVF set-up (systemd-detect-virt
//     says "none"), so without this GNOME suspends it when idle.
//   - No first-run wizard (gnome-initial-setup) and no crash-report
//     prompts. Ubuntu 26.04 also starts a per-release welcome tour
//     (gnome-initial-setup --upgrade-user, a systemd user unit) unless
//     ~/.config/gnome-initial-setup/upgrade-<VERSION_ID>-done exists; it
//     opened over the desktop on the first test install.
//   - The UNATTEND volume hidden from the desktop (a udisks rule): it
//     stays attached for the marker, and would otherwise show up as a
//     USB drive in Files and in Orca's announcements.
//   - The SPICE guest agent (spice-vdagent), for absolute mouse
//     positioning (issue #4 mechanism: two display channels need the agent),
//     with its audio volume sync disarmed. PROVEN IN-APP 2026-10-19: on
//     every SPICE connect (each Enter Ubuntu) the agent set Ubuntu's master
//     volume to 0, the volume AVM's SPICE client reports, so Orca ran but
//     was silent. Stopping the agent kept the sound; running it with an
//     ALSA configuration that has no mixer (a systemd user drop-in) kept
//     the sound AND client-mode mouse. The Windows agent is not affected.
//
// CONCURRENCY: the same model as WindowsInstallPipeline — run() is
// @concurrent, tools run on a background GCD queue inside a continuation,
// and progress hops to the main actor before each stage begins.
//
// The tool-running helpers are a small, deliberate duplicate of
// WindowsInstallPipeline's private ones rather than a shared refactor: that
// pipeline is boot-proven, and this change does not touch it.

import Foundation
import Carbon

/// PRIVACY: through AVMLog's sanitizer, like pipelineLog. Never logs the
/// answer file itself (it holds the password hash).
nonisolated private func ubuntuLog(_ msg: String) {
    AVMLog.write(msg, category: "ubuntu-pipeline")
}

// MARK: - The account

/// What the Setup Wizard collects for an Ubuntu VM. Stored as
/// ubuntu-account.json in the VM's folder until the pipeline uses it.
nonisolated struct UbuntuAccount: Codable, Equatable {
    /// The full name shown at the login screen, e.g. "Kelly Ford".
    var realName: String
    /// The Linux user name: lower case, starting with a letter.
    var userName: String
    /// SHA-512 crypt ("$6$…"), never the password itself.
    var passwordHash: String
    /// Sign in at startup with no password prompt.
    var signInAutomatically: Bool
    /// Ubuntu's keyboard layout and variant, matching the Mac's layout when
    /// the VM was made (2026-10-25, code audit; see UbuntuKeyboard). nil
    /// means US, as before. The password is typed on the Mac with its own
    /// layout, and the guest receives key positions, so a US guest under an
    /// AZERTY or QWERTZ Mac turned the password into different characters
    /// at the login screen, locking the user out.
    var keyboardLayout: String? = nil
    var keyboardVariant: String? = nil

    static let fileName = "ubuntu-account.json"

    /// Why `name` can't be a user name, or nil when it can. Ubuntu's own
    /// rule: lower-case letters, digits, hyphen and underscore, starting
    /// with a letter, at most 32 characters. A few names belong to the
    /// system already.
    static func problem(withUserName name: String) -> String? {
        if name.isEmpty {
            return "Please enter a user name for Ubuntu."
        }
        guard name.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            return "The user name can use only lower-case letters, digits, hyphens and underscores, and must start with a letter."
        }
        // Ubuntu Desktop's own users and groups (widened 2026-10-25, code
        // audit): "audio" or "video" used to pass here and then fail useradd
        // 15 silent minutes into the install.
        let reserved: Set<String> = ["root", "daemon", "bin", "sys", "sync", "games", "man", "lp",
                                     "mail", "news", "uucp", "proxy", "www-data", "backup", "list",
                                     "irc", "nobody", "nogroup", "messagebus", "syslog",
                                     "gdm", "admin", "sudo", "ubuntu", "adm", "tty", "disk", "kmem",
                                     "dialout", "fax", "voice", "cdrom", "floppy", "tape", "audio",
                                     "dip", "video", "plugdev", "staff", "users", "operator", "src",
                                     "shadow", "utmp", "sasl", "input", "sgx", "kvm", "render",
                                     "netdev", "lpadmin", "sambashare", "lxd", "polkitd", "avahi",
                                     "pulse", "pulse-access", "colord", "geoclue", "rtkit", "saned",
                                     "tss", "uuidd", "tcpdump", "usbmux", "whoopsie", "kernoops",
                                     "dnsmasq", "cups-pk-helper", "fwupd-refresh", "gnome-initial-setup",
                                     "speech-dispatcher", "nm-openvpn", "sssd", "landscape", "pollinate",
                                     "snapd", "crontab", "ssl-cert", "bluetooth", "scanner", "wheel",
                                     // Fedora Workstation's own (2026-10-26).
                                     "ftp", "halt", "shutdown", "dbus", "chrony", "pipewire", "flatpak",
                                     "unbound", "rpc", "rpcuser", "usbmuxd", "abrt", "setroubleshoot",
                                     "qemu", "brlapi", "pesign", "wsdd", "saslauth", "openvpn",
                                     "nm-openconnect", "passim", "dhcpcd"]
        if reserved.contains(name) || name.hasPrefix("systemd-") {
            return "Ubuntu keeps the name \(name) for itself. Please choose another user name."
        }
        return nil
    }

    /// Why `name` can't be the account's full name, or nil when it can.
    /// Ubuntu's installer refuses : , and = there (the account database
    /// uses them as separators) and more than 160 characters. Caught here,
    /// not 15 silent minutes into the install (code review, 2026-10-19).
    static func problem(withRealName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Please enter your name for the Ubuntu account."
        }
        if trimmed.unicodeScalars.count > 160 {   // the installer counts code points
            return "Your name for the Ubuntu account can be at most 160 characters."
        }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ":,=").union(.controlCharacters)) != nil {
            return "Your name for the Ubuntu account can't contain a colon, a comma or an equals sign."
        }
        return nil
    }

    /// A suggested user name from the Mac's own short name.
    static func suggestedUserName() -> String {
        let lowered = NSUserName().lowercased()
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9_-]", with: "", options: .regularExpression)
        let trimmed = cleaned.drop(while: { !$0.isLetter })
        let candidate = String(trimmed.prefix(32))
        return problem(withUserName: candidate) == nil ? candidate : ""
    }

    // MARK: Storage

    /// Owner-only from the first byte (2026-10-25, code audit): writing
    /// first and chmodding after left a moment, or a failed chmod, in which
    /// the hash sat in a file anyone on the Mac could read.
    func save(inVMDirectory dir: URL) throws {
        let url = dir.appendingPathComponent(Self.fileName)
        let data = try JSONEncoder().encode(self)
        Darwin.unlink(url.path)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { Darwin.close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    /// The saved account, checked again (2026-10-25, code audit): the user
    /// name goes unquoted into a script that runs as root in the installer,
    /// so a file edited by hand must not be able to put anything else there.
    static func load(fromVMDirectory dir: URL) -> UbuntuAccount? {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let account = try? JSONDecoder().decode(UbuntuAccount.self, from: data) else { return nil }
        guard problem(withUserName: account.userName) == nil,
              problem(withRealName: account.realName) == nil else {
            ubuntuLog("UbuntuAccount.load: the saved account fails its own checks; not using it")
            return nil
        }
        if let layout = account.keyboardLayout, layout.range(of: "^[a-z]{2,8}$", options: .regularExpression) == nil {
            return nil
        }
        if let variant = account.keyboardVariant, variant.range(of: "^[a-z_]{1,16}$", options: .regularExpression) == nil {
            return nil
        }
        return account
    }

    static func delete(fromVMDirectory dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }
}

// MARK: - Keyboard layout (2026-10-25)

/// The Mac's current keyboard layout, as Ubuntu's (xkb) layout and variant.
/// Read on the main thread when the VM is made (Text Input Sources must be
/// asked from the main thread). Apple's layouts map to xkb's "mac" variants
/// where xkb has one, since those match the Mac's key positions. nil for a
/// layout not in the table; the setup wizard then says Ubuntu will use US.
enum UbuntuKeyboard {
    struct Layout: Equatable {
        let layout: String
        let variant: String?
        let name: String
    }

    static let table: [String: Layout] = [
        "com.apple.keylayout.US": Layout(layout: "us", variant: nil, name: "U.S."),
        "com.apple.keylayout.ABC": Layout(layout: "us", variant: nil, name: "U.S."),
        "com.apple.keylayout.USExtended": Layout(layout: "us", variant: nil, name: "U.S."),
        "com.apple.keylayout.USInternational-PC": Layout(layout: "us", variant: "intl", name: "U.S. International"),
        "com.apple.keylayout.Dvorak": Layout(layout: "us", variant: "dvorak", name: "Dvorak"),
        "com.apple.keylayout.Colemak": Layout(layout: "us", variant: "colemak", name: "Colemak"),
        "com.apple.keylayout.British": Layout(layout: "gb", variant: "mac", name: "British"),
        "com.apple.keylayout.British-PC": Layout(layout: "gb", variant: nil, name: "British"),
        "com.apple.keylayout.Irish": Layout(layout: "ie", variant: nil, name: "Irish"),
        "com.apple.keylayout.Canadian": Layout(layout: "us", variant: nil, name: "Canadian English"),
        "com.apple.keylayout.Canadian-CSA": Layout(layout: "ca", variant: nil, name: "Canadian French"),
        "com.apple.keylayout.French": Layout(layout: "fr", variant: "mac", name: "French"),
        "com.apple.keylayout.French-PC": Layout(layout: "fr", variant: nil, name: "French"),
        "com.apple.keylayout.French-numerical": Layout(layout: "fr", variant: "mac", name: "French"),
        "com.apple.keylayout.Belgian": Layout(layout: "be", variant: nil, name: "Belgian"),
        "com.apple.keylayout.German": Layout(layout: "de", variant: "mac", name: "German"),
        "com.apple.keylayout.SwissGerman": Layout(layout: "ch", variant: "de_mac", name: "Swiss German"),
        "com.apple.keylayout.SwissFrench": Layout(layout: "ch", variant: "fr_mac", name: "Swiss French"),
        "com.apple.keylayout.Austrian": Layout(layout: "at", variant: "mac", name: "Austrian"),
        "com.apple.keylayout.Spanish": Layout(layout: "es", variant: "mac", name: "Spanish"),
        "com.apple.keylayout.Spanish-ISO": Layout(layout: "es", variant: "mac", name: "Spanish"),
        "com.apple.keylayout.LatinAmerican": Layout(layout: "latam", variant: nil, name: "Latin American"),
        "com.apple.keylayout.Italian": Layout(layout: "it", variant: "mac", name: "Italian"),
        "com.apple.keylayout.Italian-Pro": Layout(layout: "it", variant: "mac", name: "Italian"),
        "com.apple.keylayout.Portuguese": Layout(layout: "pt", variant: "mac", name: "Portuguese"),
        "com.apple.keylayout.Brazilian": Layout(layout: "br", variant: nil, name: "Brazilian"),
        "com.apple.keylayout.Brazilian-ABNT2": Layout(layout: "br", variant: nil, name: "Brazilian"),
        "com.apple.keylayout.Dutch": Layout(layout: "us", variant: nil, name: "Dutch"),
        "com.apple.keylayout.Danish": Layout(layout: "dk", variant: "mac", name: "Danish"),
        "com.apple.keylayout.Swedish": Layout(layout: "se", variant: "mac", name: "Swedish"),
        "com.apple.keylayout.Swedish-Pro": Layout(layout: "se", variant: "mac", name: "Swedish"),
        "com.apple.keylayout.Norwegian": Layout(layout: "no", variant: "mac", name: "Norwegian"),
        "com.apple.keylayout.Finnish": Layout(layout: "fi", variant: "mac", name: "Finnish"),
        "com.apple.keylayout.Polish": Layout(layout: "pl", variant: nil, name: "Polish"),
        "com.apple.keylayout.PolishPro": Layout(layout: "pl", variant: nil, name: "Polish"),
        "com.apple.keylayout.Czech": Layout(layout: "cz", variant: nil, name: "Czech"),
        "com.apple.keylayout.Czech-QWERTY": Layout(layout: "cz", variant: "qwerty", name: "Czech"),
        "com.apple.keylayout.Hungarian": Layout(layout: "hu", variant: nil, name: "Hungarian"),
        "com.apple.keylayout.Turkish": Layout(layout: "tr", variant: nil, name: "Turkish"),
        "com.apple.keylayout.Turkish-QWERTY-PC": Layout(layout: "tr", variant: nil, name: "Turkish"),
    ]

    /// The current layout's mapping, or nil with the layout's own name.
    @MainActor
    static func current() -> (layout: Layout?, macName: String) {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return (nil, "unknown")
        }
        func property(_ key: CFString) -> String? {
            guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let id = property(kTISPropertyInputSourceID) ?? ""
        let name = property(kTISPropertyLocalizedName) ?? id
        return (table[id], name)
    }
}

// MARK: - What the ISO is

/// What AVM read off an installer ISO, used by the Setup Wizard to say what
/// the user picked and by the pipeline's validation gate.
/// Which Linux the installer is (2026-10-26): Ubuntu's autoinstall,
/// Debian's preseed or Fedora's kickstart. Everything after the answers
/// (the account, Orca, the marker, the stall watch) is shared.
nonisolated enum LinuxDistro: String, Equatable, Sendable {
    case ubuntu, debian, fedora
}

nonisolated struct UbuntuISOInfo: Equatable {
    /// From /.disk/info, e.g. "Ubuntu 26.04.1 LTS \"Resolute Raccoon\" - Release arm64".
    let discInfo: String
    /// e.g. "26.04.1", or "" when /.disk/info doesn't say.
    let version: String
    let isARM64: Bool
    let isDesktop: Bool
    var distro: LinuxDistro = .ubuntu
    /// Fedora only (2026-10-26): a live image (Fedora Workstation Live),
    /// not an installer AVM can give answers to. See identifyFedora.
    var isLiveImage = false

    /// A spoken-friendly name, e.g. "Ubuntu 26.04.1 LTS desktop".
    var spokenName: String {
        if distro == .debian {
            return version.isEmpty ? "Debian" : "Debian \(version)"
        }
        if distro == .fedora {
            return version.isEmpty ? "Fedora" : "Fedora \(version)"
        }
        var name = "Ubuntu"
        if !version.isEmpty { name += " \(version)" }
        if discInfo.contains("LTS") { name += " LTS" }
        name += isDesktop ? " desktop" : " server"
        return name
    }

    /// The major version, e.g. 26 for 26.04.1. 0 when unknown.
    var majorVersion: Int {
        Int(version.split(separator: ".").first ?? "") ?? 0
    }
}

/// What identify found. Not Ubuntu and couldn't read are different
/// answers: the first means the Windows path, the second means saying so.
nonisolated enum ISOIdentity: Equatable {
    case ubuntu(UbuntuISOInfo)
    case notUbuntu
    case unreadable(String)

    var info: UbuntuISOInfo? {
        if case .ubuntu(let info) = self { return info }
        return nil
    }
}

// MARK: - Stages

nonisolated enum UbuntuPipelineStage: Int, CaseIterable, Sendable {
    case writeAnswers     = 1   // the answer file and its setup script, into scratch
    case buildMarkerImage = 2   // mtools: the UNATTEND FAT volume for AVMDONE.TAG
    case rebuildISO       = 3   // xorriso: the original ISO + /nocloud + edited grub.cfg
    case promote          = 4   // verified artifacts from scratch into the VM folder

    var label: String {
        switch self {
        case .writeAnswers:     return "Writing the install answers"
        case .buildMarkerImage: return "Preparing the install-complete marker"
        case .rebuildISO:       return "Adding the answers to the installer"
        case .promote:          return "Finalizing the install media"
        }
    }

    var spoken: String {
        let total = Self.allCases.count
        return "\(label). Step \(rawValue) of \(total)."
    }

    var visible: String {
        "Step \(rawValue) of \(Self.allCases.count): \(label)"
    }
}

nonisolated enum UbuntuPipelineError: LocalizedError {
    case toolNotFound(String)
    case notAnUbuntuInstaller(String)
    case stageFailed(stage: UbuntuPipelineStage, reason: String)
    case accountMissing

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "A required tool (\(name)) is missing from the app. This is a build problem, not something you did."
        case .notAnUbuntuInstaller(let reason):
            return reason
        case .stageFailed(let stage, let reason):
            return "\(stage.label) failed. \(reason)"
        case .accountMissing:
            return "The Ubuntu account details for this virtual machine are missing, so Ubuntu can't be installed without questions. Delete this virtual machine and create it again with the Setup Wizard."
        }
    }
}

// MARK: - Pipeline

nonisolated final class UbuntuInstallPipeline {

    struct Input {
        let vmID: UUID
        let vmName: String
        let sourceISOPath: String
        let runtimeDir: URL
    }

    /// (spoken, visible). Invoked ON the main actor, before each stage.
    var onProgress: (@MainActor (String, String) -> Void)?

    private var scratchDir: URL?

    /// The boot-menu edit: the first `linux /casper/vmlinuz` line gains
    /// these words. GRUB needs the ; escaped. console=ttyAMA0 copies the
    /// installer's kernel and boot messages to the serial port, which AVM
    /// already records as firmware-serial.log in the VM's folder: the one
    /// place a stalled install can be diagnosed from. The menu's own
    /// console=tty0 comes later on the line, so the screen stays the main
    /// console. noprompt: without it the live system's shutdown stops at
    /// "Please remove the installation medium, then press ENTER" and waits
    /// for a key forever, so a failed install's power-off never happens
    /// (proven with a forced failure; the success path's own power-off
    /// skips the prompt, which is why only failures hit it).
    static let kernelArguments = "autoinstall ds=nocloud\\;s=/cdrom/nocloud/ noprompt console=ttyAMA0"

    /// The boot menu's new first line: when the install-complete marker is
    /// on any disk GRUB can see (the UNATTEND volume), hand back to the
    /// firmware, which boots the installed disk. See the file header.
    static let markerGuardLine = "if search --no-floppy --file --set=avmdone /AVMDONE.TAG; then exit; fi"

    // MARK: Identify

    /// Read what an ISO is, without changing anything: .ubuntu with what it
    /// found, .notUbuntu when there is no /casper/vmlinuz (the Windows path),
    /// or .unreadable when the file or the tool can't be used at all. Runs
    /// xorriso; call off the main actor.
    @concurrent
    static func identify(isoPath: String) async -> ISOIdentity {
        guard let xorriso = try? toolURL(named: "xorriso") else {
            return .unreadable("A required tool (xorriso) is missing from the app. This is a build problem, not something you did.")
        }
        // One path per -find. On a disc with no /casper/vmlinuz the first
        // -find fails and xorriso stops; see below for what that means.
        let listing = await runTool(xorriso, [
            "-indev", isoPath,
            "-find", "/casper/vmlinuz", "--",
            "-find", "/EFI/boot", "--"
        ])
        // Match whole lines: xorriso's failure message quotes the path too.
        let found = Set(listing.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        guard found.contains("'/casper/vmlinuz'") else {
            // Only xorriso's own "no such path" answer means "not Ubuntu".
            // Anything else (unreadable file, not an ISO, xorriso failing to
            // start) must not quietly become a Windows VM (code review,
            // 2026-10-19).
            // xorriso loads a file it can't read as a BLANK medium and then
            // reports the path missing (proven with an unreadable file). But
            // a valid Windows ISO it can't parse may also look blank, so
            // only a file macOS itself can't read is "couldn't read"; every
            // other no-casper answer stays on the Windows path, whose own
            // gate speaks to a wrong file.
            let readable = FileManager.default.isReadableFile(atPath: isoPath)
            if readable && listing.output.contains("Cannot find path '/casper/vmlinuz'") {
                // Debian's ARM installer keeps its kernel in /install.a64.
                if let debian = await identifyDebian(isoPath: isoPath, xorriso: xorriso) {
                    return .ubuntu(debian)
                }
                // Fedora's keeps it in /images/pxeboot (2026-10-26).
                if let fedora = await identifyFedora(isoPath: isoPath, xorriso: xorriso) {
                    return .ubuntu(fedora)
                }
                ubuntuLog("identify: no /casper/vmlinuz, /install.a64/vmlinuz or Fedora disc — not a Linux installer AVM knows")
                return .notUbuntu
            }
            ubuntuLog("identify: xorriso couldn't read the ISO (exit \(listing.code)): \(listing.output.suffix(300))")
            return .unreadable("AVM couldn't read this ISO. It may be damaged, still downloading, or not a disc image.")
        }
        let isARM64 = found.contains("'/EFI/boot/bootaa64.efi'")

        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("avm-ubuntu-probe-\(UUID().uuidString)")
        try? fm.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: probe) }
        let infoURL = probe.appendingPathComponent("info")
        let sourcesURL = probe.appendingPathComponent("install-sources.yaml")
        await runTool(xorriso, ["-osirrox", "on", "-indev", isoPath,
                                "-extract", "/.disk/info", infoURL.path,
                                "-extract", "/casper/install-sources.yaml", sourcesURL.path])
        let discInfo = ((try? String(contentsOf: infoURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = (try? String(contentsOf: sourcesURL, encoding: .utf8)) ?? ""
        let isDesktop = sources.contains("id: ubuntu-desktop")

        var version = ""
        if let match = discInfo.range(of: "[0-9]+\\.[0-9]+(\\.[0-9]+)?", options: .regularExpression) {
            version = String(discInfo[match])
        }
        let info = UbuntuISOInfo(discInfo: discInfo, version: version, isARM64: isARM64, isDesktop: isDesktop)
        ubuntuLog("identify: \(info.spokenName), arm64=\(isARM64), desktop=\(isDesktop), disc info \"\(discInfo)\"")
        return .ubuntu(info)
    }

    /// Why AVM can't install from this ISO, or nil when it can. The same
    /// words serve the Setup Wizard and the pipeline's gate.
    /// Debian's ARM64 installer (netinst or DVD), or nil.
    @concurrent
    static func identifyDebian(isoPath: String, xorriso: URL) async -> UbuntuISOInfo? {
        let listing = await runTool(xorriso, [
            "-indev", isoPath,
            "-find", "/install.a64/vmlinuz", "--",
            "-find", "/EFI/boot", "--"
        ])
        let found = Set(listing.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        guard found.contains("'/install.a64/vmlinuz'") else { return nil }
        let fm = FileManager.default
        let probe = fm.temporaryDirectory.appendingPathComponent("avm-debian-probe-\(UUID().uuidString)")
        try? fm.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: probe) }
        let infoURL = probe.appendingPathComponent("info")
        await runTool(xorriso, ["-osirrox", "on", "-indev", isoPath, "-extract", "/.disk/info", infoURL.path])
        let discInfo = ((try? String(contentsOf: infoURL, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var version = ""
        if let match = discInfo.range(of: "[0-9]+(\\.[0-9]+)*", options: .regularExpression) {
            version = String(discInfo[match])
        }
        // The netinst installs the desktop from the network, so every Debian
        // installer counts as a desktop one.
        let info = UbuntuISOInfo(discInfo: discInfo, version: version,
                                 isARM64: found.contains("'/EFI/boot/bootaa64.efi'"), isDesktop: true, distro: .debian)
        ubuntuLog("identify: \(info.spokenName), arm64=\(info.isARM64), disc info \"\(discInfo)\"")
        return info
    }

    static func problem(with info: UbuntuISOInfo?) -> String? {
        guard let info else {
            return "This ISO isn't an Ubuntu installer AVM recognizes."
        }
        if info.distro == .debian {
            if !info.isARM64 {
                return "This is a Debian installer for Intel and AMD PCs. This Mac needs the arm64 one: on debian.org, download the arm64 netinst image."
            }
            if info.majorVersion != 0 && info.majorVersion < 12 {
                return "This is \(info.spokenName). AVM needs Debian 12 or later."
            }
            return nil
        }
        if info.distro == .fedora {
            return fedoraProblem(with: info)
        }
        if !info.isARM64 {
            return "This is an Ubuntu installer for Intel and AMD PCs. This Mac needs the ARM version: on ubuntu.com, download Ubuntu Desktop for ARM."
        }
        if !info.isDesktop {
            return "This is the Ubuntu Server installer. AVM needs Ubuntu Desktop for ARM, which brings the desktop and the Orca screen reader."
        }
        // 26.04 is the release every part of this was proven on, so anything
        // older is refused rather than half-supported: the interim 25.04 and
        // 25.10 were never tested, and 24.04's WirePlumber 0.4 ignores the
        // audio tuning's configuration format (third review, 2026-10-19). A
        // version AVM can't read is refused for the same reason.
        if info.majorVersion == 0 {
            return "AVM couldn't tell which Ubuntu version this is. AVM needs Ubuntu 26.04 or later, from ubuntu.com."
        }
        if info.majorVersion < 26 {
            return "This is \(info.spokenName). AVM needs Ubuntu 26.04 or later."
        }
        return nil
    }

    // MARK: Run

    @concurrent
    func run(_ input: Input) async throws {
        ubuntuLog("run: starting for VM \(input.vmID.uuidString)")

        let identity = await Self.identify(isoPath: input.sourceISOPath)
        if case .unreadable(let reason) = identity {
            ubuntuLog("run: validation HARD-STOP: \(reason)")
            throw UbuntuPipelineError.notAnUbuntuInstaller(reason)
        }
        if let problem = Self.problem(with: identity.info) {
            ubuntuLog("run: validation HARD-STOP: \(problem)")
            throw UbuntuPipelineError.notAnUbuntuInstaller(problem)
        }
        let distro = identity.info?.distro ?? .ubuntu
        guard let account = UbuntuAccount.load(fromVMDirectory: input.runtimeDir) else {
            ubuntuLog("run: no \(UbuntuAccount.fileName) in the VM folder")
            throw UbuntuPipelineError.accountMissing
        }

        let scratch = try Self.makeScratchDir(for: input.vmID)
        scratchDir = scratch
        do {
            for stage in UbuntuPipelineStage.allCases {
                await emit(stage)
                switch stage {
                case .writeAnswers:     try stageWriteAnswers(input: input, account: account, scratch: scratch, distro: distro,
                                                              version: identity.info?.version ?? "")
                case .buildMarkerImage: try await stageBuildMarkerImage(scratch: scratch)
                case .rebuildISO:       try await stageRebuildISO(input: input, scratch: scratch, distro: distro, account: account)
                case .promote:          try stagePromote(input: input, scratch: scratch)
                }
            }
        } catch {
            ubuntuLog("run: FAILED: \(error.localizedDescription)")
            cleanScratch()
            throw error
        }
        cleanScratch()
        // The hash now lives only inside install-avm.iso (see file header).
        UbuntuAccount.delete(fromVMDirectory: input.runtimeDir)
        ubuntuLog("run: complete; account file removed")
    }

    private func emit(_ stage: UbuntuPipelineStage) async {
        ubuntuLog("progress: \(stage.visible)")
        guard let handler = onProgress else { return }
        await MainActor.run { handler(stage.spoken, stage.visible) }
    }

    // MARK: Stage 1 — the answer file

    private func stageWriteAnswers(input: Input, account: UbuntuAccount, scratch: URL, distro: LinuxDistro,
                                   version: String) throws {
        let nocloud = scratch.appendingPathComponent("nocloud")
        do {
            try FileManager.default.createDirectory(at: nocloud, withIntermediateDirectories: true)
            if distro == .debian {
                try Self.debianPreseed(account: account, hostName: Self.hostName(fromVMName: input.vmName),
                                       timeZone: TimeZone.current.identifier)
                    .write(to: nocloud.appendingPathComponent("preseed.cfg"), atomically: true, encoding: .utf8)
                try Self.debianSetupScript(account: account)
                    .write(to: nocloud.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
                try Self.debianFailureScript
                    .write(to: nocloud.appendingPathComponent("failed.sh"), atomically: true, encoding: .utf8)
                return
            }
            if distro == .fedora {
                // One file: the setup and failure scripts ride inside the
                // kickstart, as its %post and %onerror sections.
                try Self.fedoraKickstart(account: account, hostName: Self.hostName(fromVMName: input.vmName),
                                         timeZone: TimeZone.current.identifier, version: version)
                    .write(to: nocloud.appendingPathComponent("ks.cfg"), atomically: true, encoding: .utf8)
                return
            }
            try Self.userData(account: account, hostName: Self.hostName(fromVMName: input.vmName),
                              timeZone: TimeZone.current.identifier)
                .write(to: nocloud.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
            try "".write(to: nocloud.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
            try Self.setupScript(account: account)
                .write(to: nocloud.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
            try Self.failureScript
                .write(to: nocloud.appendingPathComponent("failed.sh"), atomically: true, encoding: .utf8)
        } catch {
            throw UbuntuPipelineError.stageFailed(
                stage: .writeAnswers,
                reason: "Couldn't write the answer file. (\(error.localizedDescription))"
            )
        }
    }

    /// A YAML double-quoted scalar. JSON's string form is one, so
    /// JSONSerialization does the escaping.
    static func yamlQuoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    /// Ubuntu host names: lower case, letters, digits and hyphens, at most 63.
    static func hostName(fromVMName name: String) -> String {
        let lowered = name.lowercased()
        let dashed = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let cut = String(trimmed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "ubuntu" : cut
    }

    static func userData(account: UbuntuAccount, hostName: String, timeZone: String) -> String {
        """
        #cloud-config
        autoinstall:
          version: 1
          interactive-sections: []
          locale: en_US.UTF-8
          keyboard: {layout: \(account.keyboardLayout ?? "us")\(account.keyboardVariant.map { ", variant: \($0)" } ?? "")}
          timezone: \(yamlQuoted(timeZone))
          source: {id: ubuntu-desktop}
          identity:
            hostname: \(yamlQuoted(hostName))
            username: \(yamlQuoted(account.userName))
            realname: \(yamlQuoted(account.realName))
            password: \(yamlQuoted(account.passwordHash))
          storage:
            layout: {name: direct}
          codecs: {install: false}
          drivers: {install: false}
          updates: security
          packages:
            - spice-vdagent
          late-commands:
            - bash /cdrom/nocloud/setup.sh
          error-commands:
            - bash /cdrom/nocloud/failed.sh
          shutdown: poweroff

        """
    }

    /// Runs at the end of the install with the new system at /target. Its
    /// last act is the install-complete marker.
    static func setupScript(account: UbuntuAccount) -> String {
        let user = account.userName   // validated: [a-z][a-z0-9_-]*, safe unquoted
        let autoLogin = account.signInAutomatically
            ? """
              mkdir -p $T/etc/gdm3
              printf '[daemon]\\nAutomaticLoginEnable=true\\nAutomaticLogin=%s\\n' "$U" > $T/etc/gdm3/custom.conf
              """
            : "# Sign in automatically: not chosen."
        return """
        #!/bin/bash
        # Written by AVM. Runs once, at the end of Ubuntu's install.
        # set -e: any failed step fails the install, so error-commands
        # (failed.sh) report it, instead of the marker announcing an install
        # whose Orca or sign-in settings never landed (code review,
        # 2026-10-19). Optional steps say so with || true.
        set -ex
        T=/target
        U=\(user)
        \(autoLogin)
        # System-wide defaults the user can still change.
        mkdir -p $T/etc/dconf/profile $T/etc/dconf/db/local.d $T/etc/dconf/db/gdm.d
        printf 'user-db:user\\nsystem-db:local\\n' > $T/etc/dconf/profile/user
        cat > $T/etc/dconf/db/local.d/00-avm <<'DCONF'
        [org/gnome/desktop/a11y/applications]
        screen-reader-enabled=true

        [org/gnome/desktop/a11y]
        always-show-universal-access-status=true

        [org/gnome/desktop/session]
        idle-delay=uint32 0

        [org/gnome/desktop/screensaver]
        lock-enabled=false

        [org/gnome/settings-daemon/plugins/power]
        sleep-inactive-ac-type='nothing'
        sleep-inactive-battery-type='nothing'

        [org/gnome/orca/default/keybindings]
        keyboard-layout='laptop'
        DCONF
        cat > $T/etc/dconf/db/gdm.d/00-avm <<'DCONF'
        [org/gnome/desktop/a11y/applications]
        screen-reader-enabled=true

        [org/gnome/orca/default/keybindings]
        keyboard-layout='laptop'
        DCONF
        # ORCA'S SETTINGS FILE (2026-10-26, MEASURED on Debian 13): Orca
        # writes ~/.local/share/orca/user-settings.conf on its first run; a
        # machine switched off then (Force Stop, a power cut) kept an empty
        # file, and Orca crashed on it at every later sign-in (KeyError
        # 'default'), leaving no screen reader for good. Before each desktop
        # session, a file that isn't valid JSON is set aside; Orca then
        # starts with its defaults.
        mkdir -p $T/usr/local/lib/avm $T/etc/systemd/user/graphical-session-pre.target.wants
        cat > $T/usr/local/lib/avm/orca-settings-guard.sh <<'GUARD'
        #!/bin/sh
        f="$HOME/.local/share/orca/user-settings.conf"
        [ -e "$f" ] || exit 0
        python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null && exit 0
        mv "$f" "$f.unreadable-$(date +%s)"
        GUARD
        chmod 755 $T/usr/local/lib/avm/orca-settings-guard.sh
        cat > $T/etc/systemd/user/avm-orca-settings-guard.service <<'UNIT'
        [Unit]
        Description=AVM: set aside an unreadable Orca settings file
        Before=graphical-session-pre.target

        [Service]
        Type=oneshot
        ExecStart=/bin/sh /usr/local/lib/avm/orca-settings-guard.sh

        [Install]
        WantedBy=graphical-session-pre.target
        UNIT
        ln -sf ../avm-orca-settings-guard.service $T/etc/systemd/user/graphical-session-pre.target.wants/avm-orca-settings-guard.service
        curtin in-target -- dconf update
        # dconf update must have compiled both databases from these files;
        # a database older than its keyfile means the settings never landed.
        # One test per line: set -e ignores a failure early in an && list.
        [ -s $T/etc/dconf/db/local ]
        [ ! $T/etc/dconf/db/local.d/00-avm -nt $T/etc/dconf/db/local ]
        [ -s $T/etc/dconf/db/gdm ]
        [ ! $T/etc/dconf/db/gdm.d/00-avm -nt $T/etc/dconf/db/gdm ]
        # No first-run wizard, and no crash-report prompts. Ubuntu also runs
        # a per-release welcome tour (gnome-initial-setup --upgrade-user)
        # until upgrade-<release>-done exists; the name follows the release.
        mkdir -p $T/home/$U/.config/gnome-initial-setup
        echo yes > $T/home/$U/.config/gnome-initial-setup-done
        V=$(. $T/etc/os-release && echo "$VERSION_ID") || true
        if [ -n "$V" ]; then touch "$T/home/$U/.config/gnome-initial-setup/upgrade-$V-done"; fi
        curtin in-target -- chown -R $U:$U /home/$U/.config
        # The installer carries its boot arguments into the new system;
        # only the installer needs them. (The installed system still uses
        # the serial port the firmware declares; that is Ubuntu's own.)
        sed -i -e 's/console=ttyAMA0 //' -e 's/noprompt //' $T/etc/default/grub || true
        curtin in-target -- update-grub || true
        if [ -f $T/etc/default/apport ]; then sed -i 's/^enabled=1/enabled=0/' $T/etc/default/apport; fi
        # The SPICE agent's audio volume sync sets Ubuntu's master volume to
        # whatever AVM's SPICE client reports, which is 0, every time AVM
        # connects (each Enter Ubuntu), so Orca goes silent. The agent has no
        # switch for it, so it runs with an ALSA configuration that has no
        # mixer to reach; its mouse and display work is untouched.
        mkdir -p $T/etc/avm $T/etc/systemd/user/spice-vdagent.service.d
        echo 'ctl.!default { type hw card 31 }' > $T/etc/avm/spice-vdagent-alsa.conf
        printf '[Service]\\nEnvironment=ALSA_CONFIG_PATH=/etc/avm/spice-vdagent-alsa.conf\\n' > $T/etc/systemd/user/spice-vdagent.service.d/10-avm-no-volume-sync.conf
        # Audio without crackle (2026-10-19, heard in the in-app test): run
        # PipeWire at 44.1 kHz, the rate AVM's QEMU audio uses (QMP
        # query-audiodevs on a running AVM VM: spice out frequency 44100,
        # fixed-settings true), so nothing is
        # resampled, and give the emulated sound card a larger buffer, so
        # speech doesn't run dry between QEMU's audio ticks.
        mkdir -p $T/etc/pipewire/pipewire.conf.d $T/etc/wireplumber/wireplumber.conf.d
        cat > $T/etc/pipewire/pipewire.conf.d/10-avm-audio.conf <<'PW'
        context.properties = {
            default.clock.rate          = 44100
            default.clock.allowed-rates = [ 44100 ]
            default.clock.quantum       = 1024
            default.clock.min-quantum   = 1024
        }
        PW
        cat > $T/etc/wireplumber/wireplumber.conf.d/50-avm-audio.conf <<'WP'
        monitor.alsa.rules = [
          {
            matches = [ { node.name = "~alsa_output.*" } ]
            actions = { update-props = { api.alsa.period-size = 1024, api.alsa.headroom = 8192 } }
          }
        ]
        WP
        # The UNATTEND volume stays attached for the marker; keep it out of
        # the desktop's drive list (and out of Orca's announcements).
        echo 'ENV{ID_FS_LABEL}=="UNATTEND", ENV{UDISKS_IGNORE}="1"' > $T/etc/udev/rules.d/99-avm-unattend.rules
        # The install-complete marker, last: Ubuntu is on the disk.
        mkdir -p /run/avm-unattend
        mount -t vfat /dev/disk/by-label/UNATTEND /run/avm-unattend || exit 1
        echo "Ubuntu installed by AVM" > /run/avm-unattend/AVMDONE.TAG
        sync
        # The marker is written and synced; nothing after it may fail the
        # install (VMManager also lets AVMDONE win over AVMFAIL).
        umount /run/avm-unattend || true
        exit 0

        """
    }

    /// Runs when the install fails (error-commands). Without it the
    /// installer waits on an error screen with nothing speaking, forever.
    /// It keeps the end of the installer's logs on the UNATTEND volume,
    /// writes AVMFAIL.TAG, and powers off; VMManager announces that exit
    /// (UBUNTU INSTALL END). The logs are cut to fit the 8 MB volume.
    static let failureScript = """
        #!/bin/bash
        # Written by AVM. Runs only if Ubuntu's install fails.
        set -x
        mkdir -p /run/avm-unattend
        if mount -t vfat /dev/disk/by-label/UNATTEND /run/avm-unattend; then
            for log in /var/log/installer/subiquity-server-debug.log /var/log/installer/curtin-install.log; do
                [ -f "$log" ] && tail -c 2000000 "$log" > "/run/avm-unattend/$(basename "$log" .log | cut -c1-8).log"
            done
            echo "Ubuntu install failed" > /run/avm-unattend/AVMFAIL.TAG
            sync
            umount /run/avm-unattend
        fi
        # The installer holds a shutdown inhibitor; a plain poweroff is
        # refused ("Operation denied due to active block inhibitor", proven
        # with a forced failure). Fall back to an immediate power-off.
        systemctl poweroff --ignore-inhibitors || systemctl poweroff --force

        """

    // MARK: Stage 2 — the marker volume

    /// The same 8 MB FAT volume, label and geometry as the Windows answer
    /// image (proven geometry 16384/16/63), empty: Ubuntu's answers ride
    /// the ISO, and this volume is only the marker's home.
    private func stageBuildMarkerImage(scratch: URL) async throws {
        let image = scratch.appendingPathComponent("autounattend.img")
        let mformat = try Self.toolURL(named: "mformat")
        let mdir = try Self.toolURL(named: "mdir")
        do {
            try Data(count: 8_388_608).write(to: image)
        } catch {
            throw UbuntuPipelineError.stageFailed(stage: .buildMarkerImage,
                                                 reason: "Couldn't create the marker disk image. (\(error.localizedDescription))")
        }
        let env = ["MTOOLS_SKIP_CHECK": "1"]
        let format = await Self.runTool(mformat, ["-i", image.path, "-v", "UNATTEND",
                                                  "-T", "16384", "-h", "16", "-s", "63", "::"],
                                        extraEnvironment: env)
        guard format.code == 0 else {
            throw UbuntuPipelineError.stageFailed(stage: .buildMarkerImage,
                                                 reason: "Couldn't format the marker disk image. (mformat exit \(format.code): \(format.output.prefix(300)))")
        }
        // Postcondition: readable, labeled, and with no marker yet.
        let listing = await Self.runTool(mdir, ["-i", image.path, "::"], extraEnvironment: env)
        guard listing.code == 0, listing.output.contains("UNATTEND"), !listing.output.uppercased().contains("AVMDONE") else {
            throw UbuntuPipelineError.stageFailed(stage: .buildMarkerImage,
                                                 reason: "The marker disk image didn't read back as expected. (mdir exit \(listing.code))")
        }
    }

    // MARK: Stage 3 — the ISO

    private func stageRebuildISO(input: Input, scratch: URL, distro: LinuxDistro, account: UbuntuAccount) async throws {
        if distro == .fedora {
            try await stageRebuildFedoraISO(input: input, scratch: scratch)
            return
        }
        let xorriso = try Self.toolURL(named: "xorriso")
        let grubDir = scratch.appendingPathComponent("grub")
        let grubURL = grubDir.appendingPathComponent("grub.cfg")
        try? FileManager.default.createDirectory(at: grubDir, withIntermediateDirectories: true)

        let extract = await Self.runTool(xorriso, ["-osirrox", "on", "-indev", input.sourceISOPath,
                                                   "-extract", "/boot/grub/grub.cfg", grubURL.path])
        guard extract.code == 0, let original = try? String(contentsOf: grubURL, encoding: .utf8) else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't read the installer's boot menu. (xorriso exit \(extract.code))")
        }
        guard let edited = distro == .debian ? Self.editedDebianBootMenu(original, keyboard: Self.debianKeyboardArguments(account)) : Self.editedBootMenu(original) else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "The installer's boot menu isn't in the form AVM knows, so the answers couldn't be added. This Ubuntu release may be newer than this version of AVM.")
        }
        do {
            try? FileManager.default.removeItem(at: grubURL)
            try edited.write(to: grubURL, atomically: true, encoding: .utf8)
        } catch {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't write the edited boot menu. (\(error.localizedDescription))")
        }

        let output = scratch.appendingPathComponent("install-avm.iso")
        let build = await Self.runTool(xorriso, [
            "-indev", input.sourceISOPath,
            "-outdev", output.path,
            "-map", grubURL.path, "/boot/grub/grub.cfg",
            "-map", scratch.appendingPathComponent("nocloud").path, "/nocloud",
            "-boot_image", "any", "replay"
        ])
        guard build.code == 0 else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't build the installer copy. Check that the Mac has about 5 GB free. (xorriso exit \(build.code): \(build.output.suffix(300)))")
        }

        // Postcondition: the copy's boot menu is the edited one and the
        // answers are on it.
        let check = scratch.appendingPathComponent("grub-check.cfg")
        let verify = await Self.runTool(xorriso, ["-osirrox", "on", "-indev", output.path,
                                                  "-extract", "/boot/grub/grub.cfg", check.path,
                                                  "-find", "/nocloud", "--"])
        let readBack = (try? String(contentsOf: check, encoding: .utf8)) ?? ""
        guard verify.code == 0,
              readBack.hasPrefix(Self.markerGuardLine),
              readBack.contains(distro == .debian ? Self.debianKernelArguments : Self.kernelArguments),
              verify.output.contains(distro == .debian ? "\n'/nocloud/preseed.cfg'" : "\n'/nocloud/user-data'"),
              verify.output.contains("\n'/nocloud/setup.sh'"),
              verify.output.contains("\n'/nocloud/failed.sh'") else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "The installer copy didn't read back with the answers on it. (xorriso exit \(verify.code))")
        }
    }

    /// The installer's boot menu with the marker guard first, a one-second
    /// timeout, and the autoinstall words on the first entry. nil when the
    /// menu has no `linux /casper/vmlinuz` line to edit.
    // MARK: Debian (2026-10-26)

    /// Debian's installer reads a preseed file instead of autoinstall. The
    /// arguments go before "---" (what follows it is for the installed
    /// system); priority=critical means no question is asked.
    static let debianKernelArguments = "auto=true priority=critical preseed/file=/cdrom/nocloud/preseed.cfg"

    /// The first installer entry boots by itself, with the answers, after a
    /// second; the marker guard keeps an installed machine off the
    /// installer, as for Ubuntu.
    /// The keyboard on the installer's command line (2026-10-26, MEASURED by
    /// test-linux-install.sh --keyboard gb:mac): Debian's installer settles
    /// the keyboard before it reads the preseed file, so the preseed's
    /// keyboard answers were ignored and every install got "us". Account
    /// values are checked words (UbuntuAccount), safe on the command line.
    static func debianKeyboardArguments(_ account: UbuntuAccount) -> String {
        let layout = account.keyboardLayout ?? "us"
        var words = "keymap=\(layout) keyboard-configuration/layoutcode=\(layout)"
        if let variant = account.keyboardVariant, !variant.isEmpty {
            words += " keyboard-configuration/variantcode=\(variant)"
        }
        return words
    }

    static func editedDebianBootMenu(_ original: String, keyboard: String = "") -> String? {
        guard let entry = original.range(of: "linux\\s+/install\\.a64/vmlinuz", options: .regularExpression) else {
            return nil
        }
        var menu = original
        let arguments = keyboard.isEmpty ? debianKernelArguments : "\(debianKernelArguments) \(keyboard)"
        menu.replaceSubrange(entry, with: "\(original[entry]) \(arguments)")
        if let timeout = menu.range(of: "(?m)^set timeout=[0-9]+", options: .regularExpression) {
            menu.replaceSubrange(timeout, with: "set timeout=1")
        } else {
            menu = "set timeout=1\nset default=0\n" + menu
        }
        return markerGuardLine + "\n" + menu
    }

    /// Debian's answers. Installs onto the virtual disk (nvme0n1) only,
    /// never the UNATTEND volume, with GNOME, Orca and the agents AVM uses,
    /// then runs setup.sh, and powers off as Ubuntu's install does, so
    /// AVM's restart-after-install takes over.
    static func debianPreseed(account: UbuntuAccount, hostName: String, timeZone: String) -> String {
        """
        # Written by AVM. Debian's installer reads this and asks nothing.
        d-i debian-installer/locale string en_US.UTF-8
        d-i keyboard-configuration/xkb-keymap select \(account.keyboardLayout ?? "us")
        d-i keyboard-configuration/layoutcode string \(account.keyboardLayout ?? "us")
        \(account.keyboardVariant.map { "d-i keyboard-configuration/variantcode string \($0)" } ?? "")
        d-i hw-detect/load_firmware boolean false
        d-i netcfg/choose_interface select auto
        d-i netcfg/get_hostname string \(hostName)
        d-i netcfg/get_domain string local
        d-i netcfg/hostname string \(hostName)
        d-i mirror/country string manual
        d-i mirror/http/hostname string deb.debian.org
        d-i mirror/http/directory string /debian
        d-i mirror/http/proxy string
        d-i passwd/root-login boolean false
        d-i passwd/user-fullname string \(account.realName)
        d-i passwd/username string \(account.userName)
        d-i passwd/user-password-crypted password \(account.passwordHash)
        d-i clock-setup/utc boolean true
        d-i time/zone string \(timeZone)
        d-i clock-setup/ntp boolean true
        d-i partman-auto/disk string /dev/nvme0n1
        d-i partman-auto/method string regular
        d-i partman-auto/choose_recipe select atomic
        d-i partman-partitioning/confirm_write_new_label boolean true
        d-i partman/choose_partition select finish
        d-i partman/confirm boolean true
        d-i partman/confirm_nooverwrite boolean true
        d-i partman-efi/non_efi_system boolean true
        d-i apt-setup/cdrom/set-first boolean false
        d-i apt-setup/disable-cdrom-entries boolean true
        d-i apt-setup/non-free-firmware boolean true
        tasksel tasksel/first multiselect standard, gnome-desktop
        d-i pkgsel/include string orca spice-vdagent qemu-guest-agent spice-webdavd dconf-cli
        d-i pkgsel/upgrade select safe-upgrade
        popularity-contest popularity-contest/participate boolean false
        d-i grub-installer/only_debian boolean true
        d-i grub-installer/force-efi-extra-removable boolean true
        d-i preseed/late_command string sh /cdrom/nocloud/setup.sh || sh /cdrom/nocloud/failed.sh
        d-i finish-install/reboot_in_progress note
        d-i debian-installer/exit/poweroff boolean true

        """
    }

    /// Debian's failure script (2026-10-26, code audit: Debian alone had
    /// none, so a failed setup step left its installer on an error screen
    /// with nothing said). Run by late_command when setup.sh fails: the
    /// end of the installer's log and AVMFAIL.TAG on the UNATTEND volume,
    /// then power off, which VMManager announces. Debian's installer has
    /// busybox and no systemd.
    static let debianFailureScript = """
        #!/bin/sh
        # Written by AVM. Runs only if Debian's install fails.
        set -x
        mkdir -p /run/avm-unattend
        if mount -t vfat /dev/disk/by-label/UNATTEND /run/avm-unattend; then
            [ -f /var/log/syslog ] && tail -c 2000000 /var/log/syslog > /run/avm-unattend/syslog.log
            echo "Debian install failed" > /run/avm-unattend/AVMFAIL.TAG
            sync
            umount /run/avm-unattend
        fi
        poweroff -f

        """

    /// Ubuntu's setup script, for Debian's installer: its in-target in
    /// place of curtin's, GDM's daemon.conf in place of custom.conf, and
    /// sh (Debian's installer has no bash). It writes the same marker.
    static func debianSetupScript(account: UbuntuAccount) -> String {
        setupScript(account: account)
            .replacingOccurrences(of: "#!/bin/bash", with: "#!/bin/sh")
            .replacingOccurrences(of: "curtin in-target -- ", with: "in-target ")
            .replacingOccurrences(of: "/etc/gdm3/custom.conf", with: "/etc/gdm3/daemon.conf")
            .replacingOccurrences(of: "Ubuntu installed by AVM", with: "Debian installed by AVM")
            .replacingOccurrences(of: "at the end of Ubuntu's install", with: "at the end of Debian's install")
            .replacingOccurrences(of: "T=/target\n", with: "T=/target\n" + debianKeyboardFix(account), options: [], range: nil)
    }

    /// MEASURED 2026-10-26 (test-linux-install.sh --keyboard gb:mac, then the
    /// installed system's cdebconf record): Debian's installer settles the
    /// keyboard from the language before it reads the preseed file or the
    /// command line's keyboard words, and records "us" for every keyboard
    /// setting. So the setup script writes the installed system's keyboard
    /// file itself, which the sign-in screen and the desktop read. Values
    /// are checked words (UbuntuAccount).
    static func debianKeyboardFix(_ account: UbuntuAccount) -> String {
        let layout = account.keyboardLayout ?? "us"
        let variant = account.keyboardVariant ?? ""
        return """
            # The keyboard chosen in AVM's wizard (Debian's installer keeps "us").
            sed -i -e 's/^XKBLAYOUT=.*/XKBLAYOUT="\(layout)"/' -e 's/^XKBVARIANT=.*/XKBVARIANT="\(variant)"/' $T/etc/default/keyboard

            """
    }

    // MARK: Fedora (2026-10-26)
    //
    // Fedora's installer (Anaconda) reads a kickstart file. AVM installs from
    // the Everything netinstall ISO (or the Server one), never the
    // Workstation live image: the live image installs by copying itself
    // (liveinst), where kickstart has no %packages, so the agents and Orca's
    // settings could not be added the same way. The netinstall installs
    // @workstation-product-environment from Fedora's mirrors instead, the
    // same GNOME desktop the live image brings, with Orca. A live image is
    // refused with a spoken reason (fedoraProblem).
    //
    // THE BOOT MENU IS IN TWO PLACES. The firmware boots the disc's El Torito
    // image, /images/efiboot.img, a small FAT volume with its own copy of
    // EFI/BOOT/grub.cfg, and GRUB reads that copy, not the one in the ISO's
    // tree (Ubuntu's and Debian's EFI images only point GRUB at /boot/grub).
    // Both copies are edited, the inner one with mcopy into a copy of the
    // image, and xorriso's boot-record replay follows the replaced file.
    // Proven on Fedora-Everything-netinst-aarch64-44-1.7.iso: the rebuilt
    // disc's El Torito entry pointed at the new image, and its volume id
    // was kept.
    //
    // THE VOLUME ID MUST STAY. The menu finds the installer's second stage by
    // the disc's label (inst.stage2=hd:LABEL=Fedora-E-dvd-aarch64-44), and
    // the kickstart is found the same way, on the same disc, so the label
    // AVM adds is read from the menu itself, and the rebuilt disc's label is
    // checked against it.
    //
    // THE REST IS UBUNTU'S. The kickstart's %post runs Ubuntu's setup script
    // inside the new system (fedoraSetupScript), the account comes from the
    // same ubuntu-account.json, and the last act is the same AVMDONE.TAG.
    // %onerror is failureScript's counterpart: AVMFAIL.TAG, the end of
    // Anaconda's logs, and a power-off. The marker guard heads the menu,
    // and `poweroff` ends the install, as for Ubuntu.

    /// Where the kickstart sits on the rebuilt disc.
    static let fedoraKickstartPath = "/nocloud/ks.cfg"

    /// The words the first menu entry gains. inst.ks finds the kickstart on
    /// the disc the menu already finds its second stage on. inst.text: no
    /// one is at the screen, and the text installer needs no graphics.
    /// console=ttyAMA0 copies the boot to firmware-serial.log, as for
    /// Ubuntu; console=tty0 after it keeps the screen the main console.
    static func fedoraKernelArguments(volumeLabel: String) -> String {
        "inst.ks=hd:LABEL=\(volumeLabel):\(fedoraKickstartPath) inst.text console=ttyAMA0 console=tty0"
    }

    /// The disc label Fedora's own menu boots the installer from, or nil.
    static func fedoraVolumeLabel(inBootMenu menu: String) -> String? {
        let prefix = "inst.stage2=hd:LABEL="
        guard let range = menu.range(of: "inst\\.stage2=hd:LABEL=[^\\s]+", options: .regularExpression) else {
            return nil
        }
        return String(menu[range].dropFirst(prefix.count))
    }

    /// The first installer entry boots by itself, with the answers, after a
    /// second. Fedora's menu starts on its SECOND entry ("Test this media &
    /// install", set default="1"), a media check that takes minutes, so the
    /// default is moved to the first. The marker guard comes first, as for
    /// Ubuntu.
    static func editedFedoraBootMenu(_ original: String) -> String? {
        guard let entry = original.range(of: "linux\\s+/images/pxeboot/vmlinuz", options: .regularExpression),
              let label = fedoraVolumeLabel(inBootMenu: original) else {
            return nil
        }
        var menu = original
        menu.replaceSubrange(entry, with: "\(original[entry]) \(fedoraKernelArguments(volumeLabel: label))")
        if let defaultEntry = menu.range(of: "(?m)^set default=.*$", options: .regularExpression) {
            menu.replaceSubrange(defaultEntry, with: "set default=\"0\"")
        } else {
            menu = "set default=\"0\"\n" + menu
        }
        if let timeout = menu.range(of: "(?m)^set timeout=[0-9]+", options: .regularExpression) {
            menu.replaceSubrange(timeout, with: "set timeout=1")
        } else {
            menu = "set timeout=1\n" + menu
        }
        return markerGuardLine + "\n" + menu
    }

    /// A kickstart argument, single-quoted. Anaconda splits kickstart lines
    /// the way a POSIX shell does (shlex), so a name with a space or a quote
    /// in it stays one argument.
    static func kickstartQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Fedora's answers. Installs onto the virtual disk (nvme0n1) only, never
    /// the UNATTEND volume or the installer, from Fedora's mirrors with its
    /// updates, with GNOME, Orca and the agents AVM uses (spice-webdavd is
    /// the shared-folder service). `version` is the release the disc says it
    /// is (.discinfo), so the mirrors serve that release; Anaconda's own
    /// $releasever stands in when it is unknown. The welcome tour is left
    /// out: it opens over the desktop at the first sign-in, as Ubuntu's did.
    static func fedoraKickstart(account: UbuntuAccount, hostName: String, timeZone: String, version: String) -> String {
        let release = version.isEmpty ? "$releasever" : version
        let layout = account.keyboardLayout ?? "us"
        let xkb = account.keyboardVariant.map { "\(layout) (\($0))" } ?? layout
        return """
        # Written by AVM. Fedora's installer (Anaconda) reads this and asks nothing.
        text
        lang en_US.UTF-8
        keyboard --xlayouts=\(kickstartQuoted(xkb))
        timezone \(kickstartQuoted(timeZone)) --utc
        network --bootproto=dhcp --device=link --activate --hostname=\(hostName)
        url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-\(release)&arch=aarch64"
        repo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f\(release)&arch=aarch64"
        ignoredisk --only-use=nvme0n1
        zerombr
        clearpart --all --initlabel --drives=nvme0n1
        autopart --type=btrfs
        rootpw --lock
        user --name=\(account.userName) --gecos=\(kickstartQuoted(account.realName)) --groups=wheel --iscrypted --password=\(kickstartQuoted(account.passwordHash))
        firstboot --disable
        poweroff

        %packages
        @^workstation-product-environment
        orca
        spice-vdagent
        spice-webdavd
        qemu-guest-agent
        dconf
        -gnome-tour
        %end

        %post --interpreter=/bin/bash --erroronfail --log=/root/avm-setup.log
        \(fedoraSetupScript(account: account))
        %end

        %onerror --interpreter=/bin/bash
        \(fedoraFailureScript)
        %end

        """
    }

    /// Ubuntu's setup script, for the kickstart's %post, which runs inside
    /// the new system: no /target and no curtin, GDM's /etc/gdm in place of
    /// /etc/gdm3, grubby in place of update-grub, and Fedora's own dconf
    /// user profile kept (it already reads the local database, and also the
    /// site and distro ones Fedora adds). Before the marker, the desktop as
    /// the default target, the agents on, and SELinux labels on the files
    /// written. It writes the same marker. The UNATTEND volume mounts from
    /// inside the new system: Anaconda binds /dev into it, and vfat is
    /// already loaded for the new system's EFI partition.
    static func fedoraSetupScript(account: UbuntuAccount) -> String {
        let fedoraExtras = """
            # Fedora (2026-10-26): start to the desktop, with the agents on
            # (their units also start themselves when their virtual ports
            # appear). Then SELinux, which Fedora enforces: the files above
            # get the labels its policy expects, not whatever the install
            # left on them.
            systemctl set-default graphical.target
            systemctl enable spice-vdagentd.socket qemu-guest-agent.service || true
            restorecon -R /etc /home/$U || true

            """
        return setupScript(account: account)
            .replacingOccurrences(of: "at the end of Ubuntu's install", with: "at the end of Fedora's install, in its %post")
            .replacingOccurrences(of: "(failed.sh)", with: "(%onerror)")
            .replacingOccurrences(of: "T=/target", with: "T=")
            .replacingOccurrences(of: "curtin in-target -- ", with: "")
            .replacingOccurrences(of: "/etc/gdm3", with: "/etc/gdm")
            .replacingOccurrences(of: "printf 'user-db:user\\nsystem-db:local\\n' > $T/etc/dconf/profile/user",
                                  with: "# Fedora's own /etc/dconf/profile/user already reads the local database.")
            .replacingOccurrences(of: "update-grub || true",
                                  with: "grubby --update-kernel=ALL --remove-args=\"console=ttyAMA0 console=tty0\" || true")
            .replacingOccurrences(of: "# The install-complete marker, last", with: fedoraExtras + "# The install-complete marker, last")
            .replacingOccurrences(of: "Ubuntu is on the disk", with: "Fedora is on the disk")
            .replacingOccurrences(of: "Ubuntu installed by AVM", with: "Fedora installed by AVM")
    }

    /// The kickstart's %onerror: runs in the installer when the install
    /// fails, including a failed %post (--erroronfail). Without it Anaconda
    /// waits on an error screen with nothing speaking, forever. The same
    /// contract as failureScript: the end of the logs on the UNATTEND volume
    /// (cut to fit its 8 MB), AVMFAIL.TAG, and a power-off.
    static let fedoraFailureScript = """
        # Written by AVM. Runs only if Fedora's install fails.
        set -x
        mkdir -p /run/avm-unattend
        if mount -t vfat /dev/disk/by-label/UNATTEND /run/avm-unattend; then
            for log in /tmp/anaconda.log /tmp/packaging.log /tmp/storage.log /tmp/program.log /mnt/sysroot/root/avm-setup.log; do
                [ -f "$log" ] && tail -c 1200000 "$log" > "/run/avm-unattend/$(basename "$log" .log | cut -c1-8).log"
            done
            echo "Fedora install failed" > /run/avm-unattend/AVMFAIL.TAG
            sync
            umount /run/avm-unattend
        fi
        systemctl poweroff --force || poweroff -f
        """

    /// Fedora's installer: the disc label starts "Fedora", and /.discinfo
    /// (a time stamp, the release, the architecture) and the installer's
    /// kernel are there. A Fedora disc without them is a live image. -lsd,
    /// unlike -find, reports a missing path as a warning and carries on, so
    /// one call answers for all three.
    @concurrent
    static func identifyFedora(isoPath: String, xorriso: URL) async -> UbuntuISOInfo? {
        let listing = await runTool(xorriso, [
            "-indev", isoPath,
            "-lsd", "/images/pxeboot/vmlinuz", "/.discinfo", "--"
        ])
        guard let volumeID = fedoraVolumeID(inXorrisoReport: listing.output), volumeID.hasPrefix("Fedora") else {
            return nil
        }
        let found = Set(listing.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var discInfo = ""
        if found.contains("'/.discinfo'") {
            let fm = FileManager.default
            let probe = fm.temporaryDirectory.appendingPathComponent("avm-fedora-probe-\(UUID().uuidString)")
            try? fm.createDirectory(at: probe, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: probe) }
            let infoURL = probe.appendingPathComponent("discinfo")
            await runTool(xorriso, ["-osirrox", "on", "-indev", isoPath, "-extract", "/.discinfo", infoURL.path])
            discInfo = (try? String(contentsOf: infoURL, encoding: .utf8)) ?? ""
        }
        let info = fedoraISOInfo(volumeID: volumeID, discInfo: discInfo,
                                 hasInstallerKernel: found.contains("'/images/pxeboot/vmlinuz'"))
        ubuntuLog("identify: \(info.spokenName), arm64=\(info.isARM64), live=\(info.isLiveImage), volume id \"\(volumeID)\"")
        return info
    }

    /// The disc label in xorriso's report on a disc it loaded, e.g.
    /// "Volume id    : 'Fedora-E-dvd-aarch64-44'".
    static func fedoraVolumeID(inXorrisoReport report: String) -> String? {
        guard let line = report.range(of: "(?m)^Volume id\\s*:\\s*'[^']*'", options: .regularExpression) else {
            return nil
        }
        let text = report[line]
        guard let open = text.firstIndex(of: "'") else { return nil }
        return String(text[text.index(after: open)...].dropLast())
    }

    /// What a Fedora disc is, from its label, its /.discinfo, and whether
    /// the installer's kernel is there. The release falls back to the
    /// label's last number (Fedora-WS-Live-44), so a live image is still
    /// named in the spoken reason it can't be used.
    static func fedoraISOInfo(volumeID: String, discInfo: String, hasInstallerKernel: Bool) -> UbuntuISOInfo {
        let lines = discInfo.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let release = lines.count > 1 ? lines[1] : ""
        let arch = lines.count > 2 ? lines[2] : ""
        var version = release.range(of: "^[0-9]+$", options: .regularExpression) != nil ? release : ""
        if version.isEmpty, let match = volumeID.range(of: "[0-9]+$", options: .regularExpression) {
            version = String(volumeID[match])
        }
        let isARM64 = arch.isEmpty ? volumeID.contains("aarch64") : arch == "aarch64"
        let isInstaller = hasInstallerKernel && !arch.isEmpty
        return UbuntuISOInfo(discInfo: volumeID, version: version, isARM64: isARM64, isDesktop: true,
                             distro: .fedora, isLiveImage: !isInstaller)
    }

    /// Why AVM can't install from this Fedora disc, or nil when it can.
    /// Fedora 44 or later: it brings Orca 50, which keeps the laptop layout
    /// (Caps Lock as the Orca key, see the file header) where the setup
    /// script writes it, the place proven on Ubuntu 26.04's Orca 50. An
    /// older Orca would leave its key on Insert, which a Mac doesn't have.
    static func fedoraProblem(with info: UbuntuISOInfo) -> String? {
        if info.isLiveImage {
            return "This is a Fedora live image. AVM installs Fedora from the Everything netinstall image instead, which brings the same Fedora Workstation desktop: on fedoraproject.org, download Fedora Everything for aarch64, the netinstall ISO."
        }
        if !info.isARM64 {
            return "This is a Fedora installer for Intel and AMD PCs. This Mac needs the aarch64 one: on fedoraproject.org, download the Fedora Everything netinstall image for aarch64."
        }
        if info.majorVersion == 0 {
            return "AVM couldn't tell which Fedora version this is. AVM needs Fedora 44 or later, from fedoraproject.org."
        }
        if info.majorVersion < 44 {
            return "This is \(info.spokenName). AVM needs Fedora 44 or later."
        }
        return nil
    }

    /// Stage 3 for Fedora: both copies of the boot menu edited (see the
    /// section header), the kickstart added, and the result read back.
    private func stageRebuildFedoraISO(input: Input, scratch: URL) async throws {
        let xorriso = try Self.toolURL(named: "xorriso")
        let mcopy = try Self.toolURL(named: "mcopy")
        let env = ["MTOOLS_SKIP_CHECK": "1"]
        let fm = FileManager.default
        let bootDir = scratch.appendingPathComponent("fedora-boot")
        try? fm.createDirectory(at: bootDir, withIntermediateDirectories: true)
        let grubURL = bootDir.appendingPathComponent("grub.cfg")
        let efiURL = bootDir.appendingPathComponent("efiboot.img")

        let extract = await Self.runTool(xorriso, ["-osirrox", "on", "-indev", input.sourceISOPath,
                                                   "-extract", "/EFI/BOOT/grub.cfg", grubURL.path,
                                                   "-extract", "/images/efiboot.img", efiURL.path])
        guard extract.code == 0, let original = try? String(contentsOf: grubURL, encoding: .utf8),
              fm.fileExists(atPath: efiURL.path) else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't read the installer's boot menu. (xorriso exit \(extract.code))")
        }
        guard let edited = Self.editedFedoraBootMenu(original),
              let label = Self.fedoraVolumeLabel(inBootMenu: original) else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "The installer's boot menu isn't in the form AVM knows, so the answers couldn't be added. This Fedora release may be newer than this version of AVM.")
        }
        do {
            try? fm.removeItem(at: grubURL)
            try edited.write(to: grubURL, atomically: true, encoding: .utf8)
            // Extracted read-only, as it is on the disc.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: efiURL.path)
        } catch {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't write the edited boot menu. (\(error.localizedDescription))")
        }
        // -o: replace the image's own grub.cfg without asking.
        let inner = await Self.runTool(mcopy, ["-o", "-i", efiURL.path, grubURL.path, "::/EFI/BOOT/grub.cfg"],
                                       extraEnvironment: env)
        guard inner.code == 0 else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't edit the installer's EFI boot image. (mcopy exit \(inner.code): \(inner.output.prefix(300)))")
        }

        let output = scratch.appendingPathComponent("install-avm.iso")
        let build = await Self.runTool(xorriso, [
            "-indev", input.sourceISOPath,
            "-outdev", output.path,
            "-map", grubURL.path, "/EFI/BOOT/grub.cfg",
            "-map", efiURL.path, "/images/efiboot.img",
            "-map", scratch.appendingPathComponent("nocloud").path, "/nocloud",
            "-boot_image", "any", "replay"
        ])
        guard build.code == 0 else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "Couldn't build the installer copy. Check that the Mac has about 5 GB free. (xorriso exit \(build.code): \(build.output.suffix(300)))")
        }

        // Postcondition: both menus are the edited one, the kickstart is on
        // the copy, and the copy kept the label the menu finds it by.
        let checkMenu = bootDir.appendingPathComponent("grub-check.cfg")
        let checkImage = bootDir.appendingPathComponent("efiboot-check.img")
        let checkInner = bootDir.appendingPathComponent("grub-inner-check.cfg")
        let verify = await Self.runTool(xorriso, ["-osirrox", "on", "-indev", output.path,
                                                  "-extract", "/EFI/BOOT/grub.cfg", checkMenu.path,
                                                  "-extract", "/images/efiboot.img", checkImage.path,
                                                  "-lsd", Self.fedoraKickstartPath, "--"])
        let readInner = await Self.runTool(mcopy, ["-i", checkImage.path, "::/EFI/BOOT/grub.cfg", checkInner.path],
                                           extraEnvironment: env)
        let arguments = Self.fedoraKernelArguments(volumeLabel: label)
        let menus = [checkMenu, checkInner].map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        guard verify.code == 0, readInner.code == 0,
              menus.allSatisfy({ $0.hasPrefix(Self.markerGuardLine) && $0.contains(arguments) }),
              Self.fedoraVolumeID(inXorrisoReport: verify.output) == label,
              verify.output.contains("\n'\(Self.fedoraKickstartPath)'") else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "The installer copy didn't read back with the answers on it. (xorriso exit \(verify.code), mcopy exit \(readInner.code))")
        }
    }

    static func editedBootMenu(_ original: String) -> String? {
        guard let entry = original.range(of: "linux\\s+/casper/vmlinuz", options: .regularExpression) else {
            return nil
        }
        var menu = original
        menu.replaceSubrange(entry, with: "\(original[entry]) \(kernelArguments)")
        if let timeout = menu.range(of: "(?m)^set timeout=[0-9]+", options: .regularExpression) {
            menu.replaceSubrange(timeout, with: "set timeout=1")
        }
        return markerGuardLine + "\n" + menu
    }

    // MARK: Stage 4 — promote

    private func stagePromote(input: Input, scratch: URL) throws {
        let fm = FileManager.default
        for name in ["install-avm.iso", "autounattend.img"] {
            let src = scratch.appendingPathComponent(name)
            let dst = input.runtimeDir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                throw UbuntuPipelineError.stageFailed(stage: .promote,
                                                     reason: "Couldn't move \(name) into the virtual machine's folder. (\(error.localizedDescription))")
            }
            let size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
            guard size > 0 else {
                throw UbuntuPipelineError.stageFailed(stage: .promote,
                                                     reason: "The file \(name) is missing or empty after finalizing.")
            }
            // Owner-only (2026-10-25, privacy audit): install-avm.iso carries
            // the password hash in its answer file, and the installer logs
            // can land on autounattend.img. QEMU runs as the same user, so
            // it still reads both.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        ubuntuLog("stagePromote: promoted install-avm.iso + autounattend.img to \(input.runtimeDir.path)")
    }

    // MARK: Scratch

    private static func makeScratchDir(for vmID: UUID) throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent(AVMPaths.supportFolderName).appendingPathComponent("scratch")
            .appendingPathComponent(vmID.uuidString)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanScratch() {
        if let scratch = scratchDir {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratchDir = nil
    }

    // MARK: Tools (see the file header on the duplication)

    private static func toolURL(named name: String) throws -> URL {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw UbuntuPipelineError.toolNotFound(name)
        }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            ubuntuLog("toolURL: \(name) not found at \(url.path)")
            throw UbuntuPipelineError.toolNotFound(name)
        }
        return url
    }

    /// Same contract as WindowsInstallPipeline.runTool: the environment is
    /// inherited unchanged (DYLD_LIBRARY_PATH must never be set — it kills
    /// mtools), and the wait happens on a background GCD queue.
    @discardableResult
    private static func runTool(_ executable: URL, _ arguments: [String],
                                extraEnvironment: [String: String] = [:]) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if !extraEnvironment.isEmpty {
                    var env = ProcessInfo.processInfo.environment
                    for (key, value) in extraEnvironment { env[key] = value }
                    process.environment = env
                }
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, "Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }
                // A time limit, as the Windows pipeline's (2026-10-26).
                nonisolated(unsafe) var timedOut = false
                let limit = DispatchWorkItem { timedOut = true; process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 45 * 60, execute: limit)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                limit.cancel()
                var output = String(data: data, encoding: .utf8) ?? ""
                if timedOut { output += "\n\(executable.lastPathComponent) took more than 45 minutes and was stopped. Is the installer's drive still connected?" }
                continuation.resume(returning: (timedOut ? -2 : process.terminationStatus, output))
            }
        }
    }
}
