// VMConfiguration.swift
// AVM — Accessible Virtual Machine

import Foundation

/// Persistent configuration for a single virtual machine.
/// Stored as JSON in Application Support/AVM/configurations.json via VMStore.
/// (Comment trued 2026-08-15: previously said "vms.json", a filename that has
/// never existed in a shipped build.)
///
/// ADDING A SETTING (2026-09-26, USB increment 2b): every VM shares one
/// configurations.json, and this type uses Swift's automatic Codable. The
/// automatic loader fails on a missing key for any property that is not
/// optional, and one failure hides every VM in the file. So every setting
/// added after 0.1.2 MUST be optional, with nil meaning "use the default".
/// Older files then load unchanged, and an older AVM ignores keys it does
/// not know.
struct VMConfiguration: Identifiable, Codable, Hashable {

    // MARK: - Identity

    var id: UUID
    var name: String

    // MARK: - Hardware

    var cpuCount: Int
    var ramSizeGB: Int
    var diskSizeGB: Int

    // MARK: - Storage paths

    /// Absolute path to the primary qcow2 disk image for this VM.
    var diskImagePath: String

    /// Absolute path to the installation ISO, if one is attached.
    /// Nil means no optical drive is present.
    var installISOPath: String?
    /// true once a Start has found the install-complete marker on the
    /// UNATTEND volume (2026-10-28). From then on, a volume without the
    /// marker but a disk holding data is still treated as installed (the
    /// marker's volume is a drive Windows can see and empty); before then,
    /// no marker means the install isn't finished, and an interrupted one
    /// starts again from the DVD.
    var installMarkerSeen: Bool?
    /// A "Fresh install" restore point is owed (2026-10-28): the first
    /// sign-in was seen on a Start that carried on from a saved state,
    /// where no point can be taken; the next plain Start takes it.
    var freshInstallPointPending: Bool?

    // MARK: - Shared folder

    /// A Mac folder the guest sees as a network drive, over SPICE WebDAV
    /// (2026-10-26). nil shares nothing. Read it through sharedFolderURL.
    var sharedFolderPath: String?
    /// true: the guest can read the shared folder but not change it.
    var sharedFolderReadOnly: Bool?

    // MARK: - USB plug and play (increment 2b)

    /// What happens when a USB device is plugged in while this VM is
    /// running. Stored as plain text, not as an enum, on purpose: an
    /// unknown word from a newer AVM must read as the default, never fail
    /// the load. nil or an unknown word means Ask each time. Read it
    /// through effectiveUSBMode, never directly.
    var usbMode: String?

    /// Devices the user chose "Remember for this device" for, in the ask
    /// alert. nil means none remembered yet.
    var usbRememberedDevices: [RememberedUSBDevice]?

    // MARK: - Guest operating system (Ubuntu, 2026-10-19)

    /// Which operating system this VM installs and runs. Plain text for the
    /// same reason as usbMode. nil, or a word this AVM doesn't know, means
    /// Windows: every VM made before Ubuntu support is a Windows VM. Read
    /// it through guestOS, never directly.
    var guestOSName: String?

    // MARK: - Windows edition (2026-10-25)

    /// Which edition Windows Setup installs: a WindowsEdition raw value.
    /// Plain text for the same reason as usbMode. nil, or a word this AVM
    /// doesn't know, means the install pipeline's own default (Windows 11
    /// Pro), exactly as before the setup wizard asked. Read it through
    /// windowsEdition, never directly.
    var windowsEditionName: String?

    // MARK: - Storage location (2026-10-25, roadmap item 3)

    /// Absolute path of this VM's own folder (disk.qcow2, nvram, tpm-state,
    /// install media) when the user stored it somewhere other than
    /// Application Support, such as an external drive. nil means the
    /// Application Support layout, exactly as before. Read the folder
    /// through directoryURL(), never directly.
    var storageFolderPath: String?
    /// The drive storageFolderPath is on (2026-11-05, second audit), so a
    /// drive that mounts under another name ("Backup 1" after a stale mount
    /// folder) is still found: the path is rebuilt from the volume with this
    /// UUID. nil for the Mac's own disk, and for machines made before this;
    /// recorded at the next start.
    var storageVolumeUUID: String?

