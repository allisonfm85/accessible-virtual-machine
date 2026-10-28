// VMStore.swift
// AVM — Accessible Virtual Machine

import Foundation
import Combine

// MARK: - Orphaned VM directory (2026-08-15, Reclaim Disk Space)

/// One leftover directory in VMs/ with no matching configuration entry —
/// the debris the pre-fix delete (issue #5) left behind. Everything the
/// Reclaim sheet's row needs: identity, size, and a recognition date.
struct OrphanedVMDirectory: Identifiable, Hashable {
    /// The directory's name, which is its UUID string.
    let uuidString: String
    /// Allocated size in bytes of the whole directory.
    let sizeBytes: UInt64
    /// The directory's modification date — the row's recognition handle
    /// ("from July 12, 2026" tells the user which deletion this was).
    let modificationDate: Date?

    var id: String { uuidString }
}

final class VMStore: ObservableObject {

    // MARK: - Published State

    @Published private(set) var configurations: [VMConfiguration] = []

    /// The one VMStore, for code outside the windows. The USB hot-plug
    /// watcher reads the SAVED configuration here at every plug-in,
    /// never a copy taken when the VM started, so USB changes made in
    /// Settings apply right away. Weak, like VMManager.shared: the app
    /// owns the store, and this reference never keeps it alive.
    static weak var shared: VMStore?

    // MARK: - Private Properties

    private let fileManager = FileManager.default

    /// The AVM root under Application Support. Every piece of on-disk
    /// storage layout knowledge in the app lives in this file: the
    /// configurations store, and (2026-08-15) the per-VM directories.
    private var avmDirectory: URL {
        get throws {
            // Through AVMPaths (2026-10-26), so the accessibility audit's
            // stand-in folder applies here too.
            let avmDirectory = try AVMPaths.supportDirectory()
            try fileManager.createDirectory(
                at: avmDirectory,
                withIntermediateDirectories: true
            )
            return avmDirectory
        }
    }

    private var storeURL: URL {
        get throws {
            try avmDirectory.appendingPathComponent("configurations.json")
        }
    }

    /// The VMs/ container directory itself.
    private var vmsContainerURL: URL {
        get throws {
            try avmDirectory.appendingPathComponent("VMs")
        }
    }

    // MARK: - Per-VM directory layout (2026-08-15, issue #5)

    /// The directory that holds every file belonging to one VM:
    /// disk.qcow2, install ISO staging, autounattend.img, nvram.fd,
    /// tpm-state, logs, and anything the pipeline adds later.
    ///
    /// DESIGN DECISION OF RECORD: this URL is computed from the UUID and
    /// the same Application Support lookup used for the store — NEVER
    /// derived from configuration.diskImagePath. The stored path string
    /// happens to spell the directory "vms" (lowercase) while the real
    /// directory is "VMs"; that only works because the filesystem is
    /// case-insensitive. The UUID-based computation is deterministic and
    /// immune to whatever the stored string says.
    ///
    /// installISOPath and sharedFolderPath are deliberately NOT part of
    /// this layout: they point at the user's own files (e.g. an ISO in
    /// ~/Downloads) and deletion must never touch them.
    ///
    /// STORAGE LOCATION (2026-10-25): a VM the user stored in a folder of
    /// their choosing (an external drive) lives in that folder instead,
    /// recorded in storageFolderPath. The rule above still holds: the
    /// folder comes from that dedicated setting or the UUID, never from
    /// diskImagePath. VMConfiguration.directoryURL() is the one place it is
    /// worked out.
    func vmDirectoryURL(for configuration: VMConfiguration) throws -> URL {
        try configuration.directoryURL()
    }

    /// Total allocated size in bytes of the VM's directory, for the
    /// delete confirmation dialog ("about 72 gigabytes"). Returns nil if
    /// the directory does not exist — the already-orphaned-entry case —
    /// so the caller can word the dialog honestly.
    func vmDirectorySizeBytes(for configuration: VMConfiguration) -> UInt64? {
        guard
            let url = try? vmDirectoryURL(for: configuration),
            fileManager.fileExists(atPath: url.path)
        else { return nil }
        return allocatedSizeBytes(of: url)
    }

