// MacGuestFiles.swift
// AVM — Accessible Virtual Machine
//
// A macOS machine's files and restore points (2026-10-26), apart from
// MacGuest.swift so the tests can reach them without Virtualization.

import Foundation

// MARK: - Files

nonisolated struct MacGuestFiles {
    let folder: URL
    var disk: URL { folder.appendingPathComponent("macos-disk.img") }
    var auxiliaryStorage: URL { folder.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModel: URL { folder.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { folder.appendingPathComponent("MachineIdentifier") }
    /// The machine's network card's address, kept so it's the same at every
    /// start: a saved machine resumes only on the configuration it was saved
    /// with (2026-10-26), and macOS sees the same network card throughout.
    var macAddress: URL { folder.appendingPathComponent("MACAddress") }
    /// A running machine saved to disk (MacGuestRunner.saveAndStop), to be
    /// resumed at the next Start.
    var savedState: URL { folder.appendingPathComponent("SavedState.vzvmsave") }
    var restorePoints: URL { folder.appendingPathComponent("restore-points", isDirectory: true) }

    var isInstalled: Bool {
        [disk, auxiliaryStorage, hardwareModel, machineIdentifier].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

nonisolated struct MacGuestError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Restore points (2026-10-26)

/// A macOS machine's restore points: copies of its disk and auxiliary
/// storage made with APFS clones (clonefile), so taking one is instant and
/// costs only the space that changes afterwards. Taken and used only while
/// the machine is shut down, so the disk is never copied mid-write.
nonisolated struct MacRestorePoint: Identifiable, Sendable {
    let folder: URL
    let name: String
    let date: Date
    var id: String { folder.lastPathComponent }
}

nonisolated enum MacRestorePoints {
    static func list(_ files: MacGuestFiles) -> [MacRestorePoint] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: files.restorePoints, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("point.json")),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = info["name"] as? String,
                  let seconds = info["date"] as? Double else { return nil }
            return MacRestorePoint(folder: folder, name: name, date: Date(timeIntervalSince1970: seconds))
        }.sorted { $0.date > $1.date }
    }

    static func take(_ files: MacGuestFiles, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: files.restorePoints, withIntermediateDirectories: true)
        let folder = files.restorePoints.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            try clone(files.disk, to: folder.appendingPathComponent(files.disk.lastPathComponent))
            try clone(files.auxiliaryStorage, to: folder.appendingPathComponent(files.auxiliaryStorage.lastPathComponent))
            let info: [String: Any] = ["name": name, "date": Date().timeIntervalSince1970]
            try JSONSerialization.data(withJSONObject: info).write(to: folder.appendingPathComponent("point.json"))
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// The machine back as it was at `point`. Any saved running state goes:
    /// it belongs to the disk being replaced.
    static func restore(_ point: MacRestorePoint, into files: MacGuestFiles) throws {
        let fm = FileManager.default
        for (live, name) in [(files.disk, files.disk.lastPathComponent), (files.auxiliaryStorage, files.auxiliaryStorage.lastPathComponent)] {
            let fresh = live.deletingLastPathComponent().appendingPathComponent(".\(name).restoring")
            try? fm.removeItem(at: fresh)
            try clone(point.folder.appendingPathComponent(name), to: fresh)
            _ = try fm.replaceItemAt(live, withItemAt: fresh)
        }
        try? fm.removeItem(at: files.savedState)
    }

    static func delete(_ point: MacRestorePoint) throws {
        try FileManager.default.removeItem(at: point.folder)
    }

    private static func clone(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            let code = errno
            throw MacGuestError(code == ENOTSUP
                ? "Restore points need the machine on an APFS disk, where copies are instant."
                : "Couldn't copy \(source.lastPathComponent): \(String(cString: strerror(code))).")
        }
    }
}

