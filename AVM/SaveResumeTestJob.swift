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
//   AVM.app/Contents/MacOS/AVM --test-two-machines --vm <folder> --guest <os> --vm2 <folder> --guest2 <os>
//   AVM.app/Contents/MacOS/AVM --test-duplicate --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-send-file --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-linux-share --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-ctl --vm <folder> --guest <os>
//
// --test-ctl: a control socket in a temporary AVM folder, and real
// `AVM ctl` commands against it: list, start --no-window, status,
// send-file, save, start (carries on), stop.
//
// --test-linux-share: a Mac folder served over SPICE (AVM --serve-folder,
// as a machine's window serves it) is mounted at the user's sign-in by
// /usr/local/lib/avm/mount-mac-folder.sh, and a file in it reads back in
// the guest; a file written in the guest appears on the Mac.
//
// --test-send-file: sends a 3 MB file of random bytes (three pieces) to
// the machine's Downloads, twice, and checks both arrive whole, the second
// under a new name.
//
// --test-duplicate: duplicates the machine as Duplicate… does, in a
// temporary AVM folder (the user's machine list is never opened), then
// runs the original and the copy at once, and deletes the copy.
//
// --test-two-machines: both machines run at once through MachineSessions
// (with no windows): each answers, each is the current machine in turn,
// shutting the first down leaves the second running and current, and the
// second saves and carries on.
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
import CommonCrypto

@MainActor
enum SaveResumeTestJob {