    // MARK: - Secure Boot (2026-10-25, roadmap item 8)

    /// true: the VM boots UTM's Secure Boot firmware, whose variable store
    /// carries Microsoft's KEK and db certificates with Secure Boot on, so
    /// Windows Update's Secure Boot check passes (Insider builds). nil or
    /// false: the original firmware, exactly as before. New Windows VMs
    /// get true from the setup wizard; existing ones change it in Settings.
    var secureBoot: Bool?

    // MARK: - Clipboard (2026-10-25)

    /// Share the clipboard with the guest, through the SPICE agent AVM
    /// installs (AVMPasteboard). nil means on, the default; false keeps the
    /// two clipboards apart. Read it through sharesClipboard.
    var shareClipboard: Bool?

    /// true: the machine may use the Mac's microphone (2026-10-27). Off
    /// unless chosen. Read it through sharesMicrophone.
    var shareMicrophone: Bool?

    /// How much sound QEMU holds ahead for the Mac (2026-10-28, a tester's
    /// crackle): SoundSmoothness's raw value; nil: balanced. Read it
    /// through soundSmoothness.
    var soundBuffer: String?
    /// Automatic backups (MachineBackups.swift): "daily" or "weekly"; nil for none.
    var backupEvery: String?
    var lastBackup: Date?
    /// Being installed with "use my saved screen reader setup" on: put in once
    /// someone first signs in (ScreenReaderSetup.swift).
    var wantsSavedScreenReaderSetup: Bool?
    /// Which ear this machine's sound goes to (2026-11-01, the user's request:
    /// its screen reader in one ear and VoiceOver in the other): "left" or
    /// "right"; nil for both. Windows and Linux: QEMU's patch
    /// hda-per-ear-levels applies it, live.
    var soundEarChoice: String?
    /// This machine's volume, 0 to 100; nil for 100.
    var soundVolume: Int?

    /// The Mac output this machine plays through (2026-10-30,
    /// SoundOutputDevices.swift), by its Core Audio unique ID, and its name
    /// for Settings while it isn't connected; nil: the Mac's default output.
    var soundOutputUID: String?
    var soundOutputName: String?

    // MARK: - Remote Desktop (2026-10-28, RemoteDesktop.swift)

    /// The account the Windows App signs in with; nil: Remote Desktop off.
    /// The password is in the keychain, by the machine's id.
    var remoteDesktopUser: String?
    /// "mac": reachable from this Mac only; "network": from the whole
    /// network. nil: this Mac only.
    var remoteDesktopReach: String?
    /// The port on the Mac forwarded to the machine's 3389, kept once
    /// chosen so the address stays the same.
    var remoteDesktopPort: Int?
    /// A mark of the password last set in the machine (not the password):
    /// the account's password is set again only when the one in the
    /// keychain differs (2026-10-28), never at every start, since an
    /// administrator's reset of an existing account loses what Windows
    /// encrypted under the old one.
    var remoteDesktopPasswordMark: String?

    /// true: the machine has a USB camera fed by the Mac's camera
    /// (2026-10-27, AVM's QEMU usb-camera). Off unless chosen. Read it
    /// through sharesCamera.
    var shareCamera: Bool?

    /// true: a Linux machine draws with the Mac's GPU (2026-10-27):
    /// virtio-gpu-gl-pci, virglrenderer and ANGLE on Metal. Off unless
    /// chosen; Windows has no driver for it. QEMU can't save a machine
    /// using it ("virgl is not yet migratable"), so Save with Open Apps is
    /// off while it's on. Read it through uses3D.
    var gpu3D: Bool?

    // MARK: - Braille display follow-through (2026-10-26)

