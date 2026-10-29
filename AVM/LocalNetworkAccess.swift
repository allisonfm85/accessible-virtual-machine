// LocalNetworkAccess.swift
// AVM — Accessible Virtual Machine
//
// macOS's Local Network permission, asked for before the guest starts
// (2026-10-26). The guest reaches the internet through QEMU's user-mode
// network, which sends the guest's name lookups to the Mac's own DNS
// server. On most home networks that is the router, a local network
// address, so macOS holds those lookups until AVM is allowed Local Network
// access. The first time, its prompt used to appear while Windows had the
// keyboard, in the middle of Windows Setup, and until it was answered the
// guest had a working network card and no internet.
//
// Now, before QEMU starts, AVM sends one DNS query to that server itself.
// That makes macOS ask then, while the Mac has the keyboard, and AVM says
// what the prompt is for. If access is off, AVM says where to turn it on;
// the machine starts either way. A DNS server on the internet (8.8.8.8,
// say) needs no permission, and AVM asks for nothing.

import Foundation
import Network
import SystemConfiguration

@MainActor
enum LocalNetworkAccess {
    enum Result { case allowed, denied, notNeeded }

    /// Settled once allowed, so later starts don't ask again.
    private static var allowed = false
    /// How long AVM waits for the user to answer macOS's prompt. macOS
    /// asks only once, so after that a refusal shows at once, and AVM
    /// waits only a moment.
    private static let answerLimit: Duration = .seconds(90)
    private static let laterLimit: Duration = .seconds(3)
    private static let askedKey = "AVMLocalNetworkAsked"

    /// Asks for Local Network access if the guest will need it. Returns
    /// once it is allowed, refused, or the wait runs out.
    static func ensure(guest: String) async -> Result {
        guard !allowed else { return .allowed }
        guard let server = dnsServers().first(where: isLocal) else { return .notNeeded }

        let askedBefore = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let outcome = Outcome()
        var announced = false
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    connection.send(content: dnsQuery, completion: .contentProcessed { _ in })
                    outcome.finish(.allowed)
                case .waiting:
                    // macOS's prompt is up, or access was refused before.
                    if !announced, !askedBefore {
                        announced = true
                        Announcer.shared.announce("macOS is asking whether AVM can find and connect to devices on your local network. Choose Allow: \(guest) needs it to reach the internet.", tone: .info)
                    }
                case .failed:
                    outcome.finish(.denied)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)

        let result = await outcome.wait(limit: askedBefore ? laterLimit : answerLimit)
        connection.cancel()
        switch result {
        case .allowed:
            allowed = true
            AVMLog.write("AVM: LocalNetwork — allowed (DNS server is on the local network).")
        case .denied:
            AVMLog.write("AVM: LocalNetwork — not allowed; the guest will have no internet.")
            Announcer.shared.announce("\(guest) won't reach the internet until AVM is allowed local network access. Next: in System Settings, open Privacy and Security, then Local Network, and turn on AVM.", tone: .failure)
        case .notNeeded:
            break
        }
        return result
    }

    /// The Mac's DNS servers, in order.
    nonisolated static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "AVM" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Private, link-local and unique-local addresses: the ones macOS
    /// counts as the local network.
    nonisolated static func isLocal(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// A standard query for apple.com's address.
    private static let dnsQuery = Data([
        0x41, 0x56, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x05, 0x61, 0x70, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d, 0x00,
        0x00, 0x01, 0x00, 0x01,
    ])

    /// The first answer wins; the time limit counts as refused.
    @MainActor
    private final class Outcome {
        private var result: Result?
        private var waiter: CheckedContinuation<Result, Never>?

        func finish(_ value: Result) {
            guard result == nil else { return }
            result = value
            waiter?.resume(returning: value)
            waiter = nil
        }

        func wait(limit: Duration) async -> Result {
            if let result { return result }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                self.finish(.denied)
            }
            return await withCheckedContinuation { waiter = $0 }
        }
    }
}
