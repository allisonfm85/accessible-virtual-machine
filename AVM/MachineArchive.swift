// MachineArchive.swift
// AVM — Accessible Virtual Machine
//
// Export and import of a whole virtual machine (2026-10-26), so a user can
// back a machine up to an external drive and bring it back, on this Mac or
// another. No AppKit here, so the tests reach all of it; the panels and the
// spoken progress are MachineArchivePanels.swift.
//
// THE PACKAGE: a folder named "<Name>.avmvm" holding the machine's own
// folder's files, as they are, plus avm-machine.json: the configuration
// (with no storage folder and no absolute disk path, since both belong to
// the Mac it came from) and the format's version. The manifest is written
// LAST, and the package is built under a hidden "-partial" name and renamed
// only when complete, so a package with a manifest is always a whole one.
//
// WHAT IS LEFT OUT, and why:
//   - secrets. ubuntu-account.json (the password hash) never goes, and
//     windows-setup.json goes with its encoded password removed, as
//     WindowsSetupAnswers.forgetPassword would leave it. A machine whose
//     install hasn't finished is refused instead (exportProblem): its
//     install disc and UNATTEND volume still carry the answers.
//   - what only means something while it runs: sockets, logs, screen
//     grabs, lock files, half-done restore files.
//   - SavedState.vzvmsave. Its validity is tied to this host. A machine
//     that is saved rather than shut down is refused, not stripped: its
//     disk is mid-session, and booting it without the saved memory is a
//     power cut.
//
// IMPORT gives the machine a NEW id, so importing twice, or back onto the
// Mac it came from, never collides with the original. A macOS machine
// keeps its MachineIdentifier: that is the machine's identity to macOS
// (and to Apple's services), and a new one would make it a different Mac.
// macOSIdentityTwins finds the machines that share it, so the panel can
// say so.
//
// COPYING: an APFS clone (clonefile) when the destination is on the same
// volume, which is instant and costs no space; otherwise a copy that skips
// holes and all-zero blocks, so a sparse raw macOS disk stays sparse on
// APFS and HFS+. On exFAT or FAT, which have no sparse files, the copy is
// the disk's full size, and the free-space check counts it that way.

import Foundation

// MARK: - Errors (spoken as written)

nonisolated struct MachineArchiveError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - The package

enum MachineArchive {
    nonisolated static let packageExtension = "avmvm"
    nonisolated static let manifestName = "avm-machine.json"
    /// Bumped only for a change an older AVM couldn't read correctly.
    static let formatVersion = 1

    struct Manifest: Codable {
        var format: Int
        var exportedAt: Date
        var appVersion: String?
        var configuration: VMConfiguration
    }