    /// What happens when a braille display comes back within a minute of
    /// leaving Windows. "send" (or nil): it follows the user's earlier choice
    /// back to Windows, as a Monarch needs when it switches modes. "ask":
    /// AVM asks, as for any braille display, because unplugging it to take
    /// it back from Windows looks the same. Read it through
    /// brailleFollowsBack.
    var brailleFollowThrough: String?

    // MARK: - Keyboard for Windows (2026-10-26)

    /// A second keyboard that types only into Windows (WindowsKeyboard
    /// .swift), by the helper's identifier for it; nil: none. The name is
    /// for saying which one, even when it isn't connected.
    var windowsKeyboardID: String?
    var windowsKeyboardName: String?
    /// true: an Apple ISO keyboard, whose § and ` keys AVM swaps back
    /// (HIDKeyMap.isoSwapped). nil: a PC or ANSI keyboard, as it is.
    var windowsKeyboardAppleISO: Bool?
    /// Windows apps in the Mac's Command-Tab list (WindowsApps.swift,
    /// 2026-10-29); nil: on.
    var windowsAppsInCommandTab: Bool?
    /// The trackpad and mouse do nothing in the machine while the keyboard
    /// is in it (VMView's SPICECoordinator, 2026-10-30); nil: they work.
    /// Not for a macOS machine, which has its own view.
    var trackpadAndMouseOff: Bool?
    /// The machine's own app in the Mac's Command-Tab list while it runs
    /// (WindowsApps.syncMachines, 2026-10-30); nil: the default, which is
    /// isInCommandTab.
    var inCommandTab: Bool?

    // MARK: - Display (2026-10-28)

    /// The display the machine's window always opens on, filling it
    /// (MachineDisplays.swift), by macOS's lasting id for it; nil: wherever
    /// it was last. The name is for saying which, even when it isn't
    /// connected.
    var displayID: String?
    var displayName: String?

    /// macOS machines: false for a new machine whose first start hasn't
    /// offered macOS's VoiceOver yet, true once it has; nil for machines
    /// made before this existed (MacGuestRunner.offerVoiceOverOnce).
    var macVoiceOverOffered: Bool?

    // MARK: - Sound (2026-10-26)

    /// true: the experimental shorter audio path (SpiceAudioPipeline).
    /// Read it through usesLowAudioLatency. Unused since 2026-10-27, when
    /// QEMU started playing the guest's sound itself (shorter still); kept
    /// so saved machines keep their record.
    var lowAudioLatency: Bool?

    // MARK: - Screen readers in Windows (2026-10-26)

    /// Screen readers AVM installs during Windows setup: ScreenReader raw
    /// values. nil or empty means none, Narrator only, as before. Read it
    /// through windowsScreenReaders.
    var windowsScreenReaderNames: [String]?

    // MARK: - Disk controller (2026-10-27)

    /// "virtio": the disk is a virtio-blk device, which QEMU can save with
    /// the machine running (Save and Close, restore points with memory).
    /// nil: NVMe, as every machine made before this; QEMU 10's NVMe device
    /// refuses to be saved ("non-migratable device"). New machines get
    /// "virtio". Read it through usesVirtioDisk.
    var diskBus: String?
    /// Moving an older machine to the virtio disk (2026-10-27), chosen in
    /// Settings: "pending" until the guest agent has made it ready (the
    /// driver for Windows, the start-up image for Linux); "firstBoot" for
    /// the first Start on the virtio disk, which switches back to NVMe if
    /// the machine doesn't come up. nil otherwise.
    var diskBusSwitch: String?

    // MARK: - More disk (2026-11-03)

    /// true: the disk has grown and Windows' drive C hasn't taken the new space
    /// yet; the next Start does it through the guest agent (MachineDrives.swift).
    var extendDriveC: Bool?
    /// The second drive's size in gigabytes, nil with none. Its file is
    /// secondDriveFileName in the machine's folder.
    var secondDriveGB: Int?
    /// true until the guest has made the second drive ready to use.
    var secondDriveNeedsFormat: Bool?
    static let secondDriveFileName = "drive2.qcow2"

    // MARK: - Templates (2026-10-27)

