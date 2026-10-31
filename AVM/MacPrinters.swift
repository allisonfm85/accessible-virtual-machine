// MacPrinters.swift
// AVM — Accessible Virtual Machine
//
// THE MAC'S PRINTERS IN A MACHINE (2026-10-27), as VMware's printer
// sharing. A machine reaches the Mac's own printing system only at
// 10.0.2.2, and CUPS refuses requests from the Mac itself unless they're
// addressed to "localhost" (its guard against DNS rebinding), so a machine
// can't print through the Mac. It can reach a network printer directly,
// though, through QEMU's network (MEASURED: a Brother MFC-L2980DW answered
// get-printer-attributes from Debian), and modern printers print without
// a driver over IPP. So AVM finds each of the Mac's network printers'
// addresses, as macOS does (its queue's device URI; Bonjour for a dnssd://
// one), and the machine adds them (VMManager.addMacPrinters): Windows with
// its IPP class driver, Linux with CUPS's driverless "everywhere" model.
// A printer on USB to the Mac isn't one of them; USB passthrough sends it.

import Foundation

nonisolated struct MacPrinter: Sendable, Equatable {
    /// The Mac's queue name, "Brother_MFC_L2980DW".
    let queue: String
    /// The name to show, "Brother MFC-L2980DW".
    let name: String
    /// Where the machine sends to: "ipp://10.168.168.65:631/ipp/print".
    let uri: String
}

nonisolated enum MacPrinters {

    /// The Mac's network printers with an address a machine can reach.
    /// Fax queues are left out. Blocking (lpstat, Bonjour, DNS): call off
    /// the main thread.
    static func find() -> [MacPrinter] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lpstat")
        process.arguments = ["-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> MacPrinter? in
                // "device for Brother_MFC_L2980DW: dnssd://Brother%20MFC-L2980DW._ipps._tcp.local./?uuid=…"
                let text = String(line)
                guard text.hasPrefix("device for "), let colon = text.range(of: ": ") else { return nil }
                let queue = String(text[text.index(text.startIndex, offsetBy: 11)..<colon.lowerBound])
                let device = String(text[colon.upperBound...])
                if queue.lowercased().contains("fax") { return nil }
                guard let uri = reachableURI(device) else { return nil }
                return MacPrinter(queue: queue, name: displayName(queue: queue, device: device), uri: uri)
            }
    }

    /// "Brother MFC-L2980DW" from the Bonjour name, or the queue name.
    static func displayName(queue: String, device: String) -> String {
        if device.hasPrefix("dnssd://"), let host = URL(string: device)?.host?.removingPercentEncoding {
            if let dot = host.range(of: "._ipp") { return String(host[..<dot.lowerBound]) }
        }
        return queue.replacingOccurrences(of: "_", with: " ")
    }

    /// The device URI as a machine can use it: plain IPP to the printer's
    /// IPv4 address (a machine can't do Bonjour, and Windows' IPP driver
    /// doesn't trust a printer's own certificate).
    static func reachableURI(_ device: String) -> String? {
        if device.hasPrefix("dnssd://") {
            guard let host = URL(string: device)?.host?.removingPercentEncoding,
                  let suffix = host.range(of: "._ipp") else { return nil }
            let service = String(host[..<suffix.lowerBound])
            guard let found = resolve(service: service, type: "_ipp._tcp.") else { return nil }
            return "ipp://\(found.address):\(found.port)/\(found.path)"
        }
        guard let url = URL(string: device), let scheme = url.scheme?.lowercased(),
              ["ipp", "ipps", "http", "https"].contains(scheme), let host = url.host,
              let address = ipv4(host) else { return nil }
        let port = url.port ?? 631
        let path = url.path.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "/_.-".contains($0)) }
        return "ipp://\(address):\(port)\(path.isEmpty ? "/ipp/print" : path)"
    }

    /// A Bonjour service's IPv4 address, port and resource path (its "rp"),
    /// waiting at most `limit` seconds.
    static func resolve(service: String, type: String, limit: TimeInterval = 4) -> (address: String, port: Int, path: String)? {
        final class Resolver: NSObject, NetServiceDelegate {
            var done = false
            func netServiceDidResolveAddress(_ sender: NetService) { done = true }
            func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { done = true }
        }
        let resolver = Resolver()
        let net = NetService(domain: "local.", type: type, name: service)
        net.delegate = resolver
        net.schedule(in: .current, forMode: .default)
        net.resolve(withTimeout: limit)
        let deadline = Date().addingTimeInterval(limit + 1)
        while !resolver.done, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        net.stop()
        guard net.port > 0 else { return nil }
        var path = "ipp/print"
        // Only path characters (2026-10-28, security review): the TXT record
        // comes from the network, and the path goes into a script in the
        // guest.
        if let txt = net.txtRecordData(), let rp = NetService.dictionary(fromTXTRecord: txt)["rp"] {
            let clean = String(decoding: rp, as: UTF8.self).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "/_.-".contains($0)) }
            if !clean.isEmpty { path = clean }
        }
        let address = (net.addresses ?? []).lazy.compactMap { data -> String? in
            data.withUnsafeBytes { raw -> String? in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
        }.first ?? net.hostName.flatMap(ipv4)
        guard let address else { return nil }
        return (address, net.port, path)
    }

    static func ipv4(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }
}
