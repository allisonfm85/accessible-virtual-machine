// SaveResumeTestJob.swift
// AVM — Accessible Virtual Machine
//
// Save and resume, tested with no one at the screen (2026-10-27), on a
// machine kept by Tools/test-windows-install.sh or test-linux-install.sh
// (--keep), through AVM's own code (VMManager.startVM, saveStateAndStop,
// and the resume in startVM):
//
//   AVM.app/Contents/MacOS/AVM --test-save-resume --vm <folder> [--guest windows|debian|ubuntu|fedora] [--convert]
//   AVM.app/Contents/MacOS/AVM --test-microphone --vm <folder> [--guest ...]
//
// --test-microphone (Linux): starts the machine with the Mac's microphone shared,
// records three seconds in the guest, and says how loud the loudest moment
// was (a working microphone always hears something; a blocked one gives
// exact silence). macOS asks for microphone permission the first time.
//
// --convert: the machine is an older one on NVMe; first it's moved to the
// virtio disk as Settings' Turn On Save with Open Apps does (a Start that
// gets it ready, then a first Start on the virtio disk), then tested.
//
// 1. starts the machine and waits for its guest agent;
// 2. reads the guest's boot ID (Windows: its last boot time);
// 3. saves it, and checks it stopped and says it's saved;
// 4. starts it again, and checks that it carried on (same boot ID), that
//    its clock is the Mac's again, and that the saved state is gone;
// 5. shuts it down.
// Prints each step with how long it took; exits 0 if every check passed.

import Foundation

@MainActor
enum SaveResumeTestJob {