    /// true: a template, kept as it is; its row offers New Machine from
    /// Template (a duplicate) instead of Start. Read it through isATemplate.
    var isTemplate: Bool?

    /// true: Start runs it in the background, with no window (2026-10-27,
    /// as Hyper-V's and VMware's headless machines); Enter opens one.
    /// Read it through startsWithoutWindow.
    var noWindow: Bool?

    /// true: at each Start, the Mac's network printers are added in the
    /// machine (2026-10-27, MacPrinters.swift). Read it through
    /// sharesPrinters.
    var sharePrinters: Bool?

    // MARK: - Defaults

    init(
        id: UUID = UUID(),
        name: String = "Windows 11",
        cpuCount: Int = 4,
        ramSizeGB: Int = 8,
        diskSizeGB: Int = 64,
        diskImagePath: String = "",
        installISOPath: String? = nil,
        sharedFolderPath: String? = nil,
        usbMode: String? = nil,
        usbRememberedDevices: [RememberedUSBDevice]? = nil,
        guestOSName: String? = nil,
        windowsEditionName: String? = nil,
        storageFolderPath: String? = nil,
        storageVolumeUUID: String? = nil,
        secureBoot: Bool? = nil,
        shareClipboard: Bool? = nil,
        windowsScreenReaderNames: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.ramSizeGB = ramSizeGB
        self.diskSizeGB = diskSizeGB
        self.diskImagePath = diskImagePath
        self.installISOPath = installISOPath
        self.sharedFolderPath = sharedFolderPath
        self.usbMode = usbMode
        self.usbRememberedDevices = usbRememberedDevices
        self.guestOSName = guestOSName
        self.windowsEditionName = windowsEditionName
        self.storageFolderPath = storageFolderPath
        self.storageVolumeUUID = storageVolumeUUID
        self.secureBoot = secureBoot
        self.shareClipboard = shareClipboard
        self.windowsScreenReaderNames = windowsScreenReaderNames
    }
}

extension VMConfiguration {
    var usesSecureBoot: Bool { secureBoot == true }
    var sharesClipboard: Bool { shareClipboard ?? true }
    var sharesMicrophone: Bool { shareMicrophone == true }
    var soundSmoothness: SoundSmoothness { soundBuffer.flatMap(SoundSmoothness.init(rawValue:)) ?? .balanced }
    var soundEar: SoundEar { soundEarChoice.flatMap(SoundEar.init(rawValue:)) ?? .both }
    /// Each ear's level, 0 to 100.
    var soundLevels: (left: Int, right: Int) {
        let volume = max(0, min(100, soundVolume ?? 100))
        return (soundEar == .right ? 0 : volume, soundEar == .left ? 0 : volume)
    }
    var brailleFollowsBack: Bool { brailleFollowThrough != "ask" }
    /// The shared folder, if one is chosen and is a folder right now (an
    /// unplugged drive shares nothing rather than failing the start).
    var sharedFolderURL: URL? {
        guard let path = sharedFolderPath, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    var sharedFolderIsReadOnly: Bool { sharedFolderReadOnly == true }
    var usesLowAudioLatency: Bool { lowAudioLatency == true }
    var usesVirtioDisk: Bool { diskBus == "virtio" }
    var isATemplate: Bool { isTemplate == true }
    var startsWithoutWindow: Bool { noWindow == true }
    var sharesPrinters: Bool { sharePrinters == true }
    var sharesCamera: Bool { shareCamera == true }
    /// Off by default with a Keyboard for Windows (2026-10-31, a tester):
    /// someone who gives Windows its own keyboard wants Command-Tab to stay
    /// the Mac's, not to land in Windows by accident. A choice made in
    /// Settings (true or false) wins either way.
    static func inCommandTabByDefault(keyboard: String?) -> Bool { keyboard == nil }
    var isInCommandTab: Bool { inCommandTab ?? Self.inCommandTabByDefault(keyboard: windowsKeyboardID) }
    var hasWindowsAppsInCommandTab: Bool { windowsAppsInCommandTab ?? Self.inCommandTabByDefault(keyboard: windowsKeyboardID) }
    /// Windows too (2026-11-01, experimental, Windows3D.swift).
    var uses3D: Bool { gpu3D == true && (guestOS.isLinux || guestOS == .windows) }
    var usesWindows3D: Bool { gpu3D == true && guestOS == .windows }
    /// Known screen readers only, in a fixed order; unknown words ignored.
    var windowsScreenReaders: [ScreenReader] {
        let chosen = Set(windowsScreenReaderNames ?? [])
        return ScreenReader.allCases.filter { chosen.contains($0.rawValue) }
    }
}

// MARK: - Storage location

extension VMConfiguration {

