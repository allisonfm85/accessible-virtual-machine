//
//  TestSupport.swift
//  AVMTests
//
//  Scratch folders and sockets for the tests. Everything lives under a
//  short folder in /tmp, because a unix socket path is limited to 104
//  bytes and $TMPDIR is too long for it.
//

import Foundation

/// A fresh folder, removed when the value goes away.
final class ScratchFolder {
    let path: String

    init() {
        path = "/tmp/avmt-\(getpid())-\(UUID().uuidString.prefix(8))"
        mkdir(path, 0o700)
    }

    func sub(_ name: String) -> String { path + "/" + name }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// A unix stream socket listening at `path`. Returns its descriptor.
func listeningSocket(at path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket failed")
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    precondition(bytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "path too long")
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        bytes.withUnsafeBytes { buf.copyMemory(from: $0) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    precondition(bound == 0, "bind failed: \(String(cString: strerror(errno)))")
    precondition(listen(fd, 4) == 0, "listen failed")
    return fd
}

/// True if `fd` is still an open descriptor.
func isOpen(_ fd: Int32) -> Bool {
    fcntl(fd, F_GETFD) != -1
}
