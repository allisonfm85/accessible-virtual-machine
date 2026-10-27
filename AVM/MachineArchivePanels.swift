// MachineArchivePanels.swift
// AVM — Accessible Virtual Machine
//
// Export Virtual Machine… and Import Virtual Machine… (2026-10-26): the
// panels, the checks a user hears before anything is written, and the
// spoken progress. The copying and every rule about what goes into a
// package are MachineArchive.swift, where the tests reach them.
//
// SPOKEN, START TO END: a refusal says why and what to do next; a copy
// says where it's going and how big it is when it starts, then every 10
// percent for anything over 2 gigabytes (an export to a USB drive can take
// most of an hour, and silence for that long is indistinguishable from a
// hang), then how it ended. Cancelling a panel is the user's own action and
// is only logged, as Delete's Cancel is.
//
// ONE AT A TIME: while a copy runs, that machine can't be started, changed
// in Settings or deleted (refusesWhileBusy), and a second export or import
// is refused with the name of the one running. Quitting asks first
// (QuitCoordinator).
//
// PRIVACY: the log gets machine names, sizes and "your Mac" or the drive's
// name, never a password, and paths only through AVMLog's sanitizer.

import AppKit
import Combine

@MainActor
final class MachineArchiveController: ObservableObject {
    static let shared = MachineArchiveController()

    /// The machine being exported, or the id the imported one will have;
    /// nil when nothing is being copied.
    @Published private(set) var busyMachineID: UUID?
    /// "exporting Work PC", for refusals and the quit question.
    @Published private(set) var activity: String?
    var isWorking: Bool { activity != nil }

    /// Progress is spoken only for copies at least this big.
    private static let speakProgressFrom: UInt64 = 2_000_000_000
    /// Room left over on the destination, so the copy never fills a drive
    /// to the last byte.
    private static let spareBytes: UInt64 = 512 * 1_048_576

    private init() {}

    /// True, after saying why, when `config` is being copied right now.
    func refusesWhileBusy(_ config: VMConfiguration) -> Bool {
        guard busyMachineID == config.id, let activity else { return false }
        Announcer.shared.announce("AVM is \(activity). Wait until it's done, then try again.", tone: .failure)
        return true
    }

    // MARK: - Export

