//
//  SocketDirectory.swift
//  AVM
//
//  The folder that holds one VM's sockets: QEMU's QMP, SPICE and
//  usbredir sockets and swtpm's socket. /tmp/avm-<uid>/<VM UUID>,
//  private to this user.
//
//  Why /tmp and not $TMPDIR: a unix socket path is limited to 104
//  bytes, and $TMPDIR plus a UUID plus a socket name goes over.
//
//  Why the checks: /tmp is shared by every account on the Mac. The old
//  folder, /tmp/avm, could be created first by another account, which
//  could then swap AVM's sockets for its own and listen in on the VM's
//  control channel, its screen, or a USB device sent to the VM. So both
//  levels are created with mode 0700, and a folder that already exists
//  is used only if lstat shows a real directory (not a symbolic link),
//  owned by this user. Our own folder with loose permissions is
//  tightened. Anything else refuses the start with a spoken reason. A
//  restart empties /tmp, which clears a planted folder.
//
//  Kept free of VMManager so the unit tests can drive it in a scratch
//  folder.
//

import Foundation

nonisolated enum SocketDirectory {

    /// Why a socket folder was refused. The description is spoken, so it
    /// names the step, the reason and the next action.
    struct Unsafe: LocalizedError, Equatable {
        let path: String
        let reason: String

        var errorDescription: String? {
            "The virtual machine did not start. Step: preparing its private socket folder, \(path). Reason: \(reason). Next: restart the Mac, which empties that folder, then start the virtual machine again."
        }
    }

    /// The base folder for this user: /tmp/avm-<uid>.
    static func basePath(uid: uid_t = getuid()) -> String {
        "/tmp/avm-\(uid)"
    }

    /// Creates or checks /tmp/avm-<uid>/<vmID> and returns it.
    static func prepare(for vmID: UUID, log: (String) -> Void = { _ in }) throws -> URL {
        try prepare(base: basePath(), vmID: vmID, log: log)
    }

    /// The same, under any base folder. `uid` is the owner the folders
    /// must have; the tests pass another one to stand in for a folder
    /// planted by another account.
    static func prepare(base: String,
                        vmID: UUID,
                        uid: uid_t = getuid(),
                        log: (String) -> Void = { _ in }) throws -> URL {
        let dir = base + "/" + vmID.uuidString
        for path in [base, dir] {
            if mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw Unsafe(path: path, reason: "it could not be created (\(errnoText()))")
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw Unsafe(path: path, reason: "it could not be checked (\(errnoText()))")
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw Unsafe(path: path, reason: "it is not a real folder")
            }
            guard info.st_uid == uid else {
                throw Unsafe(path: path, reason: "it belongs to another account")
            }
            if (info.st_mode & 0o077) != 0 {
                // Our own folder with loose permissions (an older AVM, or
                // a umask oddity at mkdir). Tighten it rather than refuse.
                guard chmod(path, 0o700) == 0 else {
                    throw Unsafe(path: path, reason: "other accounts can open it and it could not be made private (\(errnoText()))")
                }
                log("SocketDirectory: tightened \(path) to 0700")
            }
        }
        log("SocketDirectory: \(dir)")
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
