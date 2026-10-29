// RemoteDesktop.swift
// AVM — Accessible Virtual Machine
//
// Remote Desktop into a machine (2026-10-28, a tester's request): the
// Windows App (Microsoft's Remote Desktop client, from the App Store, on
// this Mac or an iPad, iPhone or another Mac on the network) connects to
// a Windows or Linux machine running here, with a user name and password
// chosen in the machine's Settings.
//
// What AVM does:
//   - In the machine, through its guest agent: makes the account (or sets
//     its password), lets it in by Remote Desktop, turns the Remote Desktop
//     host on and opens its firewall. Windows Pro has one built in; Windows
//     Home doesn't, and AVM says so. Linux gets xrdp.
//   - On the Mac: QEMU's user networking keeps the machine off the network,
//     so AVM forwards a port on the Mac to the machine's 3389: the first
//     machine with Remote Desktop on gets 3389 itself (so the name alone
//     works), the next 3390, and so on. Bound to this Mac only, or to every
//     address, as chosen. While the machine runs, AVM publishes the
//     machine's name on the local network (Bonjour), so the Windows App
//     can be given "machine-name.local" rather than an IP address.
//   - The password goes to the Mac's keychain (the user's choice), so
//     Settings can read it back.
//
// macOS machines run on Apple's framework and have no RDP; Screen Sharing
// is theirs. Not offered for them.

import Foundation
import Network
import dnssd

// MARK: - The machine's name on the network

/// Publishes "machine-name.local" while a machine with Remote Desktop runs:
/// an address record for the name pointing at this Mac (its network
/// address, or 127.0.0.1 for a machine reachable from this Mac only), and
/// the Remote Desktop service beside it, as dns-sd -P does.
@MainActor
final class RemoteDesktopAdvertiser {
    static let shared = RemoteDesktopAdvertiser()

    private final class Entry {
        var connection: DNSServiceRef?
        var record: DNSRecordRef?
        var service: DNSServiceRef?
        let name: String
        let config: VMConfiguration
        let port: Int
        let address: String
        init(name: String, config: VMConfiguration, port: Int, address: String) {
            self.name = name; self.config = config; self.port = port; self.address = address
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var networkWatch: NWPathMonitor?
    private var refresh: DispatchWorkItem?

    /// True when the name was published.
    @discardableResult
    func publish(_ config: VMConfiguration, port: Int) -> Bool {
        unpublish(config.id)
        let label = RemoteDesktop.hostLabel(for: config)
        let host = "\(label).local."
        let addressText = config.remoteDesktopReachesNetwork ? (RemoteDesktop.macAddress() ?? "127.0.0.1") : "127.0.0.1"
        // This Mac only: published on this Mac only (2026-10-28, fourth
        // audit). On every interface, the machine's name and an RDP service
        // were announced to the whole network, though no one there could
        // connect. kDNSServiceInterfaceIndexLocalOnly is (uint32_t)-1.
        let interface: UInt32 = config.remoteDesktopReachesNetwork ? 0 : UInt32.max
        var address = in_addr()
        guard inet_pton(AF_INET, addressText, &address) == 1 else { return false }
        let entry = Entry(name: host, config: config, port: port, address: addressText)

        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return false }
        entry.connection = connection
        DNSServiceSetDispatchQueue(connection, .main)
        var record: DNSRecordRef?
        let registered = withUnsafeBytes(of: &address) { raw in
            DNSServiceRegisterRecord(connection, &record, kDNSServiceFlagsUnique, interface, host,
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                     UInt16(raw.count), raw.baseAddress, 120, { _, _, _, error, _ in
                if error != kDNSServiceErr_NoError {
                    AVMLog.write("AVM: Remote Desktop — the name couldn't be published (\(error))")
                }
            }, nil)
        }
        guard registered == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(connection)
            return false
        }
        entry.record = record