    /// Shared size enumerator for the delete dialog and the Reclaim scan:
    /// allocated size of every regular file under the given directory.
    private func allocatedSizeBytes(of url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .isRegularFileKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { continue }
            let bytes = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 0
            total += UInt64(bytes)
        }
        return total
    }

    // MARK: - Reclaim Disk Space (2026-08-15, design of record)

    /// Scans VMs/ for orphaned directories. THE DEFINITION (decision of
    /// record): a directory whose name parses as a UUID and matches no
    /// entry in configurations. Non-UUID names (Finder droppings, manual
    /// creations) are INVISIBLE to this feature — we only claim to clean
    /// up what AVM itself creates, and AVM only creates UUID-named
    /// directories.
    ///
    /// The scan is fresh on every call — never cached, never run at
    /// launch. The Reclaim menu item is the sole trigger.
    ///
    /// Sorted largest first: in a space-reclaiming list, the biggest win
    /// leads.
    func findOrphans() -> [OrphanedVMDirectory] {
        // Every folder would look orphaned (see loadAll).
        guard !loadFailed else { return [] }
        guard
            let container = try? vmsContainerURL,
            fileManager.fileExists(atPath: container.path)
        else { return [] }

        let registered = Set(configurations.map { $0.id.uuidString.uppercased() })

        guard let entries = try? fileManager.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return [] }

        var orphans: [OrphanedVMDirectory] = []
        for entry in entries {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
            guard values?.isDirectory == true else { continue }

            let name = entry.lastPathComponent
            // UUID-only scope (decision of record): a name that does not
            // parse as a UUID is not ours to touch.
            guard let uuid = UUID(uuidString: name) else { continue }
            guard !registered.contains(uuid.uuidString.uppercased()) else { continue }

            orphans.append(OrphanedVMDirectory(
                uuidString: name,
                sizeBytes: allocatedSizeBytes(of: entry),
                modificationDate: values?.contentModificationDate
            ))
        }

        return orphans.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Moves one orphaned directory to the Trash. Throws on failure so
    /// the caller can announce it.
    ///
    /// DEFENSE IN DEPTH: re-checks at trash time that the UUID is not a
    /// registered configuration — the orphan list could be stale if a
    /// configuration was created while the Reclaim sheet sat open. A
    /// refused trash throws, so it is never silent.
    func trashOrphan(_ orphan: OrphanedVMDirectory) throws {
        let registered = Set(configurations.map { $0.id.uuidString.uppercased() })
        if let uuid = UUID(uuidString: orphan.uuidString),
           registered.contains(uuid.uuidString.uppercased()) {
            AVMLog.write("AVM: VMStore — Reclaim REFUSED for \(orphan.uuidString): it is now a registered VM.")
            throw NSError(
                domain: "AVM.Reclaim",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "This folder now belongs to a virtual machine in your list and was not moved."]
            )
        }

        let url = try vmsContainerURL.appendingPathComponent(orphan.uuidString)
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        AVMLog.write("AVM: VMStore — Reclaim moved orphan \(orphan.uuidString) to Trash (\(orphan.sizeBytes) bytes).")
    }

    // MARK: - Init

    init() {
        configurations = loadAll()
        VMStore.shared = self
    }

    // MARK: - Load

    // STAGE C (2026-08-03): the two failure lines in this file were promoted
    // from print() — which goes to stdout, i.e. NOWHERE for a launched app —
    // to the file log. These are the persistence layer failing: a tester
    // whose VM list comes up empty, or whose new VM vanishes after a
    // relaunch, is diagnosed by exactly these lines, and until this change
    // they were invisible in every log AVM has.
    //
    // SAVE FAILURE IS SPOKEN (2026-10-25, closes the banked question): a
    // save failure is silent data loss — the in-memory list looks right and
    // the truth only surfaces at next launch. Under "silence is never
    // neutral" saveAll now speaks a .failure as well as logging it. A LOAD
    // failure stays log-only: it happens at launch, before anything could
    // be said usefully, and an empty list is already visible.
    //
    // AN UNREADABLE LIST IS KEPT, NEVER OVERWRITTEN (2026-10-26, code
    // audit): loading used to fall back to an empty list, and the next save
    // (any new machine or setting) wrote that over the file, losing every
    // machine, while Reclaim then offered all their folders for the Trash.
    // Now the file is copied aside first, Reclaim refuses while the list
    // couldn't be read, and the user hears what happened and where the
    // copy is.
    private(set) var loadFailed = false

    private func loadAll() -> [VMConfiguration] {
        do {
            let url = try storeURL
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([VMConfiguration].self, from: data)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to load configurations: \(error.localizedDescription)")
            loadFailed = true
            var kept = "it couldn't be copied aside"
            if let url = try? storeURL, fileManager.fileExists(atPath: url.path) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let aside = url.deletingLastPathComponent().appendingPathComponent("configurations-unreadable-\(stamp).json")
                if (try? fileManager.copyItem(at: url, to: aside)) != nil {
                    kept = "a copy is kept as \(aside.lastPathComponent), in AVM's folder in Application Support"
                    AVMLog.write("AVM: VMStore — the unreadable list is kept as \(aside.lastPathComponent).")
                }
            }
            let message = "AVM couldn't read your list of virtual machines, so it shows none; \(kept). Your machines' files are untouched. Next: report the problem from the Help menu, before making new machines."
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated { Announcer.shared.announce(message, tone: .failure) }
            }
            return []
        }
    }

    // MARK: - Save All

    private func saveAll() {
        do {
            let url = try storeURL
            let data = try JSONEncoder().encode(configurations)
            try data.write(to: url, options: .atomic)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to save configurations: \(error.localizedDescription)")
            let reason = error.localizedDescription
            Task { @MainActor in
                Announcer.shared.announce(
                    "AVM could not save your virtual machine list. Your last change will be lost when AVM quits. Reason: \(reason) Next: make sure your Mac has free disk space, then make the change again.",
                    tone: .failure
                )
            }
        }
    }

    // MARK: - Add or Update

    func save(_ configuration: VMConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == configuration.id }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }
        saveAll()
    }

    // MARK: - Secure Boot switch (2026-10-25)

    /// Switches which firmware's variable store the VM uses. Each firmware
    /// keeps its own: the current nvram.fd is set aside as
    /// nvram-plain.fd or nvram-secure.fd, and the other firmware's earlier
    /// store, if there is one, comes back. A first switch to Secure Boot
    /// leaves no nvram.fd, so the next start makes one with Microsoft's
    /// keys (VMManager.prepareSecureBootNVRAM). Switching back puts the
    /// old store, and the boot entries Windows wrote to it, back exactly.
    /// Files are moved, never deleted. Throws, for a spoken failure, with
    /// nothing changed if the first move fails.
    func switchSecureBoot(_ configuration: VMConfiguration, on: Bool) throws {
        if configuration.storageIsMissing {
            throw NSError(domain: "AVM.SecureBoot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: configuration.storageMissingMessage])
        }
        let dir = try vmDirectoryURL(for: configuration)
        let current = dir.appendingPathComponent("nvram.fd")
        let setAside = dir.appendingPathComponent(on ? "nvram-plain.fd" : "nvram-secure.fd")
        let comingBack = dir.appendingPathComponent(on ? "nvram-secure.fd" : "nvram-plain.fd")
        if fileManager.fileExists(atPath: current.path) {
            // An older set-aside store is renamed, never deleted (2026-10-25,
            // code audit): after a half-finished switch it may be the only
            // copy with Windows' boot entries.
            if fileManager.fileExists(atPath: setAside.path) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let older = dir.appendingPathComponent("\(setAside.deletingPathExtension().lastPathComponent)-\(stamp).fd")
                try fileManager.moveItem(at: setAside, to: older)
            }
            try fileManager.moveItem(at: current, to: setAside)
        }
        if fileManager.fileExists(atPath: comingBack.path) {
            try fileManager.moveItem(at: comingBack, to: current)
        }
        AVMLog.write("AVM: VMStore — Secure Boot \(on ? "on" : "off") for '\(configuration.name)'; firmware settings switched.")
    }

    // MARK: - Delete

    /// The install pipelines' scratch folder for this VM, removed with it
    /// (2026-10-25, code audit). A build cut short by a quit or crash left
    /// up to 15 GB there, and for Ubuntu a copy of the password hash, and
    /// nothing else ever cleared it. AVM's own working files, so removed
    /// outright rather than trashed.
    private func removeScratch(for configuration: VMConfiguration) {
        guard let scratch = try? avmDirectory
            .appendingPathComponent("scratch")
            .appendingPathComponent(configuration.id.uuidString) else { return }
        if fileManager.fileExists(atPath: scratch.path) {
            try? fileManager.removeItem(at: scratch)
            AVMLog.write("AVM: VMStore — removed install scratch for '\(configuration.name)'.")
        }
    }

    /// Removes ONLY the configuration entry. This was the entire delete
    /// implementation until 2026-08-15 — which is exactly issue #5: the
    /// entry vanished from the list while the full VM directory (tens of
    /// gigabytes) stayed on disk, invisible to the app. It remains as the
    /// final step of deleteMovingFilesToTrash and must not be called
    /// directly by UI code.
    func delete(_ configuration: VMConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        saveAll()
    }

    /// Full delete (2026-08-15, issue #5): moves the VM's directory to
    /// the Trash, THEN removes the configuration entry. Returns the
    /// number of bytes moved to the Trash (0 if the directory did not
    /// exist — the orphaned-entry case, where removing the entry is the
    /// whole job).
    ///
    /// ORDERING IS DELIBERATE: files first, entry second. If the Trash
    /// move throws, the entry is KEPT and the error propagates to the
    /// caller for a spoken .failure announcement — the one state this
    /// method must never produce is "entry gone, files stranded and now
    /// invisible in the app", which is the very bug it fixes.
    ///
    /// A VM whose drive isn't connected is refused (2026-10-25): its folder
    /// is missing only because the drive is, and "no directory on disk"
    /// would otherwise remove the entry and strand the files on the drive,
    /// invisible to AVM, which is issue #5 again.
    @discardableResult
    func deleteMovingFilesToTrash(_ configuration: VMConfiguration) throws -> UInt64 {
        if configuration.storageIsMissing {
            AVMLog.write("AVM: VMStore — delete of '\(configuration.name)' refused: its storage folder is missing (drive not connected?). Entry kept.")
            throw NSError(
                domain: "AVM.Delete",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: configuration.storageMissingMessage]
            )
        }
        let url = try vmDirectoryURL(for: configuration)

        guard fileManager.fileExists(atPath: url.path) else {
            AVMLog.write("AVM: VMStore — delete of '\(configuration.name)': no VM directory on disk (orphaned entry); removing entry only.")
            removeScratch(for: configuration)
            delete(configuration)
            return 0
        }

        let bytes = vmDirectorySizeBytes(for: configuration) ?? 0

        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to move VM directory to Trash for '\(configuration.name)': \(error.localizedDescription). Entry kept.")
            throw error
        }

        AVMLog.write("AVM: VMStore — moved VM directory to Trash for '\(configuration.name)' (\(bytes) bytes).")
        removeScratch(for: configuration)
        delete(configuration)
        return bytes
    }
}

