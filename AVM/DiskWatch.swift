// DiskWatch.swift
// AVM — Accessible Virtual Machine
//
// DISK SPACE, SPOKEN (2026-10-27), as Hyper-V and VMware warn: while a
// machine runs, AVM checks once a minute (VMManager.startDiskWatch):
//   - the Mac's disk where the machine lives, which its disk grows into:
//     said once at each of 20, 10 and 5 GB free, again only after it has
//     had more than 25 GB free;
//   - whether QEMU has paused it because that disk is full (QEMU stops a
//     machine whose disk write fails for lack of space, and says only
//     "io-error" when asked): said, and the machine is shown as paused,
//     so Resume is there once space is free;
//   - every five minutes, through the guest agent, the machine's own
//     drives (C:, /): said once when one passes 90% full, again only
//     after it has dropped below 85%.
// The decisions are here, plain, so the tests can check them.

import Foundation

nonisolated enum DiskWatch {
    static let gigabyte: Int64 = 1_073_741_824
    /// Free space on the Mac at which AVM speaks, largest first.
    static let hostThresholds: [Int64] = [20, 10, 5].map { $0 * gigabyte }
    /// More free than this, and the warnings start over.
    static let hostReset: Int64 = 25 * gigabyte

    /// The threshold to speak now, if any: the smallest one `free` is
    /// below that hasn't been spoken (`lastSpoken` is the smallest spoken
    /// so far). Returns the new lastSpoken too.
    static func hostWarning(free: Int64, lastSpoken: Int64?) -> (speak: Int64?, lastSpoken: Int64?) {
        if free > hostReset { return (nil, nil) }
        guard let crossed = hostThresholds.last(where: { free < $0 }) else { return (nil, lastSpoken) }
        if let lastSpoken, crossed >= lastSpoken { return (nil, lastSpoken) }
        return (crossed, crossed)
    }

    /// `drive` is the external drive the machine is kept on, or nil for
    /// the Mac's own disk (2026-10-29, sixth audit: a drive's free space
    /// was said as the Mac's, and the user sent to free the wrong disk).
    static func hostWords(machine: String, free: Int64, drive: String? = nil) -> String {
        let gb = max(0, free / gigabyte)
        if let drive {
            return "The drive \(drive) has \(gb) gigabytes free, and \(machine)'s disk, kept on it, grows as it's used. When the drive is full, \(machine) pauses. Next: free some space on \(drive)."
        }
        return "Your Mac has \(gb) gigabytes free, and \(machine)'s disk grows as it's used. When the Mac's disk is full, \(machine) pauses. Next: free some space on your Mac."
    }

    /// One of the machine's drives, from the guest agent's guest-get-fsinfo.
    struct Drive: Equatable {
        let name: String     // "C:" or "/"
        let used: Int64
        let total: Int64
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// The drives worth watching: Windows' lettered drives and Linux's
    /// root, over a gigabyte; not the install media, swap or memory.
    static func drives(fromFsinfo reply: Any?) -> [Drive] {
        guard let list = reply as? [[String: Any]] else { return [] }
        return list.compactMap { fs in
            guard let mount = fs["mountpoint"] as? String,
                  let total = (fs["total-bytes"] as? NSNumber)?.int64Value,
                  let used = (fs["used-bytes"] as? NSNumber)?.int64Value,
                  total > gigabyte else { return nil }
            let type = (fs["type"] as? String ?? "").lowercased()
            if ["cdfs", "udf", "iso9660", "tmpfs", "squashfs", "vfat"].contains(type) { return nil }
            if mount == "/" { return Drive(name: "/", used: used, total: total) }
            // "C:\\" on Windows.
            if mount.count <= 3, mount.dropFirst().hasPrefix(":") {
                return Drive(name: String(mount.prefix(2)).uppercased(), used: used, total: total)
            }
            return nil
        }
    }

    /// Which drives to speak about now: past 90% and not yet spoken, and
    /// the new set of spoken drives (one below 85% may warn again).
    static func guestWarnings(_ drives: [Drive], spoken: Set<String>) -> (speak: [Drive], spoken: Set<String>) {
        var spoken = spoken
        var speak: [Drive] = []
        for drive in drives {
            if drive.fraction >= 0.90, !spoken.contains(drive.name) {
                speak.append(drive)
                spoken.insert(drive.name)
            } else if drive.fraction < 0.85 {
                spoken.remove(drive.name)
            }
        }
        return (speak, spoken)
    }

    static func guestWords(machine: String, drive: Drive) -> String {
        let percent = Int((drive.fraction * 100).rounded())
        let left = max(0, (drive.total - drive.used) / gigabyte)
        let which = drive.name == "/" ? "\(machine)'s disk" : "\(machine)'s \(drive.name) drive"
        return "\(which) is \(percent) percent full, with \(left) gigabytes left. Next: delete files in \(machine), or make its disk larger in Settings while it's shut down."
    }
}