    static let flag = "--test-save-resume"

    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) || arguments.contains("--test-microphone") else { return }
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        guard let folder = value("--vm") else {
            print("Usage: AVM \(flag) --vm <folder> [--guest windows|debian|ubuntu|fedora]")
            exit(64)
        }
        AVMLog.useTestLogFolder()
        let guest = GuestOS(rawValue: value("--guest") ?? "windows") ?? .windows
        Task { @MainActor in
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            if arguments.contains("--test-microphone") {
                let heard = await microphone(folder: folderURL, guest: guest)
                print(heard ? "PASSED" : "FAILED"); exit(heard ? 0 : 1)
            }
            if arguments.contains("--convert"), !(await convert(folder: folderURL, guest: guest)) {
                print("FAILED"); exit(1)
            }
            let ok = await run(folder: folderURL, guest: guest)
            print(ok ? "PASSED" : "FAILED")
            exit(ok ? 0 : 1)
        }
    }

    private static var ok = true
    private static func check(_ what: String, _ passed: Bool) {
        print("   \(passed ? "yes" : "NO ")  \(what)")
        if !passed { ok = false }
    }

    private static func configuration(folder: URL, guest: GuestOS) -> VMConfiguration {
        var configuration = VMConfiguration(
            name: "Save test", cpuCount: 4, ramSizeGB: guest == .windows ? 8 : 4, diskSizeGB: 64,
            diskImagePath: folder.appendingPathComponent("disk.qcow2").path,
            // Any install disc: AVM reads the "installed" marker only for a
            // machine that has one (checkInstallCompleteMarker).
            installISOPath: folder.appendingPathComponent("install-avm.iso").path,
            guestOSName: guest == .windows ? nil : guest.rawValue,
            storageFolderPath: folder.path,
            secureBoot: guest == .windows ? true : nil)
        configuration.diskBus = "virtio"
        return configuration
    }

    private static func convert(folder: URL, guest: GuestOS) async -> Bool {
        var configuration = configuration(folder: folder, guest: guest)
        configuration.diskBus = nil
        configuration.diskBusSwitch = "pending"
        print("== Getting the NVMe machine ready for the virtio disk")
        var manager = VMManager()
        var started = Date()
        guard await start(manager, configuration) else { return false }
        for _ in 0..<900 where manager.diskSwitchResult == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        print(String(format: "   %@ after %.0f s", manager.diskSwitchResult ?? "nothing", Date().timeIntervalSince(started)))
        check("it got ready", manager.diskSwitchResult == "ready")
        await shutDown(manager)
        guard manager.diskSwitchResult == "ready" else { return false }

        print("== Its first Start on the virtio disk")
        configuration.diskBus = "virtio"
        configuration.diskBusSwitch = "firstBoot"
        manager = VMManager()
        started = Date()
        guard await start(manager, configuration) else { return false }
        for _ in 0..<900 where manager.diskSwitchResult == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        print(String(format: "   %@ after %.0f s", manager.diskSwitchResult ?? "nothing", Date().timeIntervalSince(started)))
        check("it came up on the virtio disk", manager.diskSwitchResult == "switched")
        await shutDown(manager)
        return manager.diskSwitchResult == "switched"
    }

    private static func microphone(folder: URL, guest: GuestOS) async -> Bool {
        var configuration = configuration(folder: folder, guest: guest)
        configuration.shareMicrophone = true
        print("== Starting the machine with the microphone shared")
        let manager = VMManager()
        guard await start(manager, configuration) else { return false }
        guard let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the guest agent answers", false); await shutDown(manager); return false
        }
        try? await Task.sleep(for: .seconds(20))
        print("== Recording three seconds in the guest")
        guard guest != .windows else {
            // Windows has no recorder the guest agent can drive; this test
            // covers Linux, and QEMU's side is the same for both.
            print("   (Linux only for now)"); await shutDown(manager); return false
        }
        let peak = await exec(agent, program: "/bin/sh", args: ["-c", """
                U=$(id -u avmtest 2>/dev/null || ls /run/user | head -1)
                N=$(getent passwd "$U" | cut -d: -f1)
                runuser -u "$N" -- env XDG_RUNTIME_DIR=/run/user/$U timeout 3 pw-record --rate 48000 --channels 1 --format s16 /tmp/avm-mic.wav
                python3 -c "import sys,struct,wave; w=wave.open('/tmp/avm-mic.wav'); d=w.readframes(w.getnframes()); s=struct.unpack('<%dh'%(len(d)//2), d); print('frames', len(s), 'peak', max(abs(x) for x in s) if s else 0)"
                """])
        print("   \(peak ?? "no answer")")
        let words = (peak ?? "").split(separator: " ")
        let level = words.firstIndex(of: "peak").flatMap { words.indices.contains($0 + 1) ? Int(words[$0 + 1]) : nil } ?? 0
        let frames = words.firstIndex(of: "frames").flatMap { words.indices.contains($0 + 1) ? Int(words[$0 + 1]) : nil } ?? 0
        check("the guest recorded", frames > 48_000)
        check("the recording isn't silence (the Mac's microphone reached it)", level > 0)
        await shutDown(manager)
        return ok
    }

    private static func run(folder: URL, guest: GuestOS) async -> Bool {
        let configuration = configuration(folder: folder, guest: guest)

        print("== Starting the machine")
        var manager = VMManager()
        guard await start(manager, configuration) else { return false }
        guard let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the guest agent answers", false); await shutDown(manager); return false
        }
        let bootBefore = await bootID(agent, guest: guest)
        print("   boot: \(bootBefore ?? "unknown")")
        try? await Task.sleep(for: .seconds(20))

        print("== Saving it")
        var started = Date()
        let saved = await manager.saveStateAndStop()
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        check("it was saved", saved)
        check("it stopped", manager.state == .stopped)
        check("the machine list says it's saved", QEMUSavedState.looksSaved(configuration))
        guard saved else { await shutDown(manager); return false }

        print("== Starting it again")
        manager = VMManager()
        started = Date()
        guard await start(manager, configuration) else { return false }
        guard let agent2 = manager.guestAgentSocketPath, await waitForAgent(agent2, seconds: 60) else {
            check("the guest agent answers after the resume", false); await shutDown(manager); return false
        }
        print(String(format: "   running, agent answering, after %.1f s", Date().timeIntervalSince(started)))
        let bootAfter = await bootID(agent2, guest: guest)
        print("   boot: \(bootAfter ?? "unknown")")
        check("it carried on rather than starting again (same boot)", bootBefore != nil && bootBefore == bootAfter)
        try? await Task.sleep(for: .seconds(4))   // the clock is set 2 s after the resume
        if let guestNow = await guestClock(agent2, guest: guest) {
            let off = abs(guestNow - Date().timeIntervalSince1970)
            print(String(format: "   guest clock off by %.0f s", off))
            check("its clock is the Mac's again", off < 10)
        } else {
            check("its clock could be read", false)
        }
        let tags = await QEMUSavedStateProbe.tags(configuration)
        check("the saved state is gone from the disk", !tags.contains(QEMUSavedState.tag))
        check("the machine list no longer says it's saved", !QEMUSavedState.looksSaved(configuration))

        print("== A restore point while it runs, with its memory")
        started = Date()
        var point: RestorePoint?
        do {
            point = try await manager.createRunningRestorePoint(label: "Test point")
            print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        } catch {
            print("   \(error.localizedDescription)")
        }
        check("the restore point was taken", point != nil)
        check("the machine kept running", manager.state == .running)
        let marker = guest == .windows ? "C:\\avm-after-point.txt" : "/var/tmp/avm-after-point"
        _ = guest == .windows
            ? await exec(agent2, program: "cmd.exe", args: ["/c", "echo after>\(marker)"])
            : await exec(agent2, program: "/bin/touch", args: [marker])
        check("a file written after the point is there", await fileExists(agent2, marker, guest: guest))

        print("== Shutting it down and putting the restore point back")
        await shutDown(manager)
        if let point {
            do {
                try await RestorePoints.restore(point, vmDirectory: folder, currentSecureBoot: configuration.usesSecureBoot)
                check("it was restored", true)
            } catch {
                check("it was restored (\(error.localizedDescription))", false)
            }
            manager = VMManager()
            started = Date()
            guard await start(manager, configuration) else { return false }
            guard let agent3 = manager.guestAgentSocketPath, await waitForAgent(agent3, seconds: 60) else {
                check("the guest agent answers after the restore", false); await shutDown(manager); return false
            }
            print(String(format: "   running, agent answering, after %.1f s", Date().timeIntervalSince(started)))
            check("it carried on from the point (same boot)", await bootID(agent3, guest: guest) == bootBefore)
            check("the file written after the point is gone", !(await fileExists(agent3, marker, guest: guest)))
            print("== Shutting it down")
            await shutDown(manager)
            let points = (try? await RestorePoints.list(vmDirectory: folder)) ?? []
            check("the restore point is still there, marked with open apps", points.contains { $0.tag == point.tag && $0.withMemory })
            try? await RestorePoints.delete(point, vmDirectory: folder)
        }
        return ok
    }

    private static func fileExists(_ path: String, _ file: String, guest: GuestOS) async -> Bool {
        let out = guest == .windows
            ? await exec(path, program: "cmd.exe", args: ["/c", "if exist \(file) (echo yes) else (echo no)"])
            : await exec(path, program: "/bin/sh", args: ["-c", "[ -e \(file) ] && echo yes || echo no"])
        return out == "yes"
    }

    private static func start(_ manager: VMManager, _ configuration: VMConfiguration) async -> Bool {
        // QEMU's exit reaches the manager through here, as a VMSession
        // sets it in the app.
        VMManager.shared = manager
        do {
            try await manager.startVM(configuration: configuration)
        } catch {
            check("it started (\(error.localizedDescription))", false)
            return false
        }
        check("it started", manager.state == .running)
        return manager.state == .running
    }

    private static func shutDown(_ manager: VMManager) async {
        try? await manager.stopVM()
        for _ in 0..<360 where manager.state != .stopped {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if manager.state != .stopped { manager.forceStopVM() }
        print("   stopped")
    }

    // MARK: Guest agent

    private static func waitForAgent(_ path: String, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if let replies = try? await Task.detached(operation: { try GuestAgent.run([#"{"execute":"guest-ping"}"#], socketPath: path) }).value,
               replies.first?.contains(#""return""#) == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Runs a program in the guest and returns what it printed.
    private static func exec(_ path: String, program: String, args: [String]) async -> String? {
        let start: [String: Any] = ["execute": "guest-exec",
                                    "arguments": ["path": program, "arg": args, "capture-output": true]]
        guard let data = try? JSONSerialization.data(withJSONObject: start),
              let line = String(data: data, encoding: .utf8),
              let reply = try? await Task.detached(operation: { try GuestAgent.run([line], socketPath: path, timeout: 10) }).value.first,
              let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let pid = (json["return"] as? [String: Any])?["pid"] as? Int else { return nil }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(500))
            let status = #"{"execute":"guest-exec-status","arguments":{"pid":\#(pid)}}"#
            guard let reply = try? await Task.detached(operation: { try GuestAgent.run([status], socketPath: path, timeout: 10) }).value.first,
                  let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                  let result = json["return"] as? [String: Any] else { continue }
            if result["exited"] as? Bool == true {
                let out = (result["out-data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func bootID(_ path: String, guest: GuestOS) async -> String? {
        if guest == .windows {
            return await exec(path, program: "powershell.exe",
                              args: ["-NoProfile", "-Command", "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')"])
        }
        return await exec(path, program: "/bin/cat", args: ["/proc/sys/kernel/random/boot_id"])
    }

    private static func guestClock(_ path: String, guest: GuestOS) async -> TimeInterval? {
        let out = guest == .windows
            ? await exec(path, program: "powershell.exe", args: ["-NoProfile", "-Command", "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"])
            : await exec(path, program: "/bin/date", args: ["+%s"])
        return out.flatMap { TimeInterval($0) }
    }
}

/// The disk's snapshot names, for the test only.
enum QEMUSavedStateProbe {
    static func tags(_ configuration: VMConfiguration) async -> [String] {
        await QEMUSavedState.snapshotTags(disk: URL(fileURLWithPath: configuration.diskImagePath))
    }
}