// MARK: - Restore points (2026-10-25)

/// One restore point: a qcow2 snapshot of the VM's disk, tagged
/// "avm-<milliseconds>", and a folder of the same name under
/// restore-points/ holding a copy of nvram.fd, of tpm-state, the user's
/// label, and whether Secure Boot was on. The disk snapshot lives inside
/// disk.qcow2 and costs nothing at first; the file grows as the disk
/// changes afterwards, by about what changed.
nonisolated struct RestorePoint: Identifiable, Hashable, Sendable {
    let tag: String
    let label: String
    let date: Date
    let secureBoot: Bool
    /// Taken while the machine ran (2026-10-27): its memory is in the
    /// snapshot too, and restoring it carries on with open apps.
    var withMemory = false
    /// The disk bus the machine was on (2026-10-28): "nvme" or "virtio";
    /// nil for a point made before this was recorded. A machine moved to
    /// the virtio disk since can't boot a point from before the move, so
    /// a restore puts the bus back too (SettingsView).
    var diskBus: String? = nil
    var id: String { tag }
}

nonisolated enum RestorePointError: LocalizedError, Sendable {
    case tool(String)
    case secureBootMismatch(madeWithSecureBoot: Bool)

    var errorDescription: String? {
        switch self {
        case .tool(let detail):
            return detail
        case .secureBootMismatch(let on):
            return on
                ? "This restore point was made with Secure Boot on. Next: turn Secure Boot on in Settings, then restore it."
                : "This restore point was made with Secure Boot off. Next: turn Secure Boot off in Settings, then restore it."
        }
    }
}

