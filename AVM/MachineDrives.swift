// MachineDrives.swift
// AVM — Accessible Virtual Machine
//
// More disk (2026-11-03, the user's request, "sorta like upgrading your pc").
//   - How full: the dashboard shows what the disk watch last heard from the guest
//     agent, kept in the machine's folder so a stopped machine still has a figure.
//   - Growing: Settings makes the disk larger, and the next Start gives Windows'
//     drive C the new space. A Linux machine's layout differs by distribution, so
//     that stays a step for the user.
//   - A second drive: its own qcow2 in the machine's folder, on the same kind of
//     connection as the first, made ready by the guest at the next Start. Restore
//     points and saves name both disks, so they go back together. Copies and exports
//     take everything in the folder, so it goes with them.
//   There's no removing a second drive yet, as a disk can't shrink either.

import Combine
import Foundation

/// What each machine's drives last said.
@MainActor
final class DiskUsage: ObservableObject {
    static let shared = DiskUsage()
    @Published private var known: [UUID: [DiskWatch.Drive]] = [:]

    private struct Saved: Codable {
        let name: String
        let used: Int64
        let total: Int64
    }

    func drives(of configuration: VMConfiguration) -> [DiskWatch.Drive] {
        if let drives = known[configuration.id] { return drives }
        guard let folder = try? configuration.directoryURL(),
              let data = try? Data(contentsOf: folder.appendingPathComponent(DiskWatch.usageFileName)),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return saved.map { DiskWatch.Drive(name: $0.name, used: $0.used, total: $0.total) }
    }

    func note(_ drives: [DiskWatch.Drive], machine: UUID, folder: URL) {
        guard known[machine] != drives else { return }
        known[machine] = drives
        if let data = try? JSONEncoder().encode(drives.map { Saved(name: $0.name, used: $0.used, total: $0.total) }) {
            try? data.write(to: folder.appendingPathComponent(DiskWatch.usageFileName), options: .atomic)
        }
    }

    /// What a machine's disks take on the Mac: only what has been written, as they
    /// grow as they're used. Nil when they can't be read, such as on a drive that
    /// isn't connected.
    func onMacBytes(of configuration: VMConfiguration) -> Int64? {
        func allocated(_ url: URL) -> Int64? {
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
        }
        guard !configuration.diskImagePath.isEmpty,
              let disk = allocated(URL(fileURLWithPath: configuration.diskImagePath)) else { return nil }
        let second = (try? configuration.directoryURL()).flatMap(RestorePoints.secondDrive).flatMap(allocated) ?? 0
        return disk + second
    }

    /// The disk changed size, so the figures are old.
    func forget(machine: UUID, folder: URL) {
        known[machine] = []
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(DiskWatch.usageFileName))
    }
}

extension VMManager {
    /// The second drive, on the same kind of connection as the first: a machine
    /// on NVMe may have no virtio driver.
    func secondDriveArguments(configuration: VMConfiguration) -> [String] {
        guard configuration.secondDriveGB != nil, let folder = try? configuration.directoryURL(),
              let file = RestorePoints.secondDrive(folder) else { return [] }
        let device = configuration.usesVirtioDisk ? "virtio-blk-pci,drive=disk1,serial=avmdisk1" : "nvme,drive=disk1,serial=avmdisk1"
        return ["-drive", "if=none,id=disk1,file=\(Self.qemuOptionValue(file.path)),format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap",
                "-device", device]
    }

    /// What a snapshot names: the first disk's node and the second's. With only
    /// the first, carrying on from a restore point would put memory back over a
    /// second drive that had moved on, which ruins its file system.
    func snapshotDevices(_ node: String) async throws -> [String] {
        let blocks = try await sendQMPCommand("query-block", arguments: nil) as? [[String: Any]] ?? []
        guard let second = blocks.first(where: { $0["device"] as? String == "disk1" }),
              let inserted = second["inserted"] as? [String: Any],
              let name = inserted["node-name"] as? String else { return [node] }
        return [node, name]
    }

    /// Once the guest agent answers: drive C takes the new space, and a new second
    /// drive is made ready. Each is noted as done only when the guest has said how
    /// it went, so one that couldn't be asked is tried again at the next Start.
    func finishDiskChanges(configuration: VMConfiguration) async {
        guard await waitForGuestAgent(limit: .seconds(600)) else {
            AVMLog.write("AVM: finishDiskChanges - the guest agent didn't answer; trying again at the next Start")
            return
        }
        let machine = configuration.name
        if configuration.extendDriveC == true, configuration.guestOS == .windows,
           let output = try? await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"],
                                            limit: .seconds(180), input: DiskWatch.extendDriveCScript + "\n") {
            let answer = DiskWatch.answer(output)
            AVMLog.write("AVM: finishDiskChanges - drive C: \(answer?.word ?? "no answer")")
            switch answer?.word {
            case "extended":
                Announcer.shared.announce("\(machine)'s drive C is now \(answer?.detail ?? "") gigabytes.", tone: .success)
            default:
                Announcer.shared.announce("\(machine)'s drive C couldn't take the new space. A partition may be in the way. The README's section on making a disk larger says what to do next.", tone: .failure)
            }
            storeDiskChange(configuration) { $0.extendDriveC = nil }
        }
        let needsFormat = configuration.secondDriveNeedsFormat == true
        if needsFormat || configuration.guestOS.isLinux, let size = configuration.secondDriveGB {
            let output = configuration.guestOS == .windows
                ? try? await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"],
                                      limit: .seconds(180), input: DiskWatch.formatWindowsDriveScript(sizeGB: size) + "\n")
                : try? await agentRun("/bin/sh", ["-c", DiskWatch.linuxDriveScript(format: needsFormat)], limit: .seconds(180))
            guard let output else { return }
            let answer = DiskWatch.answer(output)
            AVMLog.write("AVM: finishDiskChanges - second drive: \(answer?.word ?? "no answer")")
            switch answer?.word {
            case "ready":
                let place = configuration.guestOS == .windows ? "drive \(answer?.detail ?? "")" : "the folder \(answer?.detail ?? "")"
                Announcer.shared.announce("\(machine)'s second drive is ready, as \(place), with \(size) gigabytes.", tone: .success)
                storeDiskChange(configuration) { $0.secondDriveNeedsFormat = nil }
            case "already":
                if needsFormat { storeDiskChange(configuration) { $0.secondDriveNeedsFormat = nil } }
            default:
                Announcer.shared.announce("\(machine)'s second drive couldn't be made ready. AVM tries again at its next Start.", tone: .failure)
            }
        }
    }

}
