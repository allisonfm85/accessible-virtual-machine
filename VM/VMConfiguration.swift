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
        self.secureBoot = secureBoot
        self.shareClipboard = shareClipboard
        self.windowsScreenReaderNames = windowsScreenReaderNames
    }
}

extension VMConfiguration {
    var usesSecureBoot: Bool { secureBoot == true }
    var sharesClipboard: Bool { shareClipboard ?? true }
    var sharesMicrophone: Bool { shareMicrophone == true }
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
    var uses3D: Bool { gpu3D == true && guestOS.isLinux }
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
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return try Self.defaultVMsContainer().appendingPathComponent(id.uuidString)
    }

    var isStoredElsewhere: Bool { storageFolderPath != nil }

    /// True when the VM was stored in a folder of the user's choosing and
    /// that folder can't be found now: almost always an external drive
    /// that isn't connected. Start and Delete refuse, and say so.
    var storageIsMissing: Bool {
        guard let path = storageFolderPath else { return false }
        var isDirectory: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
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
        return "AVM can't find the folder that holds \(name), at \(storageFolderPath ?? "its saved location"). Next: if it's on an external drive, connect the drive, then try again."
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
        case .macOS: return "macOS"
        }
    }

    /// Ubuntu, Debian or Fedora: AVM's Linux install and run path (account,
    /// Orca, install markers, stall watch).
    var isLinux: Bool { self == .ubuntu || self == .debian || self == .fedora }
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