/// Restore points for a stopped VM (2026-10-25). Only ever while the VM is
/// stopped: QEMU holds the disk while it runs, and a snapshot of a running
/// guest's disk alone would not match its memory. The qemu-img work runs
/// off the main thread.
nonisolated enum RestorePoints {
    static let folderName = "restore-points"

    static func list(vmDirectory dir: URL) async throws -> [RestorePoint] {
        let output = try await qemuImg(["info", "--output=json", disk(dir).path])
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw RestorePointError.tool("AVM couldn't read the disk's restore points.")
        }
        let snapshots = json["snapshots"] as? [[String: Any]] ?? []
        return snapshots.compactMap { snap -> RestorePoint? in
            guard let tag = snap["name"] as? String, tag.hasPrefix("avm-") else { return nil }
            let seconds = snap["date-sec"] as? Double ?? 0
            let folder = dir.appendingPathComponent(folderName).appendingPathComponent(tag)
            let label = (try? String(contentsOf: folder.appendingPathComponent("label.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let secure = FileManager.default.fileExists(atPath: folder.appendingPathComponent("secure-boot").path)
            let memory = (snap["vm-state-size"] as? Double ?? 0) > 0
            let bus = (try? String(contentsOf: folder.appendingPathComponent("disk-bus"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RestorePoint(tag: tag, label: (label?.isEmpty == false ? label! : "Restore point"),
                                date: Date(timeIntervalSince1970: seconds), secureBoot: secure, withMemory: memory,
                                diskBus: bus?.isEmpty == false ? bus : nil)
        }
        .sorted { $0.date > $1.date }
    }

    static func create(vmDirectory dir: URL, label: String, secureBoot: Bool, diskBus: String? = nil) async throws -> RestorePoint {
        let tag = newTag()
        _ = try await qemuImg(["snapshot", "-c", tag, disk(dir).path])
        do {
            try writeFolder(vmDirectory: dir, tag: tag, label: label, secureBoot: secureBoot, diskBus: diskBus)
        } catch {
            // Half a restore point is worse than none: take the snapshot back.
            _ = try? await qemuImg(["snapshot", "-d", tag, disk(dir).path])
            throw error
        }
        AVMLog.write("AVM: RestorePoints — created \(tag).")
        return RestorePoint(tag: tag, label: label, date: Date(), secureBoot: secureBoot, diskBus: diskBus)
    }

    static func newTag() -> String { "avm-\(Int(Date().timeIntervalSince1970 * 1000))" }

    /// The restore point's folder: copies of the firmware settings and the
    /// TPM, its label, and whether Secure Boot was on. A folder that
    /// couldn't be finished is removed, and that's thrown.
    static func writeFolder(vmDirectory dir: URL, tag: String, label: String, secureBoot: Bool, diskBus: String? = nil) throws {
        let fm = FileManager.default
        let folder = dir.appendingPathComponent(folderName).appendingPathComponent(tag)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let nvram = dir.appendingPathComponent("nvram.fd")
            if fm.fileExists(atPath: nvram.path) {
                try fm.copyItem(at: nvram, to: folder.appendingPathComponent("nvram.fd"))
            }
            let tpm = dir.appendingPathComponent("tpm-state")
            if fm.fileExists(atPath: tpm.path) {
                try fm.copyItem(at: tpm, to: folder.appendingPathComponent("tpm-state"))
            }
            try label.write(to: folder.appendingPathComponent("label.txt"), atomically: true, encoding: .utf8)
            if secureBoot {
                fm.createFile(atPath: folder.appendingPathComponent("secure-boot").path, contents: nil)
            }
            if let diskBus {
                try diskBus.write(to: folder.appendingPathComponent("disk-bus"), atomically: true, encoding: .utf8)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw RestorePointError.tool("The restore point could not be saved: \(error.localizedDescription)")
        }
    }

    static func removeFolder(vmDirectory dir: URL, tag: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(folderName).appendingPathComponent(tag))
    }

    /// Puts the disk, firmware settings and TPM back as they were. The
    /// current firmware settings and TPM state are kept beside the restore
    /// point's copies until the restore has worked, then replaced.
    static func restore(_ point: RestorePoint, vmDirectory dir: URL, currentSecureBoot: Bool) async throws {
        guard point.secureBoot == currentSecureBoot else {
            throw RestorePointError.secureBootMismatch(madeWithSecureBoot: point.secureBoot)
        }
        // ORDER (2026-10-26, code audit): this used to delete the live
        // firmware settings and TPM, then copy the saved ones, after the
        // disk was already rolled back; a failed copy (a full disk) left a
        // rolled-back Windows with a new TPM, so BitLocker asked for its
        // recovery key and Windows Hello PINs were gone. Now the saved
        // copies are staged beside the live ones first; only once both are
        // in hand is the disk rolled back and are they swapped in. A part
        // the point has no copy of is left as it is.
        let fm = FileManager.default
        let folder = dir.appendingPathComponent(folderName).appendingPathComponent(point.tag)
        var staged: [(live: URL, fresh: URL)] = []
        do {
            for name in ["nvram.fd", "tpm-state"] {
                let saved = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: saved.path) else { continue }
                let fresh = dir.appendingPathComponent(".\(name).restoring")
                try? fm.removeItem(at: fresh)
                try fm.copyItem(at: saved, to: fresh)
                staged.append((dir.appendingPathComponent(name), fresh))
            }
        } catch {
            for item in staged { try? fm.removeItem(at: item.fresh) }
            throw RestorePointError.tool("The restore point's firmware settings couldn't be copied, so nothing was changed: \(error.localizedDescription)")
        }
        _ = try await qemuImg(["snapshot", "-a", point.tag, disk(dir).path])
        // With memory (2026-10-27): the next Start loads it and carries on
        // from that moment (QEMUSavedState.resumeTag). Without, any note
        // left by an earlier restore goes.
        let resume = dir.appendingPathComponent(QEMUSavedState.resumeFile)
        if point.withMemory {
            try point.tag.write(to: resume, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: resume)
        }
        for item in staged {
            if fm.fileExists(atPath: item.live.path) {
                _ = try fm.replaceItemAt(item.live, withItemAt: item.fresh)
            } else {
                try fm.moveItem(at: item.fresh, to: item.live)
            }
        }
        AVMLog.write("AVM: RestorePoints — restored \(point.tag).")
    }

    /// The disk's size in gigabytes (GiB, as qemu-img's "G" makes them).
    /// A restore point made before the disk grew puts the old size back.
    static func diskSizeGB(vmDirectory dir: URL) async throws -> Int {
        let output = try await qemuImg(["info", "--output=json", disk(dir).path])
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        let bytes = (json?["virtual-size"] as? Double) ?? 0
        return Int((bytes / 1_073_741_824).rounded())
    }

    static func delete(_ point: RestorePoint, vmDirectory dir: URL) async throws {
        _ = try await qemuImg(["snapshot", "-d", point.tag, disk(dir).path])
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(folderName).appendingPathComponent(point.tag))
        AVMLog.write("AVM: RestorePoints — deleted \(point.tag).")
    }

    private static func disk(_ dir: URL) -> URL {
        dir.appendingPathComponent("disk.qcow2")
    }

    /// Runs the bundled qemu-img off the main thread; stdout on success,
    /// a spoken-ready error with qemu-img's own words on failure.
    static func qemuImg(_ arguments: [String]) async throws -> String {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("qemu-img"),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw RestorePointError.tool("qemu-img is missing from AVM, so restore points can't be used.")
        }
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw RestorePointError.tool("qemu-img said: \(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)")
            }
            return String(decoding: outData, as: UTF8.self)
        }.value
    }
}
