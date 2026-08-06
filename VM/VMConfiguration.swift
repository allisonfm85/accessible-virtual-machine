// VMConfiguration.swift
// AVM — Accessible Virtual Machine

import Foundation

/// Persistent configuration for a single virtual machine.
/// Stored as JSON in Application Support/AVM/vms.json via VMStore.
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

    // MARK: - Defaults

    init(
        id: UUID = UUID(),
        name: String = "Windows 11",
        cpuCount: Int = 4,
        ramSizeGB: Int = 8,
        diskSizeGB: Int = 64,
        diskImagePath: String = "",
        installISOPath: String? = nil,
        sharedFolderPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuCount = cpuCount
        self.ramSizeGB = ramSizeGB
        self.diskSizeGB = diskSizeGB
        self.diskImagePath = diskImagePath
        self.installISOPath = installISOPath
        self.sharedFolderPath = sharedFolderPath
    }
}
