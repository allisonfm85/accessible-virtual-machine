// GuestWatch.swift
// AVM — Accessible Virtual Machine
//
// Watching a running Windows or Linux machine for what a blind user can't
// see (2026-10-31, the user's request), one loop per machine, from Start
// to Stop:
//
//   - Screen changes said: while no screen reader runs in the machine
//     (Setup, a restart, a boot error, a blue screen), new text on its
//     screen is read out by itself, as Read Screen reads it on request.
//     A screen reader running there does the reading instead, so this
//     stays quiet then.
//   - A screen reader that stopped: one that ran in this session and no
//     longer does is started again with its desktop shortcut key
//     (Control-Alt-N for NVDA, Control-Alt-J for JAWS, Super-Alt-S for
//     Orca in GNOME), and the user is told. Also once at sign-in when the
//     machine's chosen screen reader hasn't started. "Running" is its
//     process: a screen reader that hangs without quitting isn't seen.
//   - A restore point before updates: when updates are waiting, a restore
//     point is taken with the machine running (at most once a day, the
//     newest kept), so updates that break the machine can be undone. If
//     the machine then doesn't come back from a restart for 20 minutes,
//     the user is told how to go back.
//
// Each can be turned off in AVM's Settings, General. The screen is never
// kept or logged; only how many lines were said.

import AppKit
import CoreGraphics
import Foundation
import ImageIO

// The settings, the process list and the screen comparison are in
// GuestWatchLogic.swift, where the logic tests reach them.


// MARK: - The loop

extension VMManager {

