// RemoteDesktopAddress.swift
// AVM — Accessible Virtual Machine
//
// The part of Remote Desktop (RemoteDesktop.swift) with no machine in it:
// which port a machine gets, its name on the network, what to type in the
// Windows App, and the password in the keychain. In the logic tests.

import Foundation
import Security
import CryptoKit

// MARK: - What a machine's settings say

extension VMConfiguration {
    var remoteDesktopOn: Bool { remoteDesktopUser?.isEmpty == false }
    var remoteDesktopReachesNetwork: Bool { remoteDesktopReach == "network" }
}

nonisolated enum RemoteDesktop {

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

    /// A mark of a password, for remoteDesktopPasswordMark: not the
    /// password, and not enough to find it.
    static func mark(for password: String) -> String {
        let digest = SHA256.hash(data: Data(("avm-remote-desktop:" + password).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// True when nothing on the Mac listens on the port at the address QEMU
    /// would bind (2026-10-28): QEMU fails to start otherwise, with only
    /// "stopped unexpectedly" to show for it.
    static func isPortFree(_ port: Int, network: Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = network ? INADDR_ANY.bigEndian : inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return bound == 0
    }

    /// The port to use at a start: the machine's own when it's free, else
    /// the next free one that no other machine has.
    static func freePort(from wanted: Int, network: Bool, among all: [VMConfiguration], except id: UUID) -> Int {
        let taken = Set(all.filter { $0.id != id && $0.remoteDesktopOn }.compactMap(\.remoteDesktopPort))
        var port = wanted
        while port < wanted + 60 {
            if !taken.contains(port) || port == wanted, isPortFree(port, network: network) { return port }
            port += 1
        }
        return wanted
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
            // Wi-Fi and Ethernet first; anything else only if there's nothing
            // better; never a self-assigned address (2026-10-28, en0 too).
            if text.hasPrefix("169.254.") { continue }
            if name == "en0" { return text }
            if found == nil { found = text }
        }
        return found
    }

    // MARK: The password, in the keychain

    private static let service = "com.alllisonmeloy.AVM.remote-desktop"

    /// False when the keychain refused (2026-10-29, seventh audit): the
    /// caller then says so instead of promising a set-up that can't happen.
    @discardableResult
    static func savePassword(_ password: String, for id: UUID) -> Bool {
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
        return status == errSecSuccess
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

    /// The password now in the machine is the keychain's (2026-10-28).
    @MainActor static func recordPasswordMark(_ mark: String?, for id: UUID) {
        guard var config = VMStore.shared?.configurations.first(where: { $0.id == id }) else { return }
        config.remoteDesktopPasswordMark = mark
        VMStore.shared?.save(config)
    }

    static func forgetPassword(for id: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
    }
}