    /// Application Support/AVM/VMs, where every VM lives unless the user
    /// chose another folder. Spelled "VMs", as VMStore's layout of record
    /// has it (the lowercase "vms" some older code used is the same folder
    /// on a case-insensitive disk).
    static func defaultVMsContainer() throws -> URL {
        try AVMPaths.supportDirectory().appendingPathComponent("VMs")
    }

    /// The folder that holds every file belonging to this VM. Computed
    /// from the UUID, or from storageFolderPath when the user chose a
    /// folder; never derived from diskImagePath (see VMStore).
    func directoryURL() throws -> URL {
        if let path = storageFolderPath {
            return URL(fileURLWithPath: Self.resolvedStoragePath(path, volumeUUID: storageVolumeUUID), isDirectory: true)
        }
        return try Self.defaultVMsContainer().appendingPathComponent(id.uuidString)
    }

    var isStoredElsewhere: Bool { storageFolderPath != nil }

    /// Only this account can open a machine's folder (2026-11-05 audit). In a
    /// folder the user chose, it was 0755 with the disk and firmware settings
    /// 0644, so every account on the Mac could read Windows' disk; machines
    /// in Application Support were kept private only by the home folder. The
    /// folder that holds machine folders in a chosen place must be this
    /// account's: one another account made first (in /Users/Shared, say)
    /// could rename or swap every machine in it.
    nonisolated struct MachineFolderError: LocalizedError { let errorDescription: String? }

    nonisolated static func makePrivate(machineFolder dir: URL) throws {
        let parent = dir.deletingLastPathComponent()
        // Only on the Mac's own volume (2026-11-05, second audit): on a share
        // or a drive that keeps ownership, the uid is whoever made the folder
        // on another computer, and machines that ran yesterday were refused.
        if parent.lastPathComponent == "AVM Virtual Machines" {
            var info = stat(), users = stat()
            if lstat(parent.path, &info) == 0, stat("/Users", &users) == 0, info.st_dev == users.st_dev, info.st_uid != getuid() {
                throw MachineFolderError(errorDescription: "The folder \(parent.path) belongs to another account on this Mac, so AVM won't keep machines in it. Next: move the machine to a folder of your own.")
            }
        }
        chmod(dir.path, 0o700)
    }

