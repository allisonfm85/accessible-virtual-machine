// GuestStatus.swift
// AVM — Accessible Virtual Machine
//
// Speak Updates and Disk (2026-10-30, the user's request): how full the
// machine's disk is and how many updates are waiting, asked of the guest
// through its agent and said in one sentence, so nobody has to open
// Settings or Windows Update and find their way around it to know.
//   Windows: drive C through PowerShell; waiting updates from Windows
//   Update's own search (it can take a minute); a restart waiting for an
//   update to finish.
//   Linux: the root file system; upgradable packages from apt or dnf.

import Foundation

extension VMManager {

    /// The sentence to say, or why there isn't one.
    func updatesAndDisk() async -> String {
        guard case .running = state else { return "\(machineName) isn't running." }
        let name = machineName
        do {
            if runningGuestOS?.isLinux == true {
                let disk = try await agentRun("/bin/sh", ["-c", "df -P / | tail -1"], limit: .seconds(20))
                let fields = disk.split(whereSeparator: \.isWhitespace)
                let usedPercent = fields.count > 4 ? fields[4].replacingOccurrences(of: "%", with: "") : "?"
                let freeGB = fields.count > 3 ? (Int64(fields[3]) ?? 0) / 1_048_576 : 0
                let count = try await agentRun("/bin/sh", ["-c",
                    "if command -v apt >/dev/null; then apt list --upgradable 2>/dev/null | grep -c upgradable; elif command -v dnf >/dev/null; then dnf -q check-update 2>/dev/null | grep -c '^[A-Za-z0-9]'; else echo ?; fi"],
                    limit: .seconds(120)).trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(name)'s disk is \(usedPercent) percent full, with \(freeGB) gigabytes free. \(Self.updatesPhrase(count))"
            }
            let script = """
            $d = Get-PSDrive C
            $p = [math]::Round($d.Used / ($d.Used + $d.Free) * 100)
            $f = [math]::Round($d.Free / 1GB)
            try { $u = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0').Updates.Count } catch { $u = '?' }
            $r = Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired'
            "$p|$f|$u|$r"
            """
            let out = try await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"],
                                         limit: .seconds(180), input: script + "\n")
            let parts = (out.split(separator: "\n").last(where: { $0.contains("|") }) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
            guard parts.count == 4 else { return "\(name) didn't say how its disk and updates are." }
            let restart = parts[3] == "True" ? " A restart is waiting to finish installing updates." : ""
            return "\(name)'s drive C is \(parts[0]) percent full, with \(parts[1]) gigabytes free. \(Self.updatesPhrase(parts[2]))\(restart)"
        } catch {
            return "\(name) didn't answer. Its guest agent may not be running yet. Reason: \(error.localizedDescription)"
        }
    }

    nonisolated static func updatesPhrase(_ count: String) -> String {
        switch count {
        case "0": return "No updates are waiting."
        case "1": return "1 update is waiting."
        case "?", "": return "Waiting updates couldn't be counted."
        default: return "\(count) updates are waiting."
        }
    }
}