    func export(_ config: VMConfiguration, isRunning: Bool) {
        let name = config.name
        if let activity {
            refuse("AVM is already \(activity). Next: try again when it's done.", log: "another copy is running")
            return
        }
        if isRunning {
            refuse("\(name) is running. Next: shut it down, then export it.", log: "'\(name)' is running")
            return
        }
        let dir: URL
        do {
            dir = try config.directoryURL()
        } catch {
            refuse("AVM can't find \(name)'s folder. Reason: \(error.localizedDescription)", log: "no folder for '\(name)'")
            return
        }
        if let problem = MachineArchive.exportProblem(for: config, vmDirectory: dir) {
            refuse("\(problem) Nothing was exported.", log: "'\(name)' can't be exported now")
            return
        }

        // A macOS machine's restore points are APFS clones: free beside the
        // disk, a full copy each anywhere else. The user decides.
        let isMac = config.guestOS == .macOS
        var includeRestorePoints = true
        let pointCount = isMac ? MacRestorePoints.list(MacGuestFiles(folder: dir)).count : 0
        if pointCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Include \(name)'s restore points?"
            alert.informativeText = "\(name) has \(pointCount == 1 ? "one restore point" : "\(pointCount) restore points"). On another drive each one is a full copy of the disk, so they can make the export several times larger. Leave them out to export the machine only as it is now."
            alert.addButton(withTitle: "Include Restore Points")
            alert.addButton(withTitle: "Leave Them Out")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: includeRestorePoints = true
            case .alertSecondButtonReturn: includeRestorePoints = false
            default:
                AVMLog.write("AVM: Export — cancelled at the restore points question for '\(name)'.")
                return
            }
        }

        let packageName = MachineArchive.packageName(for: config)
        let panel = NSSavePanel()
        panel.title = "Export \(name)"
        panel.message = "Choose where to save \(name), such as an external drive. AVM saves it as a folder named \(packageName), which Import Virtual Machine brings back."
        panel.prompt = "Export"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = packageName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, var package = panel.url else {
            AVMLog.write("AVM: Export — save panel cancelled for '\(name)'.")
            return
        }
        if package.pathExtension.lowercased() != MachineArchive.packageExtension {
            package.appendPathExtension(MachineArchive.packageExtension)
            // The panel asked about replacing the name as typed, not this one.
            if FileManager.default.fileExists(atPath: package.path) {
                refuse("Something named \(package.lastPathComponent) is already there. Nothing was exported. Next: export again and choose another name.", log: "name taken")
                return
            }
        }
        let parent = package.deletingLastPathComponent()
        let place = MachineArchive.placeName(of: parent)
        let dirPath = dir.standardizedFileURL.path
        if parent.standardizedFileURL.path == dirPath || parent.standardizedFileURL.path.hasPrefix(dirPath + "/") {
            refuse("That folder is inside \(name) itself. Nothing was exported. Next: choose another folder or drive.", log: "destination inside the machine")
            return
        }

        let plan: MachineFileCopier.Plan
        let manifest: Data
        do {
            plan = try MachineArchive.exportPlan(vmDirectory: dir, isMac: isMac, includeRestorePoints: includeRestorePoints)
            manifest = try MachineArchive.manifestData(for: config, appVersion: Self.appVersion)
        } catch {
            refuse("AVM couldn't read \(name)'s files, so nothing was exported. Reason: \(error.localizedDescription)", log: "plan failed for '\(name)'")
            return
        }
        let needed = MachineFileCopier.bytesNeeded(plan, from: dir, to: parent)
        if let free = MachineFileCopier.availableBytes(at: parent), free < needed + Self.spareBytes {
            refuse("There isn't room for \(name) on \(place). It needs \(MachineArchive.spokenSize(needed)), and \(MachineArchive.spokenSize(free)) is free. Nothing was exported. Next: free some space, or choose another drive.", log: "not enough space for '\(name)' (\(needed) needed, \(free) free)")
            return
        }

        begin("exporting \(name)", id: config.id)
        AVMLog.write("AVM: Export — '\(name)' to \(place), \(plan.entries.count) items, \(needed) bytes needed, restore points \(includeRestorePoints ? "included" : "left out").")
        Announcer.shared.announce("Exporting \(name) to \(place): \(MachineArchive.spokenSize(plan.allocatedBytes)). \(plan.allocatedBytes >= Self.speakProgressFrom ? "AVM will say how it's going. " : "")Don't start \(name)\(place == "your Mac" ? "" : " or disconnect the drive") until it's done.", tone: .info)

        let ticker = ProgressTicker(verb: "Exporting", name: name, speaks: plan.allocatedBytes >= Self.speakProgressFrom)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () throws -> Void in
                try MachineArchive.writePackage(plan: plan, from: dir, to: package, manifest: manifest) { done, total in
                    ticker.report(done, of: total)
                }
            }.result
            self.end()
            switch result {
            case .success:
                AVMLog.write("AVM: Export — '\(name)' exported to \(place).")
                Announcer.shared.announce("\(name) is exported to \(place), in the folder \(package.lastPathComponent). To bring it back, on this Mac or another, choose Import Virtual Machine in the Virtual Machine menu.", tone: .success)
            case .failure(let error):
                AVMLog.write("AVM: Export — FAILED for '\(name)': \(error.localizedDescription)")
                Announcer.shared.announce("Exporting \(name) failed, and nothing half-written was left on \(place). \(name) itself is untouched. Reason: \(error.localizedDescription) Next: check the drive is connected and has room, then export again.", tone: .failure)
            }
        }
    }

    // MARK: - Import

    func importMachine(into store: VMStore) {
        if let activity {
            refuse("AVM is already \(activity). Next: try again when it's done.", log: "another copy is running")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Virtual Machine"
        panel.message = "Choose a virtual machine AVM exported: a folder whose name ends in .\(MachineArchive.packageExtension)."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let package = panel.url else {
            AVMLog.write("AVM: Import — open panel cancelled.")
            return
        }
        let place = MachineArchive.placeName(of: package)

        let manifest: MachineArchive.Manifest
        let plan: MachineFileCopier.Plan
        let container: URL
        do {
            manifest = try MachineArchive.readPackage(package)
            plan = try MachineArchive.importPlan(package: package)
            container = try VMConfiguration.defaultVMsContainer()
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            refuse(error.localizedDescription, log: "package refused")
            return
        }
        let original = manifest.configuration
        let name = MachineArchive.uniqueName(original.name, existing: store.configurations.map(\.name))
        let needed = MachineFileCopier.bytesNeeded(plan, from: package, to: container)
        if let free = MachineFileCopier.availableBytes(at: container), free < needed + Self.spareBytes {
            refuse("There isn't room on your Mac for \(name). It needs \(MachineArchive.spokenSize(needed)), and \(MachineArchive.spokenSize(free)) is free. Nothing was imported. Next: free some space, then import again.", log: "not enough space for '\(name)' (\(needed) needed, \(free) free)")
            return
        }

        let id = UUID()
        begin("importing \(name)", id: id)
        AVMLog.write("AVM: Import — '\(name)' (\(original.guestOS.displayName)) from \(place), \(plan.entries.count) items, \(needed) bytes needed.")
        Announcer.shared.announce("Importing \(name) from \(place): \(MachineArchive.spokenSize(plan.allocatedBytes)). \(plan.allocatedBytes >= Self.speakProgressFrom ? "AVM will say how it's going. " : "")\(place == "your Mac" ? "" : "Don't disconnect the drive until it's done.")", tone: .info)

        let ticker = ProgressTicker(verb: "Importing", name: name, speaks: plan.allocatedBytes >= Self.speakProgressFrom)
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () throws -> URL in
                try MachineArchive.copyIn(plan: plan, from: package, container: container, id: id) { done, total in
                    ticker.report(done, of: total)
                }
            }.result
            self.end()
            switch result {
            case .success(let folder):
                self.finishImport(original, id: id, folder: folder, into: store)
            case .failure(let error):
                AVMLog.write("AVM: Import — FAILED for '\(name)': \(error.localizedDescription)")
                Announcer.shared.announce("Importing \(name) failed. Nothing was added, and nothing was left behind on your Mac. Reason: \(error.localizedDescription) Next: check the drive is connected, then import again.", tone: .failure)
            }
        }
    }

    private func finishImport(_ original: VMConfiguration, id: UUID, folder: URL, into store: VMStore) {
        let config = MachineArchive.importedConfiguration(original, id: id, folder: folder,
                                                          existingNames: store.configurations.map(\.name))
        store.save(config)
        AVMLog.write("AVM: Import — '\(config.name)' added to the list.")
        var words = "\(config.name) is ready. It's in your list of virtual machines."
        if config.name != original.name {
            words += " AVM named it \(config.name), because \(original.name) is already in your list."
        }
        // The same Mac to macOS (2026-10-26): its MachineIdentifier is kept,
        // so copies must not run together.
        if config.guestOS == .macOS {
            let twins = MachineArchive.macOSIdentityTwins(of: folder, among: store.configurations, excluding: id)
            if let running = twins.first(where: { MacGuestRunner.shared.runningID == $0.id }) {
                words += " It's a copy of \(running.name), which is running now, and macOS sees them as the same Mac. Shut \(running.name) down before you start \(config.name)."
            } else if !twins.isEmpty {
                words += " macOS sees it as the same Mac as \(twins.map(\.name).joined(separator: " and ")), so run only one of them at a time."
            }
        }
        Announcer.shared.announce(words, tone: .success)
    }

    // MARK: - Helpers

    private func begin(_ activity: String, id: UUID) {
        self.activity = activity
        busyMachineID = id
    }

    private func end() {
        activity = nil
        busyMachineID = nil
    }

    private func refuse(_ words: String, log: String) {
        AVMLog.write("AVM: Export/Import refused — \(log).")
        Announcer.shared.announce(words, tone: .failure)
    }

    private static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}

/// Speaks "Exporting Work PC, 30 percent." at each tenth, from the copy's
/// own thread. Called by one copy at a time, in order.
nonisolated private final class ProgressTicker: @unchecked Sendable {
    private let verb: String
    private let name: String
    private let speaks: Bool
    private var lastTenth = 0

    init(verb: String, name: String, speaks: Bool) {
        self.verb = verb
        self.name = name
        self.speaks = speaks
    }

    nonisolated func report(_ done: UInt64, of total: UInt64) {
        guard speaks, total > 0 else { return }
        let tenth = Int(min(done, total) * 10 / total)
        guard tenth > lastTenth, tenth < 10 else { return }
        lastTenth = tenth
        let words = "\(verb) \(name), \(tenth * 10) percent."
        Task { @MainActor in
            Announcer.shared.announce(words, tone: .info)
        }
    }
}