    /// True when the VM was stored in a folder of the user's choosing and
    /// that folder can't be found now: almost always an external drive
    /// that isn't connected. Start and Delete refuse, and say so.
    var storageIsMissing: Bool {
        guard let path = storageFolderPath else { return false }
        var isDirectory: ObjCBool = false
        let resolved = Self.resolvedStoragePath(path, volumeUUID: storageVolumeUUID)
        return !(FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// The UUID of the volume holding `url`, for storageVolumeUUID.
    nonisolated static func volumeUUID(of url: URL) -> String? {
        try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    /// `path` as saved, or, when it isn't there and names a drive under
    /// /Volumes, the same place on whichever mounted volume has `volumeUUID`
    /// (2026-11-05, second audit). Before, a drive mounted as "Backup 1"
    /// stranded its machines with "isn't connected" while it was.
    nonisolated static func resolvedStoragePath(_ path: String, volumeUUID: String?) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
        guard let volumeUUID else { return path }
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return path }
        let rest = parts.dropFirst(3)
        for volume in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeUUIDStringKey])) ?? [] {
            guard self.volumeUUID(of: volume) == volumeUUID else { continue }
            let candidate = rest.reduce(volume) { $0.appendingPathComponent($1) }.path
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue { return candidate }
        }
        return path
    }

    /// A folder iCloud syncs (2026-11-05, second audit): iCloud Drive, or
    /// Desktop and Documents with their sync on. iCloud can evict a machine's
    /// disk from such a folder to make room, and a Start then saw an empty
    /// disk and reinstalled over it.
    nonisolated static func isInICloud(_ url: URL) -> Bool {
        if url.standardizedFileURL.path.contains("/Library/Mobile Documents/") { return true }
        return (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// The name of the drive holding the VM, for speech: "Backup Drive".
    /// Read from the path when the drive isn't connected. nil for the
    /// Mac's own disk.
    var storageDriveName: String? {
        guard let path = storageFolderPath else { return nil }
        let parts = URL(fileURLWithPath: path).pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return parts[2]
        }
        return nil
    }

    /// The spoken refusal when storageIsMissing.
    var storageMissingMessage: String {
        if let drive = storageDriveName {
            return "\(name) is stored on the drive \(drive), which isn't connected. Next: connect \(drive), then try again."
        }
        return "AVM can't find the folder that holds \(name), at \(storageFolderPath ?? "its saved location"). Next: if it's on an external drive, connect the drive, then try again. If the drive is connected under another name, such as its name and a 1, eject it, then connect it again."
    }
}

// MARK: - Guest operating system

/// The operating systems AVM installs. Raw values are the words
/// guestOSName stores.
enum GuestOS: String {
    case windows
    case ubuntu
    /// Debian, installed the Ubuntu way: same account, Orca and markers,
    /// Debian's own preseed answers (UbuntuInstallPipeline.swift).
    case debian
    /// Fedora Workstation, installed the Ubuntu way (2026-10-26): same
    /// account, Orca and markers, Fedora's own kickstart answers, from the
    /// Everything netinstall ISO (UbuntuInstallPipeline.swift).
    case fedora
    /// Kali Linux (2026-10-30, the user's request): Debian's installer and
    /// preseed answers, with Kali's own mirror, GNOME desktop and default
    /// tools (UbuntuInstallPipeline.swift).
    case kali
    /// AlmaLinux and Rocky Linux (2026-10-30, the user's request): Fedora's
    /// way, Anaconda and a kickstart, Server with GUI from their own servers
    /// (UbuntuInstallPipeline.swift).
    case almalinux, rocky
    /// openSUSE Tumbleweed (2026-10-30, the user's request): YaST with an
    /// AutoYaST profile, GNOME from openSUSE's own repository
    /// (UbuntuInstallPipeline.swift).
    case opensuse
    /// Runs on Apple's Virtualization framework, not QEMU (MacGuest.swift).
    case macOS

    /// The name AVM says and shows for the running guest: "Enter Ubuntu",
    /// "Ubuntu keyboard on", "Send the keyboard to Ubuntu?".
    var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .ubuntu: return "Ubuntu"
        case .debian: return "Debian"
        case .fedora: return "Fedora"
        case .kali: return "Kali Linux"
        case .almalinux: return "AlmaLinux"
        case .rocky: return "Rocky Linux"
        case .opensuse: return "openSUSE"
        case .macOS: return "macOS"
        }
    }

    /// Every guest but Windows and macOS: AVM's Linux install and run path
    /// (account, Orca, install markers, stall watch).
    var isLinux: Bool { self != .windows && self != .macOS }

    /// Remote Desktop's host is GNOME's own (gnome-remote-desktop), not
    /// xrdp (RemoteDesktop.setUpGNOMERemoteDesktop).
    // MEASURED 2026-10-31 (launch suite): AlmaLinux and Rocky 10 have no
    // xrdp, and nor has EPEL 10 (EPEL 9 had); setup ended in "Unable to
    // find a match: xrdp xorgxrdp".
    var remoteDesktopIsGNOME: Bool { self == .almalinux || self == .rocky }

    /// The shared folder's guest service, spice-webdavd, is there, so
    /// Settings offers a shared folder: on Rocky, AlmaLinux's, which AVM
    /// installs (UbuntuInstallPipeline.rockyWebDAV, 2026-10-31).
    var hasSharedFolderService: Bool { self != .macOS }
}