    static let flag = "--test-save-resume"

    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) || arguments.contains("--test-microphone") || arguments.contains("--test-two-machines")
                || arguments.contains("--test-duplicate") || arguments.contains("--test-send-file")
                || arguments.contains("--test-linux-share") || arguments.contains("--test-ctl") else { return }
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
            if arguments.contains("--test-two-machines"), let second = value("--vm2") {
                let guest2 = GuestOS(rawValue: value("--guest2") ?? "windows") ?? .windows
                let passed = await twoMachines(folderURL, guest, URL(fileURLWithPath: second, isDirectory: true), guest2)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-ctl") {
                let passed = await controlTest(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-linux-share") {
                let passed = await linuxShare(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-send-file") {
                let passed = await sendFile(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-duplicate") {
                let passed = await duplicate(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
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

    /// Runs `AVM ctl …` as the user would, against this test's socket.
    private static func ctl(_ words: [String], support: URL) async -> (ok: Bool, out: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["ctl"] + words
            var env = ProcessInfo.processInfo.environment
            env["AVM_TEST_SUPPORT_DIR"] = support.path
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    private static func controlTest(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("avm-ctl-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AVMPaths.supportDirectoryOverride = support
        defer { try? FileManager.default.removeItem(at: support) }
        let store = VMStore()
        var config = configuration(folder: folder, guest: guest)
        config.name = "Ctl Test"
        store.save(config)
        ControlServer.shared.start()
        func run(_ words: [String]) async -> (ok: Bool, out: String) {
            let result = await ctl(words, support: support)
            print("   $ avmctl \(words.joined(separator: " "))\n\(result.out.split(whereSeparator: \.isNewline).map { "     " + $0 }.joined(separator: "\n"))")
            return result
        }
        print("== avmctl")
        let list = await run(["list"])
        check("list names it, shut down", list.ok && list.out.contains("Ctl Test") && list.out.contains("shut down"))
        let start = await run(["start", "ctl test", "--no-window"])
        check("start (any case, no window) works", start.ok)
        guard let session = MachineSessions.shared.session(for: config.id) else { check("it's running", false); return false }
        for _ in 0..<600 where session.vmState != .running { try? await Task.sleep(for: .milliseconds(500)) }
        guard let agent = session.manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("its guest agent answers", false); session.forceStop(); return false
        }
        try? await Task.sleep(for: .seconds(15))
        let status = await run(["status", "Ctl Test"])
        check("status says running", status.ok && status.out.contains("running"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avmctl note.txt")
        try? "sent by avmctl\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let send = await run(["send-file", "Ctl Test", file.path])
        check("send-file works", send.ok)
        let save = await run(["save", "Ctl Test"])
        check("save works", save.ok)
        for _ in 0..<40 where MachineSessions.shared.session(for: config.id) != nil { try? await Task.sleep(for: .milliseconds(250)) }
        let saved = await run(["status", "Ctl Test"])
        check("status says saved", saved.out.contains("saved"))
        let again = await run(["start", "Ctl Test", "--no-window"])
        check("start carries on", again.ok)
        guard let session2 = MachineSessions.shared.session(for: config.id) else { return false }
        for _ in 0..<120 where session2.vmState != .running { try? await Task.sleep(for: .milliseconds(500)) }
        let landed = guest == .windows ? nil : await exec(session2.manager.guestAgentSocketPath ?? "", program: "/bin/sh",
                                                         args: ["-c", "cat /home/*/Downloads/'avmctl note.txt'; rm -f /home/*/Downloads/'avmctl note.txt'"])
        if guest != .windows { check("the sent file is in Downloads", landed?.contains("sent by avmctl") == true) }
        let stop = await run(["stop", "Ctl Test"])
        check("stop works", stop.ok)
        for _ in 0..<240 where MachineSessions.shared.session(for: config.id) != nil { try? await Task.sleep(for: .milliseconds(500)) }
        check("it shut down", MachineSessions.shared.session(for: config.id) == nil)
        let unknown = await run(["status", "No Such Machine"])
        check("an unknown machine is refused", !unknown.ok && unknown.out.contains("no virtual machine called"))
        return ok
    }

    private static func linuxShare(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("avm-share-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shared) }
        try? "from the Mac\n".write(to: shared.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let manager = VMManager()
        guard await start(manager, configuration(folder: folder, guest: guest)),
              let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the machine started and answers", false); await shutDown(manager); return false
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        server.arguments = ["--serve-folder", shared.path, "--spice", manager.spiceSocketPath]
        server.standardOutput = FileHandle.nullDevice
        try? server.run()
        defer { server.terminate() }
        try? await Task.sleep(for: .seconds(25))
        print("== Mounting it as the user signs in would, and reading it")
        let out = await exec(agent, program: "/bin/sh", args: ["-c", """
            U=$(getent passwd 1000 | cut -d: -f1); UID_=1000
            [ -x /usr/local/lib/avm/mount-mac-folder.sh ] && echo "script there" || echo "script missing"
            [ -e /etc/xdg/autostart/avm-mac-folder.desktop ] && echo "autostart there" || echo "autostart missing"
            systemctl is-active spice-webdavd 2>&1 | sed 's/^/webdavd: /'
            ss -ltn 2>/dev/null | grep -q ':9843' && echo "listening on 9843" || echo "not listening on 9843"
            runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus HOME=/home/$U /bin/bash /usr/local/lib/avm/mount-mac-folder.sh
            runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus gio mount dav://localhost:9843/ 2>&1 | sed 's/^/gio: /'
            G="runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus"
            $G gio cat dav://localhost:9843/hello.txt 2>&1
            echo "from the guest" | $G gio save dav://localhost:9843/back.txt 2>&1 && echo "wrote back"
            grep -c 'Mac shared folder' /home/$U/.config/gtk-3.0/bookmarks
            """])
        print((out ?? "no answer").split(whereSeparator: \.isNewline).map { "   " + $0 }.joined(separator: "\n"))
        check("the sign-in script is installed", out?.contains("script there") == true && out?.contains("autostart there") == true)
        check("the Mac's file reads back in the guest", out?.contains("from the Mac") == true)
        try? await Task.sleep(for: .seconds(2))
        check("a file written in the guest is on the Mac", (try? String(contentsOf: shared.appendingPathComponent("back.txt"), encoding: .utf8))?.contains("from the guest") == true)
        check("it's bookmarked in Files", out?.split(whereSeparator: \.isNewline).last == "1")
        await shutDown(manager)
        return ok
    }

    private static func sendFile(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avm send test.bin")
        var bytes = Data(count: 3 * 1_048_576 + 12345)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sum = bytes.withUnsafeBytes { raw -> String in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let manager = VMManager()
        guard await start(manager, configuration(folder: folder, guest: guest)),
              let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the machine started and answers", false); await shutDown(manager); return false
        }
        try? await Task.sleep(for: .seconds(20))
        print("== Sending the file twice")
        let started = Date()
        await manager.sendFile(file)
        await manager.sendFile(file)
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        let sums = guest == .windows
            ? await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command",
                "Get-ChildItem -Path C:\\Users\\*\\Downloads\\'avm send test*' | ForEach-Object { (Get-FileHash $_.FullName).Hash.ToLower() + ' ' + $_.Name; Remove-Item $_.FullName }"])
            : await exec(agent, program: "/bin/sh", args: ["-c", "cd /home/*/Downloads && for f in avm\\ send\\ test*; do echo \"$(sha256sum \"$f\" | cut -c1-64) $f $(stat -c %U \"$f\")\"; rm -f \"$f\"; done"])
        print("   \(sums ?? "no answer")")
        let lines = (sums ?? "").split(whereSeparator: \.isNewline)
        check("two copies arrived", lines.count == 2)
        check("both are whole", lines.allSatisfy { $0.hasPrefix(sum) })
        check("the second has its own name", lines.contains { $0.contains("avm send test 2.bin") })
        if guest != .windows {
            check("they belong to the user, not root", lines.allSatisfy { !$0.hasSuffix(" root") })
        }
        await shutDown(manager)
        return ok
    }

    private static func duplicate(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("avm-duplicate-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AVMPaths.supportDirectoryOverride = support
        defer { try? FileManager.default.removeItem(at: support) }
        let store = VMStore()
        var original = configuration(folder: folder, guest: guest)
        original.name = "Original"
        store.save(original)

        print("== Duplicating")
        let started = Date()
        MachineArchiveController.shared.duplicate(original, isRunning: false, into: store, name: "The copy")
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<1200 where MachineArchiveController.shared.activity != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        guard let copy = store.configurations.first(where: { $0.name == "The copy" }) else {
            check("the copy is in the list", false); return false
        }
        check("the copy is in the list, with its own id", copy.id != original.id)
        let copyFolder = try? copy.directoryURL()
        check("its folder is its own", copyFolder.map { $0.standardizedFileURL != folder.standardizedFileURL } ?? false)
        check("it has a disk", FileManager.default.fileExists(atPath: copy.diskImagePath))

        print("== Running the original and the copy at once")
        let machines = MachineSessions.shared
        let a = machines.start(original, vmStore: nil, focusLock: nil)
        let b = machines.start(copy, vmStore: nil, focusLock: nil)
        for _ in 0..<600 where !(a.vmState == .running && b.vmState == .running) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both are running", a.vmState == .running && b.vmState == .running)
        if let agentA = a.manager.guestAgentSocketPath, let agentB = b.manager.guestAgentSocketPath {
            check("the original answers", await waitForAgent(agentA, seconds: 300))
            check("the copy answers", await waitForAgent(agentB, seconds: 300))
        }
        print("== Shutting both down, and deleting the copy")
        try? await a.stopGracefully()
        try? await b.stopGracefully()
        for _ in 0..<60 where !machines.sessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both ended", machines.sessions.isEmpty)
        if let copyFolder { try? FileManager.default.removeItem(at: copyFolder) }
        return ok
    }

    private static func twoMachines(_ folderA: URL, _ guestA: GuestOS, _ folderB: URL, _ guestB: GuestOS) async -> Bool {
        var configA = configuration(folder: folderA, guest: guestA)
        configA.name = "Machine A"
        var configB = configuration(folder: folderB, guest: guestB)
        configB.name = "Machine B"
        let machines = MachineSessions.shared
        print("== Starting two machines at once")
        let a = machines.start(configA, vmStore: nil, focusLock: nil)
        let b = machines.start(configB, vmStore: nil, focusLock: nil)
        for _ in 0..<600 where !(a.vmState == .running && b.vmState == .running) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both are running", a.vmState == .running && b.vmState == .running)
        check("two sessions", machines.sessions.count == 2)
        guard let agentA = a.manager.guestAgentSocketPath, let agentB = b.manager.guestAgentSocketPath else { return false }
        check("A's guest agent answers", await waitForAgent(agentA, seconds: 300))
        check("B's guest agent answers", await waitForAgent(agentB, seconds: 300))
        check("B, started last, is current", machines.currentID == configB.id && VMManager.shared === b.manager)
        machines.makeCurrent(configA.id)
        check("A becomes current", machines.currentID == configA.id && VMManager.shared === a.manager && VMActivity.shared.state == .running)

        print("== Shutting A down while B runs")
        let started = Date()
        try? await a.stopGracefully()
        for _ in 0..<40 where machines.session(for: configA.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print(String(format: "   A shut down in %.0f s", Date().timeIntervalSince(started)))
        check("A's session ended", machines.session(for: configA.id) == nil)
        check("B is still running", b.vmState == .running)
        check("B's guest agent still answers", await waitForAgent(agentB, seconds: 10))
        check("B became current", machines.currentID == configB.id && VMManager.shared === b.manager)

        print("== Saving B, then starting it again")
        check("B was saved", await b.saveAndStop())
        for _ in 0..<40 where machines.session(for: configB.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        check("no sessions left", machines.sessions.isEmpty && VMManager.shared == nil)
        check("the menus see nothing running", VMActivity.shared.state == .stopped)
        let b2 = machines.start(configB, vmStore: nil, focusLock: nil)
        for _ in 0..<120 where b2.vmState != .running {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("B carried on", b2.vmState == .running)
        if let agent = b2.manager.guestAgentSocketPath {
            check("B's guest agent answers after carrying on", await waitForAgent(agent, seconds: 60))
        }
        print("== Shutting B down")
        try? await b2.stopGracefully()
        for _ in 0..<40 where machines.session(for: configB.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        check("everything ended", machines.sessions.isEmpty)
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
