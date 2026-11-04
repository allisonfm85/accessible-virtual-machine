// MachineDrives.swift
// AVM — Accessible Virtual Machine
//
// More disk (2026-11-03, the user's request, "sorta like upgrading your pc").
//   - How full: the dashboard shows what the disk watch last heard from the guest
//     agent, kept in the machine's folder so a stopped machine still has a figure.
//   - Growing: Settings makes the disk larger, and the next Start gives Windows'
//     drive C the new space. A Linux machine's layout differs by distribution, so
//     that stays a step for the user.

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

    /// The disk changed size, so the figures are old.
    func forget(machine: UUID, folder: URL) {
        known[machine] = []
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(DiskWatch.usageFileName))
    }
}

extension VMManager {
    /// Once the guest agent answers: drive C takes the new space. It's noted as
    /// done only when the guest has said how it went, so if it couldn't be asked,
    /// it's tried again at the next Start.
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
    }

}