extension VMConfiguration {
    var guestOS: GuestOS {
        guestOSName.flatMap(GuestOS.init(rawValue:)) ?? .windows
    }
}

// MARK: - Windows edition

/// The Windows 11 editions the setup wizard offers. Raw values are the
/// words windowsEditionName stores.
enum WindowsEdition: String, CaseIterable, Identifiable {
    case pro
    case home
    case homeSingleLanguage

    var id: String { rawValue }

    /// The edition's name inside install.wim, which the answer file's
    /// /IMAGE/NAME selects. Spoken and shown as is.
    var imageName: String {
        switch self {
        case .pro: return "Windows 11 Pro"
        case .home: return "Windows 11 Home"
        case .homeSingleLanguage: return "Windows 11 Home Single Language"
        }
    }

    /// Microsoft's public generic install key for the edition. It tells
    /// Setup which edition to install and activates nothing; Windows asks
    /// for the user's own key or digital license later.
    var genericProductKey: String {
        switch self {
        case .pro: return "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        case .home: return "YTMG3-N6DKC-DKB77-7M9GH-8HVX7"
        case .homeSingleLanguage: return "BT79Q-G7N6G-PGBYW-4YWX6-6F4BT"
        }
    }
}

extension VMConfiguration {
    /// The chosen edition, or nil for the pipeline's default.
    var windowsEdition: WindowsEdition? {
        windowsEditionName.flatMap(WindowsEdition.init(rawValue:))
    }
}

// MARK: - USB plug and play types (increment 2b)

/// The three choices in Settings, under "When a USB device is plugged in
/// while this virtual machine is running". Raw values are the words that
/// usbMode stores.
enum USBPlugMode: String {
    /// Ask each time. The default.
    case ask
    /// Always use in Windows. Input devices, such as keyboards and braille
    /// displays, still ask: taking one from the Mac by accident can leave a
    /// blind user unable to type on the Mac. The exact test lives with the
    /// hot-plug watcher.
    case always
    /// Keep on the Mac. The Virtual Machine menu can still attach anything.
    case keepOnMac
}

extension VMConfiguration {
    /// The mode to act on. nil or an unknown word reads as Ask each time.
    var effectiveUSBMode: USBPlugMode {
        usbMode.flatMap(USBPlugMode.init(rawValue:)) ?? .ask
    }
}

/// One remembered decision. Matched on vendor ID, product ID, and serial
/// number, so two identical devices that have serial numbers are told
/// apart. Devices with no serial number share one decision per vendor and
/// product.
struct RememberedUSBDevice: Codable, Hashable, Identifiable {
    /// The product name when the decision was made, shown in Settings.
    var name: String
    var vendorID: Int
    var productID: Int
    var serialNumber: String?
    /// "windows" or "mac". Plain text for the same reason as usbMode.
    var decision: String

    var id: String {
        "\(vendorID):\(productID):\(serialNumber ?? "")"
    }

    /// true means use in Windows, false means keep on the Mac. nil means an
    /// unknown word from a newer AVM, which callers treat as not
    /// remembered, so AVM asks.
    var usesWindows: Bool? {
        switch decision {
        case "windows": return true
        case "mac": return false
        default: return nil
        }
    }

    func matches(vendorID: Int, productID: Int, serialNumber: String?) -> Bool {
        self.vendorID == vendorID
            && self.productID == productID
            && self.serialNumber == serialNumber
    }
}

// MARK: - Screen readers (2026-10-26)