        var service: DNSServiceRef?
        let published = DNSServiceRegister(&service, 0, interface, config.name, "_rdp._tcp", nil, host,
                                           UInt16(port).bigEndian, 0, nil, nil, nil)
        if published == kDNSServiceErr_NoError, let service {
            DNSServiceSetDispatchQueue(service, .main)
            entry.service = service
        }
        entries[config.id] = entry
        AVMLog.write("AVM: Remote Desktop — \(host.dropLast()) published for \(config.name), port \(port)")
        watchNetwork()
        return true
    }

    func unpublish(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let service = entry.service { DNSServiceRefDeallocate(service) }
        if let connection = entry.connection { DNSServiceRefDeallocate(connection) }   // takes its records with it
        AVMLog.write("AVM: Remote Desktop — \(entry.name.dropLast()) withdrawn")
        if entries.isEmpty {
            networkWatch?.cancel()
            networkWatch = nil
            refresh?.cancel()
            refresh = nil
        }
    }

    // MARK: Another network

    /// The address record names the Mac's address when it was published.
    /// A Mac carried to another Wi-Fi, or woken on one, kept answering
    /// with the old one until the machine was restarted (2026-10-28, third
    /// audit): now a network change republishes every name whose address
    /// moved, a couple of seconds after things settle.
    private func watchNetwork() {
        guard networkWatch == nil else { return }
        let watch = NWPathMonitor()
        watch.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.republishLater() }
        }
        watch.start(queue: .main)
        networkWatch = watch
    }

    private func republishLater() {
        refresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.republishMoved() }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func republishMoved() {
        for entry in entries.values where entry.config.remoteDesktopReachesNetwork {
            let now = RemoteDesktop.macAddress() ?? "127.0.0.1"
            guard now != entry.address else { continue }
            AVMLog.write("AVM: Remote Desktop — the Mac's address changed; republishing \(entry.name.dropLast())")
            publish(entry.config, port: entry.port)
        }
    }
}

// MARK: - Setting the machine up, through its agent

extension VMManager {

    /// The result of setting a machine up, in words for the user.
    enum RemoteDesktopSetup {
        case ready(String)
        case unsupported(String)
        case failed(String)
    }

    /// Makes the account and turns the Remote Desktop host on in the
    /// running machine. The password goes only into the machine (and the
    /// keychain, by the caller); never into the log.
    /// `setPassword` false: an account that exists keeps its password (a
    /// new one gets this one); true: it's set, as after the user typed one.
    func setUpRemoteDesktop(configuration: VMConfiguration, user: String, password: String, setPassword: Bool = true) async -> RemoteDesktopSetup {
        guard case .running = state, let agent = guestAgentSocketPath, FileManager.default.fileExists(atPath: agent) else {
            return .failed("\(configuration.name) isn't running with its agent yet. Start it, wait a minute, then try again.")
        }
        AVMLog.write("remoteDesktop: setting up the Remote Desktop account in \(configuration.name) (password \(setPassword ? "set" : "kept"))")
        do {
            if configuration.guestOS == .windows {
                return try await setUpWindowsRemoteDesktop(configuration: configuration, user: user, password: password, setPassword: setPassword)
            } else {
                return try await setUpLinuxRemoteDesktop(configuration: configuration, user: user, password: password, setPassword: setPassword)
            }
        } catch {
            // Only the first line, and never spoken (2026-10-28, second
            // review): a script's error can quote the line that failed.
            let first = error.localizedDescription.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no detail"
            AVMLog.write("remoteDesktop: setup failed: \(first.prefix(160))")
            return .failed("Remote Desktop couldn't be set up in \(configuration.name). The reason is in AVM's diagnostic log.")
        }
    }

