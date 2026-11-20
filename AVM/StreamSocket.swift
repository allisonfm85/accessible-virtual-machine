//
//  StreamSocket.swift
//  AVM
//
//  Connects to a QEMU usbredir socket as the user, so AVM can hand the
//  connected socket to the root USB helper (contract 0.3.0-fd). The
//  helper never opens a path itself.
//
//  Kept free of USBHelperClient so the unit tests can drive it against
//  a listening socket of their own.
//

import Foundation

nonisolated enum StreamSocket {

    /// Why the connection failed, in words fit for the diagnostic log
    /// and the failure announcement's step.
    struct Failure: Error, Equatable {
        let detail: String
    }

    /// The largest path a unix socket address can hold, terminator
    /// included (104 on macOS).
    static var maxPathBytes: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    /// Connects to the unix stream socket at `path`. Blocking connect on a
    /// unix socket returns at once: QEMU is already listening. The handle
    /// closes the socket when it is closed or released.
    static func connect(path: String) -> Result<FileHandle, Failure> {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= maxPathBytes else {
            return .failure(Failure(detail: "\(path) is too long for a unix socket"))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            pathBytes.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(Failure(detail: String(cString: strerror(errno))))
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            return .failure(Failure(detail: "\(path): \(reason) (is QEMU listening there?)"))
        }
        return .success(FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}
