// MachineBackups.swift
// AVM — Accessible Virtual Machine
//
// Automatic backups (2026-11-01, the user's request): a machine's Export, on a
// schedule, into one chosen folder, such as an external drive. A machine that's
// running or saved with its apps open waits until it's shut down; AVM looks
// every hour. Each is an ordinary .avmvm that Import reads. Only after a new one
// is whole do older ones of that machine go, past the newest few.

import AppKit

@MainActor
final class MachineBackups {
    static let shared = MachineBackups()
    private var timer: Timer?
    /// Said once a day, not every hour.
    private var toldNoFolder: Date?

    /// At launch: the first look a minute in, then hourly.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            Task { @MainActor in await self?.runDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runDue() }
        }
    }

    /// Whichever machines are due, one at a time.
    func runDue(now: Date = Date()) async {
        guard let store = VMStore.shared else { return }
        let due = store.configurations.filter { BackupSchedule.isDue(every: $0.backupEvery, last: $0.lastBackup, now: now) }
        guard !due.isEmpty else { return }
        guard let path = UserDefaults.standard.string(forKey: BackupSchedule.folderKey), FileManager.default.fileExists(atPath: path) else {
            if toldNoFolder.map({ now.timeIntervalSince($0) > 86_400 }) ?? true {
                toldNoFolder = now
                Announcer.shared.announce("AVM couldn't back up \(due[0].name): its backup folder isn't there. Next: connect the drive, or choose a folder in the machine's Settings, under Startup and Recovery.", tone: .failure)
            }
            return
        }
        for config in due {
            if await MachineArchiveController.shared.backUp(config, into: URL(fileURLWithPath: path, isDirectory: true)) {
                var updated = store.configurations.first { $0.id == config.id } ?? config
                updated.lastBackup = now
                store.save(updated)
            }
        }
    }
}

extension VMConfiguration {
    /// The backup's folder name, without the extension.
    var backupBaseName: String {
        (MachineArchive.packageName(for: self) as NSString).deletingPathExtension
    }
}
