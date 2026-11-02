// ScreenReaderSetup.swift
// AVM — Accessible Virtual Machine
//
// A person's screen reader setup, carried between machines (2026-11-01, the
// user's request): every new machine started from NVDA's or Orca's defaults,
// to be set up again by ear. Virtual Machine > Save Screen Reader Setup keeps a
// copy on the Mac of NVDA's settings folder, add-ons included, or Orca's;
// Apply puts it in another machine, keeping what was there beside it. AVM can
// also put it in each machine it installs (Settings, Watching Machines).
//
// The copy is a guest's archive: it's only ever unpacked in a guest, never on
// the Mac, and on Linux as the signed-in user. JAWS isn't carried: its
// settings are tied to its licence and version.

import Foundation

extension VMManager {

    /// Where saved setups live, one per screen reader.
    nonisolated static func screenReaderSetupFile(windows: Bool) throws -> URL {
        let folder = try AVMPaths.supportDirectory().appendingPathComponent("screen-reader-setups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(windows ? "nvda.zip" : "orca.tgz")
    }

    /// The largest setup kept: a settings folder, not a machine's files.
    nonisolated private static let largestSetup = 200 * 1024 * 1024

    /// A file from the guest onto the Mac, through its agent, up to `limit`.
    func copyFromGuest(_ path: String, to file: URL, limit: Int) async throws {
        guard let handle = try await agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "rb"]]) as? Int else {
            throw AVMError.qmpCommandFailed("couldn't open \(path)")
        }
        var data = Data()
        do {
            while true {
                let reply = try await agentCall(["execute": "guest-file-read", "arguments": ["handle": handle, "count": 1 << 20]]) as? [String: Any]
                if let chunk = (reply?["buf-b64"] as? String).flatMap({ Data(base64Encoded: $0) }) { data.append(chunk) }
                guard data.count <= limit else { throw AVMError.refused("It's larger than AVM keeps.") }
                if reply?["eof"] as? Bool == true || reply == nil { break }
            }
        } catch {
            _ = try? await agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
            throw error
        }
        _ = try await agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
        try data.write(to: file, options: .atomic)
    }

    /// The guest's script for the signed-in user's folder, printing AVM-OK.
    private var signedInUser: String {
        #"(Get-CimInstance Win32_ComputerSystem).UserName.Split('\')[-1]"#
    }

    /// Virtual Machine > Save Screen Reader Setup.
    func saveScreenReaderSetup() async {
        let machine = machineName
        let windows = runningGuestOS == .windows
        let name = windows ? "NVDA" : "Orca"
        do {
            let inGuest = windows ? #"C:\ProgramData\AVM\sr-setup.zip"# : "/tmp/avm-sr-setup.tgz"
            let out = windows
                ? try await agentRun("powershell.exe", ["-NoProfile", "-Command", """
                    $u = \(signedInUser); $d = "C:\\Users\\$u\\AppData\\Roaming\\nvda"
                    if (Test-Path "$d\\nvda.ini") {
                      New-Item -ItemType Directory -Force C:\\ProgramData\\AVM | Out-Null
                      $t = "C:\\ProgramData\\AVM\\sr-copy"; Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
                      robocopy $d $t /E /XF *.log /XD updates | Out-Null
                      Compress-Archive -Force -Path "$t\\*" -DestinationPath '\(inGuest)'
                      Remove-Item -Recurse -Force $t; 'AVM-OK'
                    } else { 'AVM-NONE' }
                    """], limit: .seconds(180))
                : try await agentRun("/bin/sh", ["-c", """
                    U=$(getent passwd 1000 | cut -d: -f1); D=/home/$U/.local/share
                    if [ -d "$D/orca" ]; then tar czf \(inGuest) -C "$D" orca && echo AVM-OK; else echo AVM-NONE; fi
                    """], limit: .seconds(120))
            guard out.contains("AVM-OK") else {
                Announcer.shared.announce("\(machine) has no \(name) settings to save. Next: sign in to \(machine), change a \(name) setting, then try again.", tone: .failure)
                return
            }
            let file = try Self.screenReaderSetupFile(windows: windows)
            try await copyFromGuest(inGuest, to: file, limit: Self.largestSetup)
            AVMLog.write("AVM: Screen reader setup — \(name)'s saved from \(machine)")
            Announcer.shared.announce("\(name)'s setup is saved from \(machine). Next: in another machine, choose Virtual Machine, Apply Saved Screen Reader Setup.", tone: .success)
        } catch {
            AVMLog.write("AVM: Screen reader setup — not saved: \(error.localizedDescription)")
            Announcer.shared.announce("\(name)'s setup couldn't be saved from \(machine). Reason: \(error.localizedDescription) Next: make sure \(machine) has finished starting, then try again.", tone: .failure)
        }
    }

    /// Whether there's a saved setup for this kind of machine.
    var hasSavedScreenReaderSetup: Bool {
        guard runningGuestOS != .macOS, let file = try? Self.screenReaderSetupFile(windows: runningGuestOS == .windows) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Virtual Machine > Apply Saved Screen Reader Setup, and each new machine
    /// when that's chosen. What was there stays beside it, as nvda-before-avm
    /// or orca-before-avm. The running reader stops first, or it would write
    /// its old settings over these as it quits; GuestWatch then starts it.
    @discardableResult
    func applyScreenReaderSetup() async -> Bool {
        let machine = machineName
        let windows = runningGuestOS == .windows
        let name = windows ? "NVDA" : "Orca"
        do {
            let file = try Self.screenReaderSetupFile(windows: windows)
            guard FileManager.default.fileExists(atPath: file.path) else {
                Announcer.shared.announce("No \(name) setup is saved yet. Next: in a machine set up as you like it, choose Virtual Machine, Save Screen Reader Setup.", tone: .failure)
                return false
            }
            let inGuest = windows ? #"C:\ProgramData\AVM\sr-setup.zip"# : "/tmp/avm-sr-setup.tgz"
            if windows {
                _ = try await agentRun("cmd.exe", ["/c", #"if not exist C:\ProgramData\AVM mkdir C:\ProgramData\AVM"#], limit: .seconds(30))
            }
            try await copyToGuest(file, to: inGuest)
            let out = windows
                ? try await agentRun("powershell.exe", ["-NoProfile", "-Command", """
                    $u = \(signedInUser); $d = "C:\\Users\\$u\\AppData\\Roaming\\nvda"
                    Stop-Process -Name nvda -Force -ErrorAction SilentlyContinue; Start-Sleep 2
                    if (Test-Path $d) {
                      Remove-Item -Recurse -Force "$d-before-avm" -ErrorAction SilentlyContinue
                      Move-Item $d "$d-before-avm"
                    }
                    Expand-Archive -Force -Path '\(inGuest)' -DestinationPath $d
                    Remove-Item -Force '\(inGuest)'
                    if (Test-Path "$d\\nvda.ini") { 'AVM-OK' }
                    """], limit: .seconds(180))
                : try await agentRun("/bin/sh", ["-c", """
                    U=$(getent passwd 1000 | cut -d: -f1); D=/home/$U/.local/share
                    pkill -x orca; sleep 2
                    chmod 644 \(inGuest)
                    runuser -u "$U" -- sh -c "mkdir -p '$D' && rm -rf '$D/orca-before-avm'; [ -d '$D/orca' ] && mv '$D/orca' '$D/orca-before-avm'; tar xzf \(inGuest) -C '$D' --no-same-owner"
                    rm -f \(inGuest)
                    [ -d "$D/orca" ] && echo AVM-OK
                    """], limit: .seconds(120))
            guard out.contains("AVM-OK") else { throw AVMError.qmpCommandFailed("it didn't unpack") }
            AVMLog.write("AVM: Screen reader setup — \(name)'s applied in \(machine)")
            Announcer.shared.announce("Your \(name) setup is in \(machine) now, and AVM is starting \(name) again.", tone: .success)
            return true
        } catch {
            AVMLog.write("AVM: Screen reader setup — not applied: \(error.localizedDescription)")
            Announcer.shared.announce("Your \(name) setup couldn't be put in \(machine). Reason: \(error.localizedDescription) Next: make sure someone is signed in to \(machine), then try again.", tone: .failure)
            return false
        }
    }
}
