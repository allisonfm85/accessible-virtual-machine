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
        let reserved: Set<String> = ["root", "daemon", "bin", "sys", "sync", "games", "man", "lp",
                                     "mail", "news", "uucp", "proxy", "www-data", "backup", "list",
                                     "irc", "nobody", "systemd-network", "messagebus", "syslog",
                                     "gdm", "admin", "sudo", "ubuntu"]
        if reserved.contains(name) {
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
        if trimmed.count > 160 {
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

    func save(inVMDirectory dir: URL) throws {
        let url = dir.appendingPathComponent(Self.fileName)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(fromVMDirectory dir: URL) -> UbuntuAccount? {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UbuntuAccount.self, from: data)
    }

    static func delete(fromVMDirectory dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }
}

// MARK: - What the ISO is

/// What AVM read off an installer ISO, used by the Setup Wizard to say what
/// the user picked and by the pipeline's validation gate.
nonisolated struct UbuntuISOInfo: Equatable {
    /// From /.disk/info, e.g. "Ubuntu 26.04.1 LTS \"Resolute Raccoon\" - Release arm64".
    let discInfo: String
    /// e.g. "26.04.1", or "" when /.disk/info doesn't say.
    let version: String
    let isARM64: Bool
    let isDesktop: Bool

    /// A spoken-friendly name, e.g. "Ubuntu 26.04.1 LTS desktop".
    var spokenName: String {
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
        case .rebuildISO:       return "Adding the answers to the Ubuntu installer"
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

    /// Read what an ISO is, without changing anything. nil when it isn't an
    /// Ubuntu installer at all (no /casper/vmlinuz). Runs xorriso; call off
    /// the main actor.
    @concurrent
    static func identify(isoPath: String) async -> ISOIdentity {
        guard let xorriso = try? toolURL(named: "xorriso") else {
            return .unreadable("A required tool (xorriso) is missing from the app. This is a build problem, not something you did.")
        }
        // One path per -find. On a disc with no /casper/vmlinuz the first
        // -find fails and xorriso stops, which is the answer: not Ubuntu.
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
            // reports the path missing, so a blank medium is "couldn't
            // read", not "not Ubuntu" (proven with an unreadable file).
            let blank = listing.output.contains("Media status : is blank")
            if !blank && listing.output.contains("Cannot find path '/casper/vmlinuz'") {
                ubuntuLog("identify: no /casper/vmlinuz — not an Ubuntu installer")
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
    static func problem(with info: UbuntuISOInfo?) -> String? {
        guard let info else {
            return "This ISO isn't an Ubuntu installer AVM recognizes."
        }
        if !info.isARM64 {
            return "This is an Ubuntu installer for Intel and AMD PCs. This Mac needs the ARM version: on ubuntu.com, download Ubuntu Desktop for ARM."
        }
        if !info.isDesktop {
            return "This is the Ubuntu Server installer. AVM needs Ubuntu Desktop for ARM, which brings the desktop and the Orca screen reader."
        }
        if info.majorVersion != 0 && info.majorVersion < 24 {
            return "This is \(info.spokenName). AVM needs Ubuntu 24.04 or later, whose installer can run without questions."
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
                case .writeAnswers:     try stageWriteAnswers(input: input, account: account, scratch: scratch)
                case .buildMarkerImage: try await stageBuildMarkerImage(scratch: scratch)
                case .rebuildISO:       try await stageRebuildISO(input: input, scratch: scratch)
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

    private func stageWriteAnswers(input: Input, account: UbuntuAccount, scratch: URL) throws {
        let nocloud = scratch.appendingPathComponent("nocloud")
        do {
            try FileManager.default.createDirectory(at: nocloud, withIntermediateDirectories: true)
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
          keyboard: {layout: us}
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
        curtin in-target -- dconf update
        grep -q 'screen-reader-enabled=true' $T/etc/dconf/db/local.d/00-avm
        grep -q 'screen-reader-enabled=true' $T/etc/dconf/db/gdm.d/00-avm
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
        # The UNATTEND volume stays attached for the marker; keep it out of
        # the desktop's drive list (and out of Orca's announcements).
        echo 'ENV{ID_FS_LABEL}=="UNATTEND", ENV{UDISKS_IGNORE}="1"' > $T/etc/udev/rules.d/99-avm-unattend.rules
        # The install-complete marker, last: Ubuntu is on the disk.
        mkdir -p /run/avm-unattend
        mount -t vfat /dev/disk/by-label/UNATTEND /run/avm-unattend || exit 1
        echo "Ubuntu installed by AVM" > /run/avm-unattend/AVMDONE.TAG
        sync
        umount /run/avm-unattend
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

    private func stageRebuildISO(input: Input, scratch: URL) async throws {
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
        guard let edited = Self.editedBootMenu(original) else {
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
              readBack.contains(Self.kernelArguments),
              verify.output.contains("\n'/nocloud/user-data'"),
              verify.output.contains("\n'/nocloud/setup.sh'"),
              verify.output.contains("\n'/nocloud/failed.sh'") else {
            throw UbuntuPipelineError.stageFailed(stage: .rebuildISO,
                                                 reason: "The installer copy didn't read back with the answers on it. (xorriso exit \(verify.code))")
        }
    }

    /// The installer's boot menu with the marker guard first, a one-second
    /// timeout, and the autoinstall words on the first entry. nil when the
    /// menu has no `linux /casper/vmlinuz` line to edit.
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
        }
        ubuntuLog("stagePromote: promoted install-avm.iso + autounattend.img to \(input.runtimeDir.path)")
    }

    // MARK: Scratch

    private static func makeScratchDir(for vmID: UUID) throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("AVM").appendingPathComponent("scratch")
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
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }
}
