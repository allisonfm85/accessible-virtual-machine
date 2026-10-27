// QEMUSavedState.swift
// AVM — Accessible Virtual Machine

import Foundation

/// A Windows or Linux machine saved as it is, open apps and all, and
/// carried on from there at its next Start, as Hyper-V's Save and VMware's
/// Suspend do. QEMU writes the machine's memory into a snapshot inside
/// disk.qcow2 named `tag`, alongside the disk as it was at that moment
/// (snapshot-save), and quits; the next Start loads it with QEMU paused
/// (snapshot-load), lets it go, and deletes it.
///
/// MEASURED 2026-10-27 on Windows 11 with NVDA, Secure Boot and the TPM:
/// saved in 1 s (2 GB of memory in use), carried on in 2 s in a fresh
/// QEMU, same boot time, NVDA still running, speech at 103 ms. Needs the
/// virtio disk (VMConfiguration.diskBus): QEMU 10's NVMe refuses to be
/// saved. The firmware settings (raw nvram.fd) aren't in the snapshot,
/// which is why snapshot-save names the disk alone; they don't change
/// while a machine runs. The TPM's state rides in the memory.
///
/// An old saved state carried on over newer work would lose that work,
/// so `loadedMarker` is written before a load and removed once the saved
/// state is deleted: a marker found at Start means the delete never
/// happened, and the saved state is deleted then instead of loaded.
/// `hintFile` lets the machine list say "Saved" without asking qemu-img.
nonisolated enum QEMUSavedState {
    static let tag = "saved-state"
    static let loadedMarker = "saved-state.loaded"
    static let hintFile = "saved-state.txt"
    /// A restore point with memory, put back while the machine was
    /// stopped: its tag, for the next Start to load (RestorePoints.restore).
    static let resumeFile = "resume-from.txt"

    /// What a Start carries on from: the saved state (deleted once
    /// loaded) or a restore point with memory (kept).
    struct Plan: Sendable {
        let tag: String
        let isSavedState: Bool
    }

    static func hint(in dir: URL) -> URL { dir.appendingPathComponent(hintFile) }

    /// True if the machine's list row should say it's saved.
    static func looksSaved(_ configuration: VMConfiguration) -> Bool {
        guard let dir = try? configuration.directoryURL() else { return false }
        return FileManager.default.fileExists(atPath: hint(in: dir).path)
    }

    /// The disk's snapshot names, read while QEMU isn't running.
    static func snapshotTags(disk: URL) async -> [String] {
        guard let output = try? await RestorePoints.qemuImg(["info", "--output=json", "-U", disk.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return [] }
        return (json["snapshots"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// What this Start carries on from, if anything. A saved state left
    /// behind by a load whose delete failed is deleted here instead; a
    /// saved state wins over a restore note (it's newer: saving needs the
    /// machine running, after any restore).
    static func plan(configuration: VMConfiguration, runtimeDir: URL) async -> Plan? {
        let fm = FileManager.default
        let disk = URL(fileURLWithPath: configuration.diskImagePath)
        let tags = await snapshotTags(disk: disk)
        let marker = runtimeDir.appendingPathComponent(loadedMarker)
        let resume = runtimeDir.appendingPathComponent(resumeFile)
        if tags.contains(tag) {
            if fm.fileExists(atPath: marker.path) {
                AVMLog.write("AVM: SavedState — a saved state already carried on once is still on the disk; deleting it, not loading it.")
                _ = try? await RestorePoints.qemuImg(["snapshot", "-d", tag, disk.path])
                try? fm.removeItem(at: marker)
                try? fm.removeItem(at: hint(in: runtimeDir))
            } else {
                try? fm.removeItem(at: resume)
                return Plan(tag: tag, isSavedState: true)
            }
        } else {
            try? fm.removeItem(at: hint(in: runtimeDir))
            try? fm.removeItem(at: marker)
        }
        if let point = try? String(contentsOf: resume, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           tags.contains(point) {
            return Plan(tag: point, isSavedState: false)
        }
        try? fm.removeItem(at: resume)
        return nil
    }

    /// Deletes a saved state while the machine is stopped (a restore point
    /// put back, for one). Its machine then starts from its disk.
    static func discard(configuration: VMConfiguration) async {
        guard let dir = try? configuration.directoryURL() else { return }
        let disk = URL(fileURLWithPath: configuration.diskImagePath)
        if await snapshotTags(disk: disk).contains(tag) {
            _ = try? await RestorePoints.qemuImg(["snapshot", "-d", tag, disk.path])
            AVMLog.write("AVM: SavedState — discarded.")
        }
        try? FileManager.default.removeItem(at: hint(in: dir))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(loadedMarker))
    }
}

