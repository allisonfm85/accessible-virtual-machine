// GuestRepair.swift
// AVM — Accessible Virtual Machine
//
// Repair for AVM (2026-10-31): a Fedora, AlmaLinux, Rocky or openSUSE
// machine installed before 0.4.19 keeps SELinux confining its guest agent
// (virt_qemu_ga_t), so Send File, the shared folder's bookmark, avmctl
// send-file and Remote Desktop's account fail there. The agent can't lift
// that itself: the policy is root's. So AVM opens GNOME's Run a Command
// box (Alt-F2) in the machine and types the one command that makes the
// agent's domain permissive (the same CIL module the install now adds),
// through pkexec, so GNOME asks for the password in its own dialog, which
// Orca reads. AVM then sees the agent free again and does the rest through
// it: openSUSE's shared folder drop-in, Rocky's shared folder service.
//
// MEASURED 2026-10-31 on a Rocky 10.2 machine from before the fix: the
// Super key alone (QMP send-key) didn't open GNOME's overview; Alt-F2 did,
// and the pkexec dialog came up with the password field focused. Confined
// before, free 4 seconds after the password.
//
// Typed through the machine's own keyboard (QMP send-key, TypeText.swift),
// so it needs GNOME's desktop signed in and unlocked, which is what AVM's
// installs leave. Nothing is typed that the person hasn't asked for: the
// menu item asks first.

import AppKit

extension VMManager {

    /// The guests whose installs enforce SELinux on the agent.
    nonisolated static func mayNeedRepair(_ guest: GuestOS?) -> Bool {
        guard let guest else { return false }
        return [.fedora, .almalinux, .rocky, .opensuse].contains(guest)
    }

    /// The command typed in GNOME's Run a Command box. Every character has
    /// a key on the US layout AVM's installs use.
    nonisolated static let repairCommand =
        #"pkexec sh -c 'printf "(typepermissive virt_qemu_ga_t)\n" > /tmp/avm.cil && semodule -i /tmp/avm.cil'"#

    /// Whether the agent is still confined: it can't look at a file in
    /// /usr/sbin (listing the folder itself is allowed, so that says nothing).
    func agentIsConfined() async -> Bool? {
        guard let out = try? await agentRun("/bin/sh", ["-c", "stat /usr/sbin/useradd >/dev/null 2>&1 && echo AVM-FREE || echo AVM-CONFINED"], limit: .seconds(20)) else { return nil }
        return out.contains("AVM-CONFINED")
    }

    /// Virtual Machine > Repair for AVM.
    /// `askFirst` false only for its test (--test-repair).
    func repairForAVM(askFirst: Bool = true) async {
        let machine = machineName
        guard !isRepairing else {
            Announcer.shared.announce("\(machine)'s repair is waiting for your password already.", tone: .info)
            return
        }
        guard Self.mayNeedRepair(runningGuestOS) else {
            Announcer.shared.announce("Only Fedora, AlmaLinux, Rocky Linux and openSUSE machines need this repair.", tone: .info)
            return
        }
        guard let confined = await agentIsConfined() else {
            Announcer.shared.announce("\(machine)'s guest agent isn't answering. Next: wait for it to finish starting, then try again.", tone: .failure)
            return
        }
        guard confined else {
            await finishRepair(machine)
            return
        }
        if askFirst {
            let alert = NSAlert()
            alert.messageText = "Repair \(machine) for AVM?"
            alert.informativeText = "\(machine) was installed by an older AVM, so it can't receive files or set up Remote Desktop. AVM will type one command in \(machine), and \(machine) will ask for your password. \(machine) must be signed in, on its desktop."
            alert.addButton(withTitle: "Repair")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isRepairing = true
        defer { isRepairing = false }
        Announcer.shared.announce("Typing the repair in \(machine).", tone: .info)
        // Escape first: a password box still open from an earlier try would
        // otherwise take the command as its password (2026-11-01 audit).
        _ = try? await sendQMPCommand("send-key", arguments: ["keys": [["type": "qcode", "data": "esc"]]])
        try? await Task.sleep(for: .seconds(1))
        // GNOME's Run a Command box, then the command.
        _ = try? await sendQMPCommand("send-key", arguments: ["keys": [["type": "qcode", "data": "alt"], ["type": "qcode", "data": "f2"]], "hold-time": 200])
        try? await Task.sleep(for: .seconds(3))
        guard let typed = await typeText(Self.repairCommand + "\n"), !typed.stopped, typed.skipped == 0 else {
            Announcer.shared.announce("The repair command couldn't be typed into \(machine). Next: make sure it's running, then try again.", tone: .failure)
            return
        }
        Announcer.shared.announce("\(machine) should be asking for your password now; AVM can't see it from here. Press Command-Shift-E, type your password for \(machine), and press Return. AVM checks when the repair is done.", tone: .info)
        AVMLog.write("AVM: Repair — command typed in \(machine); waiting for the password")
        // Up to three minutes for the password.
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(3))
            if await agentIsConfined() == false {
                await finishRepair(machine)
                return
            }
        }
        _ = try? await sendQMPCommand("send-key", arguments: ["keys": [["type": "qcode", "data": "esc"]]])
        Announcer.shared.announce("\(machine) isn't repaired yet. Next: make sure \(machine) is signed in and unlocked, on its desktop, then choose Repair again.", tone: .failure)
    }

    /// With the agent free: the rest, through it.
    private func finishRepair(_ machine: String) async {
        var extra = ""
        switch runningGuestOS {
        case .opensuse:
            let dropIn = """
            mkdir -p /etc/systemd/system/spice-webdavd.service.d
            printf '# Written by AVM: the shared folder needs its virtio port.\\n[Service]\\nPrivateDevices=no\\n' > /etc/systemd/system/spice-webdavd.service.d/avm.conf
            systemctl daemon-reload; systemctl restart spice-webdavd.service 2>/dev/null; echo AVM-OK
            """
            if (try? await agentRun("/bin/sh", ["-c", dropIn], limit: .seconds(60)))?.contains("AVM-OK") == true { extra = " Its shared folder works too." }
        case .rocky:
            Announcer.shared.announce("Installing the shared folder service in \(machine). This takes a minute.", tone: .info)
            let out = (try? await agentRun("/bin/sh", ["-c", UbuntuInstallPipeline.rockyWebDAV + "rpm -q spice-webdavd >/dev/null && echo AVM-OK"], limit: .seconds(300))) ?? ""
            extra = out.contains("AVM-OK") ? " Its shared folder works too." : " Its shared folder service couldn't be installed."
        default: break
        }
        AVMLog.write("AVM: Repair — \(machine)'s guest agent is free\(extra)")
        Announcer.shared.announce("\(machine) is repaired. Send File and Remote Desktop work in it now.\(extra)", tone: .success)
    }
}
