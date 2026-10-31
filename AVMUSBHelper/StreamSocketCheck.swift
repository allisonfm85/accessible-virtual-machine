// StreamSocketCheck.swift
// AVM — Accessible Virtual Machine
//
// The root USB helper's check of the stream socket path a client sends.
// In its own file (2026-10-26) so the logic test suite can compile and
// test it without the rest of the helper.

import Foundation

// MARK: - Stream socket check (2026-10-25, security audit)

/// Why the client's stream socket path must not be connected to, or nil
/// when it may. This process is root, and root's connect() ignores socket
/// permissions and follows symlinks, so the path has to prove it belongs
/// to the user who asked: exactly /tmp/avm-<uid>/<VM UUID>/usbredir-<5…8>.sock
/// (or hidbridge-<5…8>.sock, a Bluetooth device's, 2026-10-27; or under
/// /tmp/avm-<uid>-<6 hex>, the root AVM falls back to when another account
/// holds the usual one, 2026-10-28)
/// (the layout VMManager.privateSocketDirectory makes), both folders real
/// directories owned by that uid and closed to everyone else, and the
/// socket itself a socket owned by that uid. Another account then can't
/// plant or redirect anything in the path, and no client can aim root at
/// any other socket on the system.
func streamSocketProblem(_ path: String, uid: uid_t) -> String? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // "", "tmp", "avm-<uid>", "<uuid>", "usbredir-N.sock"
    guard parts.count == 5, parts[0].isEmpty, parts[1] == "tmp",
          parts[2] == "avm-\(uid)" || parts[2].range(of: "^avm-\(uid)-[0-9a-f]{6}$", options: .regularExpression) != nil,
          UUID(uuidString: parts[3]) != nil,
          (5...8).flatMap({ ["usbredir-\($0).sock", "hidbridge-\($0).sock"] }).contains(parts[4]) else {
        return "stream socket path is not in the user's private AVM folder"
    }
    let root = "/tmp/" + parts[2]
    let dir = root + "/" + parts[3]
    for folder in [root, dir] {
        var info = stat()
        guard lstat(folder, &info) == 0 else { return "\(folder) is missing" }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "\(folder) is not a folder" }
        guard info.st_uid == uid else { return "\(folder) belongs to another user" }
        guard info.st_mode & 0o077 == 0 else { return "\(folder) can be opened by other users" }
    }
    var info = stat()
    guard lstat(path, &info) == 0 else { return "the stream socket is missing (is QEMU listening?)" }
    guard info.st_mode & S_IFMT == S_IFSOCK else { return "the stream path is not a socket" }
    guard info.st_uid == uid else { return "the stream socket belongs to another user" }
    return nil
}
