// MachineDrives.swift
// AVM — Accessible Virtual Machine
//
// More disk (2026-11-03, the user's request, "sorta like upgrading your pc").
//   - How full: the dashboard shows what the disk watch last heard from the guest
//     agent, kept in the machine's folder so a stopped machine still has a figure.

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
