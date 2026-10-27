// WindowsReinstall.swift
// AVM — Accessible Virtual Machine
//
// Reinstall Windows (2026-10-26): erase a stopped Windows machine and set
// it up to install again, from the same ISO with the same setup answers,
// at its next Start. Settings asks first, and asks again for a local
// account's password, which AVM forgot once the first install media was
// built (WindowsSetupAnswers.swift).
//
// What goes: the disk (with its restore points), the firmware settings,
// the TPM, the install media AVM built and the UNATTEND volume with its
// install-complete marker, so the next Start runs Setup as the first one
// did. What stays: the machine's settings, its setup answers, and the
// user's own ISO, which must still be where it was.
//
// The new, empty disk is made BEFORE anything is deleted, beside the old
// one, so a failure part way never leaves a machine with no disk.

import Foundation

nonisolated enum WindowsReinstallError: LocalizedError, Sendable {
    case installerMissing(String)
    case passwordNeeded
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .installerMissing(let path):
            return "The Windows installer this machine was made from isn't at \((path as NSString).abbreviatingWithTildeInPath) any more. Next: put it back there, then reinstall."
        case .passwordNeeded:
            return "AVM needs the Windows account's password again to reinstall."
        case .failed(let detail):
            return detail
        }
    }
}

@MainActor
enum WindowsReinstall {

    /// True when the machine's Windows account is a local one, so the
    /// password must be asked for again.
    static func needsPassword(_ configuration: VMConfiguration) -> Bool {
        guard let dir = try? configuration.directoryURL() else { return false }
        return WindowsSetupAnswers.load(fromVMDirectory: dir)?.localAccount != nil
    }

    static func localUserName(_ configuration: VMConfiguration) -> String? {
        guard let dir = try? configuration.directoryURL() else { return nil }
        return WindowsSetupAnswers.load(fromVMDirectory: dir)?.localAccount?.userName
    }

    /// Prepares the machine; the next Start installs Windows. The VM must
    /// be stopped (Settings only offers this then).
    static func prepare(_ configuration: VMConfiguration, password: String?) async throws {
        let fm = FileManager.default
        guard let iso = configuration.installISOPath, !iso.isEmpty, fm.fileExists(atPath: iso) else {
            throw WindowsReinstallError.installerMissing(configuration.installISOPath ?? "")
        }
        let dir = try configuration.directoryURL()

        // The answers, with the password again for a local account.
        var answers = WindowsSetupAnswers.load(fromVMDirectory: dir)
        if answers?.localAccount != nil {
            guard let password else { throw WindowsReinstallError.passwordNeeded }
            answers?.localAccount?.encodedPassword = WindowsSetupAnswers.encode(password: password)
        }

        // A new, empty disk first, beside the old one.
        let disk = URL(fileURLWithPath: configuration.diskImagePath)
        let fresh = disk.deletingLastPathComponent().appendingPathComponent("disk-reinstall.qcow2")
        try? fm.removeItem(at: fresh)
        do {
            try await VMManager().createDiskImage(at: fresh.path, sizeGB: configuration.diskSizeGB)
        } catch {
            throw WindowsReinstallError.failed("AVM couldn't make a new disk, so nothing was changed. Reason: \(error.localizedDescription)")
        }

        // Then everything of the old Windows.
        for name in ["install-avm.iso", "autounattend.img", "nvram.fd", "tpm-state", RestorePoints.folderName, "firmware-serial.log"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        do {
            if fm.fileExists(atPath: disk.path) {
                _ = try fm.replaceItemAt(disk, withItemAt: fresh)
            } else {
                try fm.moveItem(at: fresh, to: disk)
            }
        } catch {
            throw WindowsReinstallError.failed("AVM couldn't put the new disk in place. Reason: \(error.localizedDescription) Next: reinstall again.")
        }
        try answers?.save(inVMDirectory: dir)
        AVMLog.write("AVM: Reinstall — \(configuration.name) is ready to install Windows again at its next start.")
    }
}