    /// From Start, every run, installed or not (Setup is where the screen
    /// matters most); the screen reader and update watches only once the
    /// machine is installed.
    func startGuestWatch(configuration: VMConfiguration, runtimeDir: URL, installed: Bool) {
        guestWatchTask?.cancel()
        guard configuration.guestOS == .windows || configuration.guestOS.isLinux else { return }
        let windows = configuration.guestOS == .windows
        let machine = configuration.name
        let chosenReaders = windows ? configuration.windowsScreenReaders.map(\.displayName) : []
        let picture = runtimeDir.appendingPathComponent("watch-screen.ppm")
        guestWatchTask = Task { [weak self] in
            var lastThumb: [UInt8]?
            var said = Set<String>()
            var processes: GuestProcesses?
            var agentAnswered = false
            var tick = 0
            var readersSeen = Set<String>()
            var missingChecks = 0
            var restartedReader = false
            var signedInChecks = 0
            var toldNoReader = false
            var lastUpdateCheck = Date()
            var agentLostAt: Date?
            var pointThisRun = false
            var toldNoComeBack = false
            var toldDevices = false
            var agentEverAnswered = false
            let started = Date()
            defer { try? FileManager.default.removeItem(at: picture) }
            var lastBoot: String?
            // Whether a screen reader runs, kept through one failed listing
            // (2026-11-01, audit): a slow tasklist read the whole screen over
            // NVDA, and a machine restarting stayed marked as having one.
            var readerRunning = false
            var failedListings = 0
            defer { Announcer.readerRunningIn.remove(machine) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .running else { continue }
                tick += 1

                // Every 16 seconds: what runs in the machine, through its
                // agent (none during Setup or a restart).
                if tick % 4 == 1 {
                    let listing: String? = windows
                        ? try? await self.agentRun("tasklist.exe", ["/fo", "csv", "/nh"], limit: .seconds(20))
                        : try? await self.agentRun("/bin/sh", ["-c", "cat /proc/sys/kernel/random/boot_id; ps -eo comm"], limit: .seconds(20))
                    processes = listing.map { GuestProcesses.parse($0, windows: windows) }
                    agentAnswered = listing != nil
                    if let processes {
                        failedListings = 0
                        readerRunning = !processes.screenReaders.isEmpty
                    } else {
                        failedListings += 1
                        if failedListings >= 2 { readerRunning = false }
                    }
                    if readerRunning { Announcer.readerRunningIn.insert(machine) } else { Announcer.readerRunningIn.remove(machine) }
                    agentEverAnswered = agentEverAnswered || agentAnswered
                    // Restarted between two listings (2026-10-31): with the
                    // restore point fixed, Windows was back in under 16
                    // seconds, every listing answered, and "back" was never said.
                    let boot = processes?.boot
                    let restarted = boot != nil && lastBoot != nil && boot != lastBoot
                    if let boot { lastBoot = boot }
                    if agentAnswered {
                        if pointThisRun, agentLostAt != nil || restarted {
                            let away = agentLostAt.map { ", \(Int(Date().timeIntervalSince($0))) s after it stopped" } ?? ", restarted between two looks"
                            AVMLog.write("AVM: GuestWatch — \(machine) answers again\(away)")
                            Announcer.shared.announce("\(machine) is back after its restart. The restore point from before the updates is kept, in Settings, Startup and Recovery.", tone: .success)
                            pointThisRun = false
                        }
                        agentLostAt = nil
                    } else if agentLostAt == nil {
                        agentLostAt = Date()
                    }
                }

                // A screen reader that stopped.
                if installed, GuestWatchSettings.isOn(GuestWatchSettings.restartReaderKey), tick % 4 == 1, let now = processes {
                    readersSeen.formUnion(now.screenReaders)
                    if now.signedIn && now.screenReaders.isEmpty {
                        missingChecks += 1
                        signedInChecks += 1
                    } else {
                        missingChecks = 0
                        if !now.screenReaders.isEmpty { restartedReader = false }
                    }
                    // Seen before and gone for two checks, about half a minute.
                    // A reader with no start key (Narrator, Orca outside
                    // GNOME) got "starting it again didn't work" with nothing
                    // tried (2026-11-01, audit); turned off on purpose, as a rule.
                    if let reader = readersSeen.sorted().first, missingChecks == 2, Self.screenReaderKeys(reader, gnome: now.gnome) != nil {
                        if !restartedReader, await self.startScreenReader(reader, gnome: now.gnome) {
                            restartedReader = true
                            AVMLog.write("AVM: GuestWatch — \(reader) stopped in \(machine); its shortcut key sent")
                            Announcer.shared.announce("\(reader) stopped in \(machine), so AVM started it again.", tone: .info, routine: true)
                        } else {
                            AVMLog.write("AVM: GuestWatch — \(reader) still not running in \(machine)")
                            Announcer.shared.announce("\(reader) isn't running in \(machine), and starting it again didn't work. \(Self.readerHelp(reader))", tone: .failure)
                        }
                    }
                    // The chosen one never started: a minute after sign-in.
                    if readersSeen.isEmpty, !toldNoReader, signedInChecks == 4, let reader = chosenReaders.first {
                        toldNoReader = true
                        let started = await self.startScreenReader(reader, gnome: false)
                        AVMLog.write("AVM: GuestWatch — no screen reader in \(machine) a minute after sign-in; started=\(started)")
                        Announcer.shared.announce(started
                            ? "No screen reader was running in \(machine), so AVM started \(reader)."
                            : "No screen reader is running in \(machine). \(Self.readerHelp(reader))", tone: .info)
                    }
                }

                // New text on the screen, while no screen reader reads it.
                // An installed machine whose agent never answers may have
                // none at all, and a screen reader AVM can't see: there,
                // only the first 3 minutes (start-up screens) are read.
                let canTell = !installed || agentEverAnswered || Date().timeIntervalSince(started) < 180
                if GuestWatchSettings.isOn(GuestWatchSettings.speakScreenKey), !readerRunning, canTell,
                   (try? await self.sendQMPCommand("screendump", arguments: ["filename": picture.path, "format": "ppm"])) != nil,
                   let source = CGImageSourceCreateWithURL(picture as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                   let thumb = ScreenChange.thumbnail(of: image) {
                    if lastThumb == nil || ScreenChange.isNewScreen(lastThumb!, thumb) {
                        lastThumb = thumb
                        let lines = await Task.detached(priority: .utility) { ScreenText.lines(in: image)?.map(\.text) }.value ?? []
                        let fresh = ScreenChange.newLines(lines, after: said)
                        said = Set(lines.map(ScreenChange.key))
                        if !fresh.isEmpty, self.state == .running {
                            AVMLog.write("AVM: GuestWatch — \(fresh.count) new line(s) on \(machine)'s screen said")
                            if windows && ScreenChange.isStopScreen(lines) {
                                Announcer.shared.announce("\(machine) stopped with an error. On its screen: \(lines.joined(separator: ". "))", tone: .failure, logAs: "\(machine) stopped with an error; its screen was read out.")
                            } else {
                                Announcer.shared.announce("On \(machine)'s screen: \(fresh.joined(separator: ". "))", tone: .info, routine: true, logAs: "\(fresh.count) new line(s) on \(machine)'s screen")
                            }
                        }
                    }
                } else if readerRunning {
                    lastThumb = nil
                    said = []
                }

                // A restore point when updates are waiting: the first look
                // 5 minutes after Start, then every half hour.
                if installed, agentAnswered, GuestWatchSettings.isOn(GuestWatchSettings.pointBeforeUpdatesKey),
                   Date().timeIntervalSince(lastUpdateCheck) > (tick < 100 ? 300 : 1800) {
                    lastUpdateCheck = Date()
                    let outcome = await self.takePointBeforeUpdates(configuration: configuration, runtimeDir: runtimeDir, windows: windows)
                    AVMLog.write("AVM: GuestWatch — before-updates check for \(machine): \(outcome)")
                    switch outcome {
                    case .taken: pointThisRun = true
                    case .devicesSent where !toldDevices:
                        toldDevices = true
                        Announcer.shared.announce("Updates are waiting in \(machine). AVM takes a restore point before updates, but not while devices are sent to it: they'd have to come back to the Mac. To take one yourself, use Restore Points in Settings.", tone: .info)
                    default: break
                    }
                }

                // Not back for 20 minutes after updates.
                if pointThisRun, !toldNoComeBack, let lost = agentLostAt, Date().timeIntervalSince(lost) > 1200 {
                    toldNoComeBack = true
                    AVMLog.write("AVM: GuestWatch — \(machine) hasn't answered for 20 minutes since the restore point before updates")
                    Announcer.shared.announce("\(machine) hasn't come back for 20 minutes since its updates began. If it doesn't start, stop it and go back to the restore point from before the updates: in its Settings, Startup and Recovery, Restore Points.", tone: .failure)
                }
            }
        }
    }

    private nonisolated static func screenReaderKeys(_ reader: String, gnome: Bool) -> [String]? {
        switch reader {
        case "NVDA": return ["ctrl", "alt", "n"]
        case "JAWS": return ["ctrl", "alt", "j"]
        case "Orca" where gnome: return ["meta_l", "alt", "s"]
        default: return nil
        }
    }

    /// The screen reader's own shortcut to start it, pressed in the machine.
    private func startScreenReader(_ reader: String, gnome: Bool) async -> Bool {
        guard let keys = Self.screenReaderKeys(reader, gnome: gnome) else { return false }
        let sent = (try? await sendQMPCommand("send-key", arguments: ["keys": keys.map { ["type": "qcode", "data": $0] }])) != nil
        guard sent else { return false }
        // Started: its process within 20 seconds.
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(5))
            let windows = reader != "Orca"
            if let listing = try? await agentRun(windows ? "tasklist.exe" : "/bin/ps", windows ? ["/fo", "csv", "/nh"] : ["-eo", "comm"], limit: .seconds(20)),
               GuestProcesses.parse(listing, windows: windows).screenReaders.contains(reader) {
                return true
            }
        }
        return false
    }

    /// One of the machine's restore points deleted while it runs, as a
    /// saved state is (QEMU's snapshot-delete; qemu-img can't touch a disk
    /// in use).
    func deleteRunningRestorePoint(_ point: RestorePoint, runtimeDir: URL) async throws {
        let node = try await diskNodeName()
        try await runQMPJob("snapshot-delete", id: "avm-point-delete", arguments: ["tag": point.tag, "devices": [node]])
        RestorePoints.removeFolder(vmDirectory: runtimeDir, tag: point.tag)
    }

    nonisolated static func readerHelp(_ reader: String) -> String {
        switch reader {
        case "NVDA": return "Next: press Control-Alt-N in it, or use Read Screen, Command-Shift-O, to hear its screen."
        case "JAWS": return "Next: press Control-Alt-J in it, or use Read Screen, Command-Shift-O, to hear its screen."
        case "Orca": return "Next: press Super-Alt-S in it, or use Read Screen, Command-Shift-O, to hear its screen."
        default: return "Next: start it from the machine's keyboard, or use Read Screen, Command-Shift-O, to hear its screen."
        }
    }

    enum PointBeforeUpdates { case taken, noUpdates, recent, devicesSent, notPossible }

    /// Marks AVM's own before-updates points, so only those are replaced.
    nonisolated static let beforeUpdatesMarker = "before-updates"

    private func takePointBeforeUpdates(configuration: VMConfiguration, runtimeDir: URL, windows: Bool) async -> PointBeforeUpdates {
        guard canSaveState else { return .notPossible }
        let marker = { (point: RestorePoint) in
            runtimeDir.appendingPathComponent(RestorePoints.folderName).appendingPathComponent(point.tag).appendingPathComponent(Self.beforeUpdatesMarker)
        }
        let existing = (try? await RestorePoints.list(vmDirectory: runtimeDir)) ?? []
        let ours = existing.filter { FileManager.default.fileExists(atPath: marker($0).path) }
        if let newest = ours.first, Date().timeIntervalSince(newest.date) < 20 * 3600 { return .recent }
        // Waiting updates: Windows Update's own search, or apt or dnf.
        let count: String
        if windows {
            count = (try? await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
                "try { (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0').Updates.Count } catch { 0 }"],
                limit: .seconds(180))) ?? "0"
        } else {
            count = (try? await agentRun("/bin/sh", ["-c",
                "if command -v apt >/dev/null; then apt list --upgradable 2>/dev/null | grep -c upgradable; elif command -v dnf >/dev/null; then dnf -q check-update 2>/dev/null | grep -c '^[A-Za-z0-9]'; elif command -v zypper >/dev/null; then zypper -q lu 2>/dev/null | grep -c '^v '; else echo 0; fi"],
                limit: .seconds(180))) ?? "0"
        }
        guard let waiting = Int(count.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last ?? ""), waiting > 0 else {
            return .noUpdates
        }
        if !USBRedirectController.shared.devices(for: self).isEmpty || BluetoothDevices.shared.hasDevices(in: self) {
            return .devicesSent
        }
        guard state == .running else { return .notPossible }
        let label = "Before updates, \(Date().formatted(date: .abbreviated, time: .shortened))"
        do {
            let point = try await createRunningRestorePoint(label: label)
            FileManager.default.createFile(atPath: marker(point).path, contents: nil)
            for old in ours {
                try? await deleteRunningRestorePoint(old, runtimeDir: runtimeDir)
            }
            AVMLog.write("AVM: GuestWatch — restore point before \(waiting) update(s) taken")
            Announcer.shared.announce("\(waiting == 1 ? "An update is" : "\(waiting) updates are") waiting in \(configuration.name), so AVM took a restore point first. If the updates cause trouble, go back to it in Settings, Startup and Recovery.", tone: .info)
            return .taken
        } catch {
            AVMLog.write("AVM: GuestWatch — restore point before updates failed: \(error.localizedDescription)")
            return .notPossible
        }
    }
}
