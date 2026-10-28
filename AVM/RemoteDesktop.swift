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
import Security
import dnssd

// MARK: - What a machine's settings say

extension VMConfiguration {
    var remoteDesktopOn: Bool { remoteDesktopUser?.isEmpty == false }
    var remoteDesktopReachesNetwork: Bool { remoteDesktopReach == "network" }
}

@MainActor
enum RemoteDesktop {

    /// The port on the Mac for a machine: its own, kept once chosen, so
    /// the address the user wrote down stays true; a new one gets the
    /// lowest free from 3389.
    static func port(for config: VMConfiguration, among all: [VMConfiguration]) -> Int {
        if let port = config.remoteDesktopPort { return port }
        let taken = Set(all.filter { $0.id != config.id && $0.remoteDesktopOn }.compactMap(\.remoteDesktopPort))
        var port = 3389
        while taken.contains(port) { port += 1 }
        return port
    }

    /// "amena-pc": the machine's name as a host name.
    static func hostLabel(for config: VMConfiguration) -> String {
        let folded = config.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var label = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII { label.append(Character(scalar)) }
            else if !label.hasSuffix("-") { label.append("-") }
        }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if label.isEmpty { label = "avm-machine" }
        return String(label.prefix(60))
    }

    /// QEMU's forwarding rule for a machine.
    static func forwardingRule(for config: VMConfiguration, port: Int) -> String {
        "tcp:\(config.remoteDesktopReachesNetwork ? "0.0.0.0" : "127.0.0.1"):\(port)-:3389"
    }

    /// What to type in the Windows App, in words: the name first, then
    /// the address that always works.
    static func addresses(for config: VMConfiguration, port: Int) -> (name: String, ip: String) {
        let suffix = port == 3389 ? "" : ":\(port)"
        let name = "\(hostLabel(for: config)).local\(suffix)"
        let ip = config.remoteDesktopReachesNetwork
            ? "\(macAddress() ?? "the Mac's IP address")\(suffix)"
            : "127.0.0.1\(suffix)"
        return (name, ip)
    }

    /// The Mac's IPv4 address on its network, if it has one.
    static func macAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let list = first else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = list
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0", (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            // Wi-Fi and Ethernet first; anything else only if there's nothing better.
            if name == "en0" { return text }
            if found == nil, !text.hasPrefix("169.254.") { found = text }
        }
        return found
    }

    // MARK: The password, in the keychain

    private static let service = "com.alllisonmeloy.AVM.remote-desktop"

    static func savePassword(_ password: String, for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "AVM Remote Desktop password"
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            AVMLog.write("AVM: Remote Desktop — the password couldn't be kept in the keychain (\(status))")
        }
    }

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func forgetPassword(for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

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
        init(name: String) { self.name = name }
    }
    private var entries: [UUID: Entry] = [:]

    /// True when the name was published.
    @discardableResult
    func publish(_ config: VMConfiguration, port: Int) -> Bool {
        unpublish(config.id)
        let label = RemoteDesktop.hostLabel(for: config)
        let host = "\(label).local."
        let addressText = config.remoteDesktopReachesNetwork ? (RemoteDesktop.macAddress() ?? "127.0.0.1") : "127.0.0.1"
        var address = in_addr()
        guard inet_pton(AF_INET, addressText, &address) == 1 else { return false }
        let entry = Entry(name: host)

        var connection: DNSServiceRef?
        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError, let connection else { return false }
        entry.connection = connection
        DNSServiceSetDispatchQueue(connection, .main)
        var record: DNSRecordRef?
        let registered = withUnsafeBytes(of: &address) { raw in
            DNSServiceRegisterRecord(connection, &record, kDNSServiceFlagsUnique, 0, host,
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
        let published = DNSServiceRegister(&service, 0, 0, config.name, "_rdp._tcp", nil, host,
                                           UInt16(port).bigEndian, 0, nil, nil, nil)
        if published == kDNSServiceErr_NoError, let service {
            DNSServiceSetDispatchQueue(service, .main)
            entry.service = service
        }
        entries[config.id] = entry
        AVMLog.write("AVM: Remote Desktop — \(host.dropLast()) published for \(config.name), port \(port), at \(addressText)")
        return true
    }

    func unpublish(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let service = entry.service { DNSServiceRefDeallocate(service) }
        if let connection = entry.connection { DNSServiceRefDeallocate(connection) }   // takes its records with it
        AVMLog.write("AVM: Remote Desktop — \(entry.name.dropLast()) withdrawn")
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
    func setUpRemoteDesktop(configuration: VMConfiguration, user: String, password: String) async -> RemoteDesktopSetup {
        guard case .running = state, let agent = guestAgentSocketPath, FileManager.default.fileExists(atPath: agent) else {
            return .failed("\(configuration.name) isn't running with its agent yet. Start it, wait a minute, then try again.")
        }
        AVMLog.write("remoteDesktop: setting up the account \(user) in \(configuration.name)")
        do {
            if configuration.guestOS == .windows {
                return try await setUpWindowsRemoteDesktop(configuration: configuration, user: user, password: password)
            } else {
                return try await setUpLinuxRemoteDesktop(configuration: configuration, user: user, password: password)
            }
        } catch {
            AVMLog.write("remoteDesktop: setup failed: \(error.localizedDescription)")
            return .failed("Remote Desktop couldn't be set up in \(configuration.name). Reason: \(error.localizedDescription)")
        }
    }

    private func setUpWindowsRemoteDesktop(configuration: VMConfiguration, user: String, password: String) async throws -> RemoteDesktopSetup {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        // Group by SID, not name: "Remote Desktop Users" is translated on a
        // non-English Windows.
        let script = """
        $ErrorActionPreference = 'Stop'
        $edition = (Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').EditionID
        if ($edition -like 'Core*') { 'HOME'; exit 0 }
        $u = \(quoted(user)); $p = ConvertTo-SecureString \(quoted(password)) -AsPlainText -Force
        if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) {
          Set-LocalUser -Name $u -Password $p -PasswordNeverExpires $true
        } else {
          New-LocalUser -Name $u -Password $p -PasswordNeverExpires -AccountNeverExpires | Out-Null
        }
        Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $u -ErrorAction SilentlyContinue
        Set-ItemProperty 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name fDenyTSConnections -Value 0
        Set-ItemProperty 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp' -Name UserAuthentication -Value 1
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Set-Service -Name TermService -StartupType Automatic
        Start-Service -Name TermService -ErrorAction SilentlyContinue
        'READY'
        """
        let out = try await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], limit: .seconds(180))
        if out.contains("HOME") {
            return .unsupported("This Windows is the Home edition, which has no Remote Desktop host built in. Remote Desktop needs Windows 11 Pro.")
        }
        guard out.contains("READY") else {
            throw AVMError.qmpCommandFailed(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300).description)
        }
        return .ready("Remote Desktop is on in \(configuration.name), with the account \(user).")
    }

    private func setUpLinuxRemoteDesktop(configuration: VMConfiguration, user: String, password: String) async throws -> RemoteDesktopSetup {
        // The account; its password by standard input, never on a command
        // line the guest could list.
        let account = """
        set -e
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        id -u "$1" >/dev/null 2>&1 || useradd -m -s /bin/bash "$1"
        chpasswd
        """
        _ = try await agentRun("/bin/sh", ["-c", account, "sh", user], limit: .seconds(60), input: "\(user):\(password)\n")
        // xrdp, from the distribution, and its service.
        let host = """
        set -e
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export DEBIAN_FRONTEND=noninteractive
        if command -v xrdp >/dev/null; then :
        elif command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq xrdp xorgxrdp
        elif command -v dnf >/dev/null; then dnf install -y -q xrdp xorgxrdp
        else echo NOPKG; exit 0; fi
        adduser xrdp ssl-cert 2>/dev/null || true
        systemctl enable --now xrdp
        if command -v firewall-cmd >/dev/null; then firewall-cmd --permanent --add-port=3389/tcp >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
        systemctl is-active xrdp && echo READY
        """
        let out = try await agentRun("/bin/sh", ["-c", host], limit: .seconds(600))
        if out.contains("NOPKG") {
            return .unsupported("AVM doesn't know how to install xrdp on this Linux. Install xrdp yourself, then connect with the account \(user).")
        }
        guard out.contains("READY") else {
            throw AVMError.qmpCommandFailed(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300).description)
        }
        return .ready("Remote Desktop is on in \(configuration.name), with the account \(user).")
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
        switch await setUpRemoteDesktop(configuration: configuration, user: user, password: password) {
        case .ready(let words):
            AVMLog.write("remoteDesktop: \(words)")
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