    /// "Windows 11.avmvm", with characters a folder name can't have
    /// replaced.
    static func packageName(for configuration: VMConfiguration) -> String {
        var base = configuration.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = "Virtual Machine" }
        return "\(base).\(packageExtension)"
    }

    // MARK: Export

    /// Why this machine can't be exported now, in words to speak; nil when
    /// it can. The caller has already refused a running machine.
    static func exportProblem(for configuration: VMConfiguration, vmDirectory dir: URL) -> String? {
        let fm = FileManager.default
        if configuration.storageIsMissing {
            return configuration.storageMissingMessage
        }
        guard fm.fileExists(atPath: dir.path) else {
            return "AVM can't find \(configuration.name)'s files, so there is nothing to export."
        }
        if configuration.guestOS == .macOS {
            let files = MacGuestFiles(folder: dir)
            guard files.isInstalled else {
                return "macOS isn't installed in \(configuration.name), so there is nothing to export yet."
            }
            if fm.fileExists(atPath: files.savedState.path) {
                return "\(configuration.name) is saved, not shut down. Next: start it, shut it down from macOS's Apple menu, then export it."
            }
            return nil
        }
        let disk = dir.appendingPathComponent(diskFileName(for: configuration))
        guard fm.fileExists(atPath: disk.path) else {
            return "\(configuration.name) has no disk in its folder, so there is nothing to export."
        }
        // An install in progress, or one that hasn't started: the answers
        // (and a password's encoding) are still on the install media, and
        // the copy couldn't finish installing anywhere else.
        if let iso = configuration.installISOPath, !iso.isEmpty {
            let guest = configuration.guestOS.displayName
            if !fm.fileExists(atPath: dir.appendingPathComponent("autounattend.img").path) {
                return "\(guest) hasn't been installed in \(configuration.name) yet. Next: start it and let the install finish, then export it."
            }
            if fm.fileExists(atPath: dir.appendingPathComponent("install-avm.iso").path)
                || fm.fileExists(atPath: dir.appendingPathComponent(UbuntuAccount.fileName).path) {
                return "\(configuration.name) still has its install disc, so \(guest) is still installing, or hasn't been started since it finished. Next: start it once, let it reach the desktop, shut it down, then export it."
            }
        }
        return nil
    }

    /// The configuration as the package records it: nothing that only
    /// means something on this Mac.
    static func manifestData(for configuration: VMConfiguration, appVersion: String?, date: Date = Date()) throws -> Data {
        var config = configuration
        config.storageFolderPath = nil
        config.diskImagePath = diskFileName(for: configuration)
        let manifest = Manifest(format: formatVersion, exportedAt: date, appVersion: appVersion, configuration: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    /// What export copies, given the choice about a macOS machine's restore
    /// points (each is a full copy once it leaves the volume it was cloned on).
    static func exportPlan(vmDirectory dir: URL, isMac: Bool, includeRestorePoints: Bool) throws -> MachineFileCopier.Plan {
        try MachineFileCopier.plan(source: dir) { relative in
            if exportSkips(relative) { return true }
            if isMac, !includeRestorePoints, relative == "restore-points" || relative.hasPrefix("restore-points/") { return true }
            return false
        }
    }

    /// Files export never copies as they are (see the header). The setup
    /// answers are written separately, without the password's encoding.
    nonisolated static func exportSkips(_ relativePath: String) -> Bool {
        (relativePath as NSString).lastPathComponent == WindowsSetupAnswers.fileName || importSkips(relativePath)
    }

    /// Files import never copies, whatever a package holds: the manifest,
    /// a password hash, and anything transient.
    nonisolated static func importSkips(_ relativePath: String) -> Bool {
        // Clipboard text in transit (MacClipboard.swift) never travels
        // (2026-10-26, code audit).
        if relativePath == "clipboard" || relativePath.hasPrefix("clipboard/") { return true }
        let name = (relativePath as NSString).lastPathComponent
        if name == UbuntuAccount.fileName || name == manifestName || name == "disk-reinstall.qcow2" {
            return true
        }
        return MachineFileCopier.isTransient(name)
    }

    /// Writes the package at `packageURL`. Off the main thread: it can take
    /// an hour for a large disk on a slow drive. A package already there
    /// (the save panel asked before replacing it) goes to the Trash only
    /// once the new one is complete.
    nonisolated static func writePackage(
        plan: MachineFileCopier.Plan,
        from dir: URL,
        to packageURL: URL,
        manifest: Data,
        progress: @Sendable (UInt64, UInt64) -> Void
    ) throws {
        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        let partialPrefix = ".\(packageURL.lastPathComponent)-partial-"
        // An earlier export of this name that AVM's quitting cut short.
        for leftover in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where leftover.hasPrefix(partialPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(leftover))
        }
        let partial = parent.appendingPathComponent(partialPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        do {
            try MachineFileCopier.copy(plan, from: dir, to: partial, progress: progress)
            // The setup answers, without the password's encoding.
            if var answers = WindowsSetupAnswers.load(fromVMDirectory: dir) {
                answers.localAccount?.encodedPassword = nil
                try answers.save(inVMDirectory: partial)
            }
            try manifest.write(to: partial.appendingPathComponent(manifestName), options: .atomic)
            if fm.fileExists(atPath: packageURL.path) {
                try fm.trashItem(at: packageURL, resultingItemURL: nil)
            }
            try fm.moveItem(at: partial, to: packageURL)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    // MARK: Import

    /// Reads and checks a package. Every refusal says exactly what's wrong.
    static func readPackage(_ url: URL) throws -> Manifest {
        let fm = FileManager.default
        let shown = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MachineArchiveError("AVM can't find \(shown). Next: if it's on an external drive, connect the drive, then try again.")
        }
        guard isDirectory.boolValue else {
            throw MachineArchiveError("\(shown) is a file, not a virtual machine AVM exported. An exported machine is a folder whose name ends in .\(packageExtension).")
        }
        let manifestURL = url.appendingPathComponent(manifestName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw MachineArchiveError("\(shown) isn't a virtual machine AVM exported: it has no \(manifestName) inside. If an export was cut short, export the machine again.")
        }
        let manifest: Manifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw MachineArchiveError("\(shown) has a \(manifestName) AVM can't read, so it can't be imported. It may be damaged. Next: export the machine again.")
        }
        guard manifest.format <= formatVersion else {
            throw MachineArchiveError("\(shown) was exported by a newer AVM. Next: update AVM with Check for Updates, then import it again.")
        }
        let config = manifest.configuration
        let missing = missingFiles(for: config, in: url)
        if !missing.isEmpty {
            throw MachineArchiveError("\(shown) is missing \(spokenList(missing)), so \(config.name) couldn't start. Nothing was imported. Next: export the machine again from the Mac it's on.")
        }
        return manifest
    }

    /// The files a machine can't start without.
    static func missingFiles(for config: VMConfiguration, in folder: URL) -> [String] {
        let fm = FileManager.default
        var names: [String]
        if config.guestOS == .macOS {
            let files = MacGuestFiles(folder: folder)
            names = [files.disk, files.auxiliaryStorage, files.hardwareModel, files.machineIdentifier].map(\.lastPathComponent)
        } else {
            names = [diskFileName(for: config)]
            // Without the UNATTEND volume and its install-complete marker,
            // the next Start would install again and wipe the disk.
            if let iso = config.installISOPath, !iso.isEmpty {
                names.append("autounattend.img")
            }
        }
        return names.filter { !fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// What import copies: everything but the manifest and anything
    /// transient that found its way in.
    static func importPlan(package: URL) throws -> MachineFileCopier.Plan {
        try MachineFileCopier.plan(source: package) { relative in
            importSkips(relative)
        }
    }

    /// Copies the package's files into `container`/<id>. Built under a
    /// hidden name first, so Reclaim Disk Space never sees half a machine
    /// as a leftover, and nothing is left behind on failure.
    nonisolated static func copyIn(
        plan: MachineFileCopier.Plan,
        from package: URL,
        container: URL,
        id: UUID,
        progress: @Sendable (UInt64, UInt64) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        let final = container.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else {
            throw MachineArchiveError("A folder for the new machine is already there. Nothing was imported. Next: try again.")
        }
        // An earlier import that AVM's quitting cut short (one runs at a
        // time, so any other working folder is a leftover).
        for leftover in (try? fm.contentsOfDirectory(atPath: container.path)) ?? [] where leftover.hasPrefix(".importing-") {
            try? fm.removeItem(at: container.appendingPathComponent(leftover))
        }
        let partial = container.appendingPathComponent(".importing-\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: false)
        do {
            try MachineFileCopier.copy(plan, from: package, to: partial, progress: progress)
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return final
    }

    /// The configuration to save for an imported machine: a new id, its new
    /// folder, and a name no other machine in the list has.
    static func importedConfiguration(_ original: VMConfiguration, id: UUID, folder: URL, existingNames: [String]) -> VMConfiguration {
        var config = original
        config.id = id
        config.storageFolderPath = nil
        // This Mac's limits, as the wizard's (2026-10-28, fourth audit): a
        // machine made on a 16 GB Mac kept 8 GB, all of an 8 GB Mac's.
        let info = ProcessInfo.processInfo
        config.ramSizeGB = min(config.ramSizeGB, max(4, Int(info.physicalMemory >> 30) / 2))
        config.cpuCount = min(config.cpuCount, max(2, info.processorCount / 2))
        config.diskImagePath = folder.appendingPathComponent(diskFileName(for: original)).path
        config.name = uniqueName(original.name, existing: existingNames)
        // Nothing of the other Mac's (2026-10-28, security review): a
        // package from someone else carried a shared folder, which its
        // disk's software would have read and written on this Mac, and the
        // microphone, camera and printers. They're chosen again here.
        config.sharedFolderPath = nil
        config.sharedFolderReadOnly = nil
        config.shareMicrophone = nil
        config.shareCamera = nil
        config.sharePrinters = nil
        config.usbRememberedDevices = nil
        config.windowsKeyboardID = nil
        config.windowsKeyboardName = nil
        config.windowsKeyboardAppleISO = nil
        config.displayID = nil
        config.displayName = nil
        // Remote Desktop too (2026-10-28, second review): the copy has no
        // keychain password, would claim the same port, and a package
        // from elsewhere would open a port to an account its sender knows.
        config.remoteDesktopUser = nil
        config.remoteDesktopReach = nil
        config.remoteDesktopPort = nil
        config.remoteDesktopPasswordMark = nil
        return config
    }

    /// "Windows 11", or "Windows 11 2" when that's taken, and so on.
    static func uniqueName(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var n = 2
        while taken.contains("\(name) \(n)".lowercased()) { n += 1 }
        return "\(name) \(n)"
    }

    /// The macOS machines in `configurations` with the same
    /// MachineIdentifier as the one in `folder`: copies of the same Mac.
    static func macOSIdentityTwins(of folder: URL, among configurations: [VMConfiguration], excluding id: UUID? = nil) -> [VMConfiguration] {
        guard let identity = try? Data(contentsOf: MacGuestFiles(folder: folder).machineIdentifier) else { return [] }
        return configurations.filter { config in
            guard config.guestOS == .macOS, config.id != id,
                  let dir = try? config.directoryURL(),
                  let other = try? Data(contentsOf: MacGuestFiles(folder: dir).machineIdentifier) else { return false }
            return other == identity
        }
    }

    // MARK: Words

    /// The disk's file name: the last part of the saved path, or the usual
    /// one when there is none.
    static func diskFileName(for configuration: VMConfiguration) -> String {
        let name = URL(fileURLWithPath: configuration.diskImagePath).lastPathComponent
        if configuration.diskImagePath.isEmpty || name.isEmpty || name == "/" {
            return configuration.guestOS == .macOS ? "macos-disk.img" : "disk.qcow2"
        }
        return name
    }

    /// "the drive Backup" for a folder on an external drive, "your Mac"
    /// otherwise.
    nonisolated static func placeName(of url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            return "the drive \(parts[2])"
        }
        return "your Mac"
    }

    /// Sizes with spelled-out units, as the Delete dialog says them.
    nonisolated static func spokenSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return "about \(Int(gb.rounded())) gigabytes" }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return "about \(Int(mb.rounded())) megabytes" }
        return "less than one megabyte"
    }

    private static func spokenList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

// MARK: - Copying

/// The copy itself: a plan of what to copy, made first so its size can be
/// checked against free space before anything is written, then the copy,
/// file by file, cloning where it can.
nonisolated enum MachineFileCopier {

    struct Entry: Sendable, Equatable {
        let relativePath: String
        let isDirectory: Bool
        /// The file's length.
        let logicalBytes: UInt64
        /// The space it takes, which is less for a sparse file.
        let allocatedBytes: UInt64
        let permissions: Int
    }

    struct Plan: Sendable {
        let entries: [Entry]
        var logicalBytes: UInt64 { entries.reduce(0) { $0 + $1.logicalBytes } }
        var allocatedBytes: UInt64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
        var hasRestorePoints: Bool { entries.contains { $0.relativePath.hasPrefix("restore-points/") } }
        /// The space the restore points' files take on their own.
        var restorePointBytes: UInt64 {
            entries.filter { $0.relativePath.hasPrefix("restore-points/") }.reduce(0) { $0 + $1.allocatedBytes }
        }
    }

    /// Names that only mean something while a machine runs.
    static func isTransient(_ name: String) -> Bool {
        let names: Set<String> = [".DS_Store", ".lock", "SavedState.vzvmsave",
                                  "watchdog-screen.ppm", "guest-screen.ppm", "firmware-serial.log"]
        if names.contains(name) { return true }
        for suffix in [".sock", ".log", ".ppm", ".restoring", ".vzvmsave"] where name.hasSuffix(suffix) {
            return true
        }
        // A cut-short export or import's own working folders.
        return name.hasPrefix(".importing-") || name.contains(".\(MachineArchive.packageExtension)-partial-")
    }

    /// Everything under `source` that `skip` lets through. Only folders and
    /// plain files: sockets, pipes and links are never copied.
    static func plan(source: URL, skip: (String) -> Bool) throws -> Plan {
        var entries: [Entry] = []
        try walk(source, relative: "", skip: skip, into: &entries)
        return Plan(entries: entries)
    }

    /// Parents before children, so the copy makes each folder before
    /// what's in it.
    private static func walk(_ folder: URL, relative: String, skip: (String) -> Bool, into entries: inout [Entry]) throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        } catch {
            throw MachineArchiveError("AVM couldn't read the folder \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        for name in names {
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            if skip(path) { continue }
            let url = folder.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let permissions = Int(info.st_mode & 0o7777)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries.append(Entry(relativePath: path, isDirectory: true, logicalBytes: 0, allocatedBytes: 0, permissions: permissions))
                try walk(url, relative: path, skip: skip, into: &entries)
            case S_IFREG:
                // st_blocks counts 512-byte units, whatever the block size.
                entries.append(Entry(relativePath: path, isDirectory: false, logicalBytes: UInt64(max(0, info.st_size)),
                                     allocatedBytes: UInt64(max(0, info.st_blocks)) * 512, permissions: permissions))
            default:
                // Sockets, pipes and links: never copied.
                continue
            }
        }
    }

    /// The space the copy needs on the volume holding `destinationFolder`:
    /// almost none when it can be cloned there, the space the files take
    /// now on a volume with sparse files, their full length on one without.
    static func bytesNeeded(_ plan: Plan, from source: URL, to destinationFolder: URL) -> UInt64 {
        if sameVolume(source, destinationFolder), fileSystemName(destinationFolder) == "apfs" {
            return 64 * 1_048_576
        }
        switch fileSystemName(destinationFolder) {
        case "apfs", "hfs": return plan.allocatedBytes
        default: return plan.logicalBytes
        }
    }

    static func availableBytes(at folder: URL) -> UInt64? {
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
        return values?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    /// "apfs", "hfs", "exfat", "msdos", "smbfs"...; nil if unknown.
    static func fileSystemName(_ url: URL) -> String? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Copies the plan into `destination`, an existing empty folder.
    /// `progress` gets bytes done and bytes in all, measured in the space
    /// the files take, after each file and every few megabytes.
    static func copy(_ plan: Plan, from source: URL, to destination: URL, progress: (UInt64, UInt64) -> Void) throws {
        let total = max(plan.allocatedBytes, 1)
        var done: UInt64 = 0
        let fm = FileManager.default
        for entry in plan.entries {
            let from = source.appendingPathComponent(entry.relativePath)
            let to = destination.appendingPathComponent(entry.relativePath)
            if entry.isDirectory {
                try fm.createDirectory(at: to, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: entry.permissions | 0o700])
                continue
            }
            if clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) == 0 {
                done += entry.allocatedBytes
                progress(min(done, total), total)
                continue
            }
            let start = done
            try copyFile(from, to: to, permissions: entry.permissions) { read in
                done = start + min(read, entry.allocatedBytes)
                progress(min(done, total), total)
            }
            done = start + entry.allocatedBytes
            progress(min(done, total), total)
        }
    }

    /// One file, holes kept as holes: only the parts with data are read
    /// (SEEK_DATA/SEEK_HOLE), and blocks of zeros inside them aren't
    /// written. The length is set at the end, so trailing holes stay holes.
    static func copyFile(_ source: URL, to destination: URL, permissions: Int, progress: (UInt64) -> Void) throws {
        func failure(_ step: String) -> MachineArchiveError {
            MachineArchiveError("Couldn't \(step) \(source.lastPathComponent): \(String(cString: strerror(errno))).")
        }
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw failure("read") }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard output >= 0 else { throw failure("write") }
        defer { close(output) }

        var info = stat()
        guard fstat(input, &info) == 0 else { throw failure("read") }
        let length = info.st_size
        let chunk = 8 * 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var read: UInt64 = 0
        var offset: off_t = 0
        while offset < length {
            var dataStart = lseek(input, offset, SEEK_DATA)
            if dataStart < 0 {
                if errno == ENXIO { break }     // only a hole is left
                dataStart = offset              // no hole support: all data
            }
            var holeStart = lseek(input, dataStart, SEEK_HOLE)
            if holeStart < 0 || holeStart > length { holeStart = length }
            var position = dataStart
            while position < holeStart {
                let want = Int(min(off_t(chunk), holeStart - position))
                let got = pread(input, buffer, want, position)
                if got < 0 { if errno == EINTR { continue }; throw failure("read") }
                if got == 0 { break }
                if !isAllZero(buffer, count: got) {
                    var written = 0
                    while written < got {
                        let n = pwrite(output, buffer + written, got - written, position + off_t(written))
                        if n < 0 { if errno == EINTR { continue }; throw failure("write") }
                        written += n
                    }
                }
                position += off_t(got)
                read += UInt64(got)
                progress(read)
            }
            offset = max(holeStart, offset + 1)
        }
        guard ftruncate(output, length) == 0 else { throw failure("write") }
        guard fsync(output) == 0 else { throw failure("finish writing") }
        fchmod(output, mode_t(permissions & 0o777))
    }

    private static func isAllZero(_ pointer: UnsafeMutableRawPointer, count: Int) -> Bool {
        let words = count / 8
        let wordPointer = pointer.bindMemory(to: UInt64.self, capacity: words)
        for i in 0..<words where wordPointer[i] != 0 { return false }
        let bytes = pointer.bindMemory(to: UInt8.self, capacity: count)
        for i in (words * 8)..<count where bytes[i] != 0 { return false }
        return true
    }
}
