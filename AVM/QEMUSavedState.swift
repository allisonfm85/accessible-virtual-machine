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

    /// Saved, or waiting to resume a restore point with open apps
    /// (2026-10-28, fifth audit): either way the disk is mid-session.
    static func looksSavedOrWaiting(_ configuration: VMConfiguration) -> Bool {
        if looksSaved(configuration) { return true }
        guard let dir = try? configuration.directoryURL() else { return false }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(resumeFile).path)
    }

    /// The saved state is there but can't be read (fifth audit).
    struct Unreadable: Error {}

    /// The disk's snapshot names, read while QEMU isn't running; nil when
    /// they couldn't be read (2026-10-28, fourth audit: a failed qemu-img
    /// read as "no snapshots", and the hint and marker were dropped while
    /// the saved state stayed on the disk, to be loaded over newer work).
    static func snapshotTags(disk: URL) async -> [String]? {
        guard let output = try? await RestorePoints.qemuImg(["info", "--output=json", "-U", disk.path]),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        return (json["snapshots"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// What this Start carries on from, if anything. A saved state left
    /// behind by a load whose delete failed is deleted here instead; a
    /// saved state wins over a restore note (it's newer: saving needs the
    /// machine running, after any restore).
    static func plan(configuration: VMConfiguration, runtimeDir: URL) async throws -> Plan? {
        let fm = FileManager.default
        let disk = URL(fileURLWithPath: configuration.diskImagePath)
        let marker = runtimeDir.appendingPathComponent(loadedMarker)
        guard let tags = await snapshotTags(disk: disk) else {
            AVMLog.write("AVM: SavedState — the disk's snapshots couldn't be read; nothing is loaded or deleted at this Start.")
            // With a saved state waiting, the Start stops here (2026-10-28,
            // fifth audit): booted fresh, the next Start loaded the old
            // state over that session's work.
            if fm.fileExists(atPath: hint(in: runtimeDir).path) { throw Unreadable() }
            return nil
        }
        let resume = runtimeDir.appendingPathComponent(resumeFile)
        if tags.contains(tag) {
            if fm.fileExists(atPath: marker.path) {
                AVMLog.write("AVM: SavedState — a saved state already carried on once is still on the disk; deleting it, not loading it.")
                // Said (2026-10-28, fifth audit): after QEMU died during the
                // load, the list still said Saved, and this Start dropped the
                // session without a word.
                await MainActor.run {
                    Announcer.shared.announce("\(configuration.name)'s saved session couldn't be carried on last time, so it starts fresh. Anything that wasn't saved in its apps then is lost.", tone: .info)
                }
                _ = try? await RestorePoints.qemuImg(["snapshot", "-d", tag, disk.path])
                // The marker goes only once the saved state has (2026-10-28,
                // code review): otherwise the Start after next loads it.
                if await snapshotTags(disk: disk)?.contains(tag) != false {
                    AVMLog.write("AVM: SavedState — the stale saved state couldn't be deleted; keeping the marker so it's never loaded.")
                } else {
                    try? fm.removeItem(at: marker)
                }
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
        if await snapshotTags(disk: disk)?.contains(tag) != false {
            _ = try? await RestorePoints.qemuImg(["snapshot", "-d", tag, disk.path])
        }
        // The hint and marker go only once the saved state has
        // (2026-10-28, fourth audit).
        guard await snapshotTags(disk: disk)?.contains(tag) == false else {
            AVMLog.write("AVM: SavedState — couldn't confirm the saved state was deleted; keeping its hint and marker.")
            return
        }
        AVMLog.write("AVM: SavedState — discarded.")
        try? FileManager.default.removeItem(at: hint(in: dir))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(loadedMarker))
    }
}