/// Screen readers AVM can install in Windows during setup. Raw values are
/// the words windowsScreenReaderNames stores.
nonisolated enum ScreenReader: String, CaseIterable, Identifiable, Sendable {
    case nvda
    case jaws

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nvda: return "NVDA"
        case .jaws: return "JAWS"
        }
    }

    /// Its name on the install media: short and upper case, so every
    /// namespace on the rebuilt ISO carries it unchanged.
    var mediaFileName: String {
        switch self {
        case .nvda: return "NVDA.EXE"
        case .jaws: return "JAWS.EXE"
        }
    }

    /// The only host its installer may come from. A download link
    /// anywhere else is refused, even if a manifest names it.
    var vendorHost: String {
        switch self {
        case .nvda: return "download.nvaccess.org"
        case .jaws: return "software.vfo.digital"
        }
    }

    /// About how big its installer is, for the room check before it has
    /// downloaded (2026-10-29, sixth audit). On the generous side.
    var typicalBytes: Int64 {
        switch self {
        case .nvda: return 120 << 20
        case .jaws: return 1700 << 20
        }
    }
}

// MARK: - QEMU option values (2026-10-25)

/// A value for a comma-separated QEMU option: QEMU reads a comma as the
/// start of the next option and escapes a literal one by doubling it.
/// Used by VMManager.qemuOptionValue for every file path it passes.
nonisolated enum QEMUOption {
    static func value(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }
}

/// The guest's sound on the Mac (2026-10-26). spice-gtk plays it through a
/// GStreamer pipeline with no ceiling on buffering: about a second can
/// pile up in its queues, plus 200 ms in the Mac output's ring buffer, and
/// over a long session the guest's and the Mac's audio clocks drift apart,
/// so speech can end up audibly late. spice-gtk lets the app replace the
/// pipeline (the SPICE_GST_AUDIOSINK environment variable, read in-process
/// when playback starts). This one is the same chain with ceilings: at
/// most 50 ms queued and a 50 ms output buffer, dropping the oldest audio
/// rather than falling behind. The guest always sends 48 kHz stereo here:
/// this spice-server is built with Opus, and Opus playback is 48 kHz.
/// Experimental: a busy Mac may crackle. Measure with
/// Tools/measure-speech-latency.sh, on and off.
nonisolated enum SpiceAudioPipeline {
    static let environmentName = "SPICE_GST_AUDIOSINK"
    static let lowLatency =
        #"appsrc is-live=1 do-timestamp=0 format=time caps="audio/x-raw,format=S16LE,channels=2,rate=48000,layout=interleaved" name="appsrc" max-bytes=19200 leaky-type=downstream ! "#
        + "queue max-size-buffers=0 max-size-bytes=0 max-size-time=50000000 leaky=downstream ! "
        + #"audioconvert ! audioresample ! osxaudiosink name="audiosink" buffer-time=50000 latency-time=10000"#

    /// Sets or clears the variable for the next SPICE connection.
    static func apply(lowLatency on: Bool) {
        if on {
            setenv(environmentName, lowLatency, 1)
        } else {
            unsetenv(environmentName)
        }
    }
}

// MARK: - Sound smoothness (2026-10-28)

/// The trade between how soon speech is heard and how smoothly sound plays
/// on a busy Mac: the size and number of QEMU's output buffers. Measured
/// key-to-speech with Orca (VMManager's SOUND note): 2.5 ms x 2 was 389 ms,
/// 5 ms x 2 430 ms. Smallest crackled in Windows on a tester's Mac
/// (2026-10-28), so the middle one is the default.
enum SoundEar: String, CaseIterable, Identifiable {
    case both
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "Both ears"
        case .left: return "Left ear only"
        case .right: return "Right ear only"
        }
    }
}

enum SoundSmoothness: String, CaseIterable, Identifiable {
    case fastest
    case balanced
    case smoothest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastest: return "Fastest speech: may crackle on a busy Mac"
        case .balanced: return "Balanced"
        case .smoothest: return "Smoothest sound: speech a little later"
        }
    }

    /// QEMU's out.buffer-length (microseconds) and out.buffer-count.
    var buffer: (microseconds: Int, count: Int) {
        switch self {
        case .fastest: return (2500, 2)
        case .balanced: return (5000, 3)
        case .smoothest: return (10000, 4)
        }
    }
}