    private func setUpWindowsRemoteDesktop(configuration: VMConfiguration, user: String, password: String, setPassword: Bool) async throws -> RemoteDesktopSetup {
        // The name and password arrive on standard input, never in the
        // script (2026-10-28, second review): a quote in either broke the
        // script's text, and PowerShell's error quoted the line, password
        // and all, into the log and speech. The group by SID and the
        // firewall rules by their group id, not their translated names.
        let script = """
        $ErrorActionPreference = 'Stop'
        $in = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding $false))
        $u = $in.ReadLine(); $pw = $in.ReadLine(); $setPassword = ($in.ReadLine() -eq 'set')
        $edition = (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').EditionID
        if ($edition -like 'Core*') { 'AVM-RD-HOME'; exit 0 }
        $p = ConvertTo-SecureString $pw -AsPlainText -Force
        if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
          if ($setPassword) { Set-LocalUser -Name $u -Password $p -PasswordNeverExpires $true }
        } else {
          New-LocalUser -Name $u -Password $p -PasswordNeverExpires -AccountNeverExpires | Out-Null
        }
        Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $u -ErrorAction SilentlyContinue
        Set-ItemProperty 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name UserAuthentication -Value 1
        Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue
        Set-Service -Name TermService -StartupType Automatic
        Start-Service -Name TermService -ErrorAction SilentlyContinue
        'AVM-RD-READY'
        """
        let input = "\(user)\r\n\(password)\r\n\(setPassword ? "set" : "keep")\r\n"
        let out = try await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], limit: .seconds(180), input: input)
        // Markers nothing else prints (2026-10-28, fifth audit): an account
        // named HOMEOFFICE in an error line read as the Home edition.
        if out.contains("AVM-RD-HOME") {
            return .unsupported("This Windows is the Home edition, which has no Remote Desktop host built in. Remote Desktop needs Windows 11 Pro.")
        }
        guard out.contains("AVM-RD-READY") else {
            throw AVMError.qmpCommandFailed(out.trimmingCharacters(in: .whitespacesAndNewlines).description)
        }
        return .ready("Remote Desktop is on in \(configuration.name), with the account \(user).")
    }

    private func setUpLinuxRemoteDesktop(configuration: VMConfiguration, user: String, password: String, setPassword: Bool) async throws -> RemoteDesktopSetup {
        // The account; its password by standard input, never on a command
        // line the guest could list, and only when it's new or changed.
        let account = """
        set -e
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        new=
        id -u "$1" >/dev/null 2>&1 || { useradd -m -s /bin/bash "$1"; new=1; }
        if [ "$2" = set ] || [ -n "$new" ]; then chpasswd; fi
        echo AVM-RD-ACCOUNT
        """
        // Checked (2026-10-28, fifth audit): a failed useradd or chpasswd
        // still ended in "Remote Desktop is on".
        let made = try await agentRun("/bin/sh", ["-c", account, "sh", user, setPassword ? "set" : "keep"], limit: .seconds(60), input: "\(user):\(password)\n")
        guard made.contains("AVM-RD-ACCOUNT") else {
            throw AVMError.refused("the account \(user) couldn't be made, or its password set: \(made.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // xrdp, from the distribution, and its service.
        let host = """
        set -e
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export DEBIAN_FRONTEND=noninteractive
        if command -v xrdp >/dev/null; then :
        elif command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq xrdp xorgxrdp
        elif command -v dnf >/dev/null; then dnf install -y -q xrdp xorgxrdp
        else echo NOPKG; exit 0; fi
        # Sound in the remote session takes the distribution's xrdp sound
        # module (pipewire-module-xrdp: Debian 13 and Ubuntu 24.04 or newer
        # have it); without it the session is silent (2026-10-28).
        if command -v apt-get >/dev/null; then
            dpkg -s pipewire-module-xrdp >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq pipewire-module-xrdp; } >/dev/null 2>&1 || true
            dpkg -s pipewire-module-xrdp >/dev/null 2>&1 && echo SOUND
        elif command -v dnf >/dev/null; then
            rpm -q pipewire-module-xrdp >/dev/null 2>&1 || dnf install -y -q pipewire-module-xrdp >/dev/null 2>&1 || true
            rpm -q pipewire-module-xrdp >/dev/null 2>&1 && echo SOUND
        fi
        adduser xrdp ssl-cert 2>/dev/null || true
        systemctl enable --now xrdp
        if command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --add-port=3389/tcp >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
        systemctl is-active xrdp && echo AVM-RD-READY
        """
        let out = try await agentRun("/bin/sh", ["-c", host], limit: .seconds(600))
        if out.contains("NOPKG") {
            return .unsupported("AVM doesn't know how to install xrdp on this Linux. Install xrdp yourself, then connect with the account \(user).")
        }
        guard out.contains("AVM-RD-READY") else {
            throw AVMError.qmpCommandFailed(out.trimmingCharacters(in: .whitespacesAndNewlines).description)
        }
        let sound = out.contains("SOUND")
        return .ready("Remote Desktop is on in \(configuration.name), with the account \(user)."
                      + (sound ? "" : " This Linux has no xrdp sound module, so the remote session has no sound."))
    }

    /// Forwards the Mac's port to the running machine now (QEMU's user
    /// networking takes hostfwd_add at run time), so Settings works without
    /// a restart. The next start has it in the arguments.
    func forwardRemoteDesktopNow(configuration: VMConfiguration, port: Int) async -> Bool {
        guard case .running = state else { return false }
        let rule = RemoteDesktop.forwardingRule(for: configuration, port: port)
        do {
            // Any old rule for this port first; the answer is text, empty on success.
            _ = try? await sendQMPCommand("human-monitor-command", arguments: ["command-line": "hostfwd_remove tcp:127.0.0.1:\(port)"])
            _ = try? await sendQMPCommand("human-monitor-command", arguments: ["command-line": "hostfwd_remove tcp:0.0.0.0:\(port)"])
            let answer = try await sendQMPCommand("human-monitor-command", arguments: ["command-line": "hostfwd_add \(rule)"])
            let text = (answer as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty else {
                AVMLog.write("remoteDesktop: hostfwd_add \(rule) answered: \(text)")
                return false
            }
            AVMLog.write("remoteDesktop: forwarding \(rule)")
            return true
        } catch {
            AVMLog.write("remoteDesktop: hostfwd_add failed: \(error.localizedDescription)")
            return false
        }
    }

    /// At each start with Remote Desktop on: once the agent answers, the
    /// account and host are set again (the same commands; nothing changes
    /// when they're already right), so a machine set up while it was
    /// stopped, or reinstalled, is ready. Failures are spoken; success is
    /// logged.
    func keepRemoteDesktopReady(configuration: VMConfiguration) async {
        guard let user = configuration.remoteDesktopUser, !user.isEmpty,
              let password = RemoteDesktop.password(for: configuration.id), !password.isEmpty else {
            AVMLog.write("remoteDesktop: no account or password kept for \(configuration.name); nothing to set up")
            return
        }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(5))
            guard case .running = state else { return }
            if (try? await agentCall(["execute": "guest-ping"], timeout: 4)) != nil { break }
        }
        guard case .running = state else { return }
        let mark = RemoteDesktop.mark(for: password)
        let setPassword = configuration.remoteDesktopPasswordMark != mark
        switch await setUpRemoteDesktop(configuration: configuration, user: user, password: password, setPassword: setPassword) {
        case .ready(let words):
            AVMLog.write("remoteDesktop: \(words)")
            if setPassword { RemoteDesktop.recordPasswordMark(mark, for: configuration.id) }
        case .unsupported(let words), .failed(let words):
            Announcer.shared.announce(words, tone: .failure)
        }
    }

    func stopForwardingRemoteDesktop(port: Int) async {
        guard case .running = state else { return }
        _ = try? await sendQMPCommand("human-monitor-command", arguments: ["command-line": "hostfwd_remove tcp:127.0.0.1:\(port)"])
        _ = try? await sendQMPCommand("human-monitor-command", arguments: ["command-line": "hostfwd_remove tcp:0.0.0.0:\(port)"])
    }
}
