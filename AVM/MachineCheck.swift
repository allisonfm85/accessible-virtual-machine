// MachineCheck.swift
// AVM — Accessible Virtual Machine
//
// "Is this working?" (2026-11-01, the user's request): one command, Virtual
// Machine > Check This Machine, that asks the machine about what a person relies
// on, and says what's wrong and what to do. Testers' reports were mostly this
// by hand. It runs as a guest-agent script that prints key=value lines; what they
// mean is MachineCheckResult, in GuestWatchLogic.swift.

import Foundation

extension VMManager {

    private var checkScript: (program: String, args: [String]) {
        if runningGuestOS == .windows {
            return ("powershell.exe", ["-NoProfile", "-Command", """
                $p = (Get-Process).Name
                'signedin=' + [int]($p -contains 'explorer')
                'reader=' + (@('nvda','jfw','Narrator') | Where-Object { $p -contains $_ }) -join ','
                function S($n) { $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { 1 } else { 0 } }
                'sound=' + (S 'Audiosrv')
                'sounddevice=' + [int](@(Get-PnpDevice -Class AudioEndpoint -PresentOnly -Status OK -ErrorAction SilentlyContinue).Count -gt 0)
                'clipboard=' + (S 'vdservice')
                'sharedfolder=' + (S 'spice-webdavd')
                """])
        }
        return ("/bin/sh", ["-c", """
            export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            U=$(getent passwd 1000 | cut -d: -f1)
            P=$(ps -eo comm)
            echo "$P" | grep -qE '^(gnome-shell|plasmashell|xfce4-session|cinnamon)$' && echo signedin=1 || echo signedin=0
            echo "$P" | grep -qx orca && echo reader=orca || echo reader=
            echo sound=1
            grep -q '^ *[0-9]' /proc/asound/cards 2>/dev/null && echo sounddevice=1 || echo sounddevice=0
            echo "$P" | grep -qx spice-vdagent && echo clipboard=1 || echo clipboard=0
            systemctl is-active -q spice-webdavd 2>/dev/null && echo sharedfolder=1 || echo sharedfolder=0
            """])
    }

    /// Virtual Machine > Check This Machine.
    func checkThisMachine(configuration: VMConfiguration?) async {
        let machine = machineName
        Announcer.shared.announce("Checking \(machine).", tone: .info)
        let script = checkScript
        guard let out = try? await agentRun(script.program, script.args, limit: .seconds(60)) else {
            let result = MachineCheckResult(agentAnswered: false, output: "", windows: runningGuestOS == .windows, soundLevels: nil)
            say(result, machine: machine)
            return
        }
        let levels = configuration?.soundLevels
        say(MachineCheckResult(agentAnswered: true, output: out, windows: runningGuestOS == .windows, soundLevels: levels), machine: machine)
    }

    private func say(_ result: MachineCheckResult, machine: String) {
        AVMLog.write("AVM: Check This Machine — \(machine): \(result.problems.count) problem(s), \(result.fine.count) fine")
        // Said beside the result, not as a problem with the machine: someone
        // may want the shortcuts for Spaces.
        let mac = Self.macTakesControlArrows ? " " + MacSpacesShortcuts.words(machine: machine) : ""
        Announcer.shared.announce(result.words(machine: machine) + mac, tone: result.problems.isEmpty ? .success : .failure)
    }

    /// True while the Mac's shortcuts for Spaces hold Control and the arrows.
    static var macTakesControlArrows: Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return MacSpacesShortcuts.takeControlArrows(CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any])
    }

    /// Once each time AVM opens, as a Windows machine starts: every start would
    /// nag someone who keeps them for Spaces.
    func warnAboutMacSpacesShortcuts(_ configuration: VMConfiguration) {
        guard configuration.guestOS == .windows, !Self.warnedAboutMacSpacesShortcuts, Self.macTakesControlArrows else { return }
        Self.warnedAboutMacSpacesShortcuts = true
        AVMLog.write("AVM: the Mac's Spaces shortcuts hold Control and the arrows")
        Announcer.shared.announce(MacSpacesShortcuts.words(machine: configuration.name), tone: .info)
    }
    private static var warnedAboutMacSpacesShortcuts = false
}
