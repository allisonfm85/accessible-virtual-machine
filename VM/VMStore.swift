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

    // MARK: - Private Properties

    private let fileManager = FileManager.default

    /// The AVM root under Application Support. Every piece of on-disk
    /// storage layout knowledge in the app lives in this file: the
    /// configurations store, and (2026-08-15) the per-VM directories.
    private var avmDirectory: URL {
        get throws {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let avmDirectory = appSupport.appendingPathComponent("AVM")
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
    func vmDirectoryURL(for configuration: VMConfiguration) throws -> URL {
        try vmsContainerURL
            .appendingPathComponent(configuration.id.uuidString)
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
    }

    // MARK: - Load

    // STAGE C (2026-08-03): the two failure lines in this file were promoted
    // from print() — which goes to stdout, i.e. NOWHERE for a launched app —
    // to the file log. These are the persistence layer failing: a tester
    // whose VM list comes up empty, or whose new VM vanishes after a
    // relaunch, is diagnosed by exactly these lines, and until this change
    // they were invisible in every log AVM has.
    //
    // BANKED QUESTION (not changed here — behavior change, needs its own
    // decision and wording approval): a SAVE failure is silent data loss —
    // the in-memory list looks right and the truth only surfaces at next
    // launch. Under "silence is never neutral" it is a candidate for a
    // spoken .failure announcement, not just a log line. Queued for the
    // announcements work.
    private func loadAll() -> [VMConfiguration] {
        do {
            let url = try storeURL
            guard fileManager.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([VMConfiguration].self, from: data)
        } catch {
            AVMLog.write("AVM: VMStore — FAILED to load configurations: \(error.localizedDescription)")
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

    // MARK: - Delete

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
    @discardableResult
    func deleteMovingFilesToTrash(_ configuration: VMConfiguration) throws -> UInt64 {
        let url = try vmDirectoryURL(for: configuration)

        guard fileManager.fileExists(atPath: url.path) else {
            AVMLog.write("AVM: VMStore — delete of '\(configuration.name)': no VM directory on disk (orphaned entry); removing entry only.")
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
        delete(configuration)
        return bytes
    }
}
