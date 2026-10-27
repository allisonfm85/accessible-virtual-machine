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

    /// Host path exposed to the guest via VirtFS / WebDAV.
    var sharedFolderPath: String?

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
        guestOSName: String? = nil
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
    }
}

// MARK: - Guest operating system

/// The operating systems AVM installs. Raw values are the words
/// guestOSName stores.
enum GuestOS: String {
    case windows
    case ubuntu

    /// The name AVM says and shows for the running guest: "Enter Ubuntu",
    /// "Ubuntu keyboard on", "Send the keyboard to Ubuntu?".
    var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .ubuntu: return "Ubuntu"
        }
    }
}

extension VMConfiguration {
    var guestOS: GuestOS {
        guestOSName.flatMap(GuestOS.init(rawValue:)) ?? .windows
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
// MARK: - QEMU option values (2026-10-25)

/// A value for a comma-separated QEMU option: QEMU reads a comma as the
/// start of the next option and escapes a literal one by doubling it.
/// Used by VMManager.qemuOptionValue for every file path it passes.
nonisolated enum QEMUOption {
    static func value(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }
}

