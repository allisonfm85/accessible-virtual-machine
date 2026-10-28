// RemoteDesktopAddress.swift
// AVM — Accessible Virtual Machine
//
// The part of Remote Desktop (RemoteDesktop.swift) with no machine in it:
// which port a machine gets, its name on the network, what to type in the
// Windows App, and the password in the keychain. In the logic tests.

import Foundation
import Security

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

