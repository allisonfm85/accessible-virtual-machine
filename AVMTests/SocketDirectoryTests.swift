//
//  SocketDirectoryTests.swift
//  AVMTests
//
//  The VM socket folder must be a real folder, owned by this user, with
//  no access for anyone else. See SocketDirectory.swift for why.
//

import Foundation
import Testing

@Suite("Socket folder")
struct SocketDirectoryTests {

    private let scratch = ScratchFolder()
    private let vmID = UUID()

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    @Test("creates both levels with mode 0700")
    func createsPrivateFolders() throws {
        let base = scratch.sub("base")
        let url = try SocketDirectory.prepare(base: base, vmID: vmID)
        #expect(url.path == base + "/" + vmID.uuidString)
        #expect(mode(base) == 0o700)
        #expect(mode(url.path) == 0o700)
    }

    @Test("reuses a folder it made before")
    func reusesExistingFolder() throws {
        let base = scratch.sub("base")
        let first = try SocketDirectory.prepare(base: base, vmID: vmID)
        let second = try SocketDirectory.prepare(base: base, vmID: vmID)
        #expect(first == second)
    }

    @Test("tightens our own folder when others can open it")
    func tightensLoosePermissions() throws {
        let base = scratch.sub("loose")
        mkdir(base, 0o777)
        chmod(base, 0o777)
        var logged: [String] = []
        _ = try SocketDirectory.prepare(base: base, vmID: vmID) { logged.append($0) }
        #expect(mode(base) == 0o700)
        #expect(logged.contains { $0.contains("tightened") })
    }

    @Test("refuses a symbolic link as the base folder")
    func refusesSymlinkBase() {
        let real = scratch.sub("real")
        mkdir(real, 0o700)
        let link = scratch.sub("link")
        symlink(real, link)
        #expect(throws: SocketDirectory.Unsafe(path: link, reason: "it is not a real folder")) {
            try SocketDirectory.prepare(base: link, vmID: vmID)
        }
    }

    @Test("refuses a symbolic link as the VM folder")
    func refusesSymlinkVMFolder() {
        let base = scratch.sub("base")
        mkdir(base, 0o700)
        let elsewhere = scratch.sub("elsewhere")
        mkdir(elsewhere, 0o700)
        let vmPath = base + "/" + vmID.uuidString
        symlink(elsewhere, vmPath)
        #expect(throws: SocketDirectory.Unsafe(path: vmPath, reason: "it is not a real folder")) {
            try SocketDirectory.prepare(base: base, vmID: vmID)
        }
    }

    @Test("refuses a file where the folder should be")
    func refusesFile() {
        let path = scratch.sub("file")
        FileManager.default.createFile(atPath: path, contents: nil)
        #expect(throws: SocketDirectory.Unsafe(path: path, reason: "it is not a real folder")) {
            try SocketDirectory.prepare(base: path, vmID: vmID)
        }
    }

    @Test("refuses a folder owned by another account")
    func refusesOtherOwner() {
        // A second account can't be created in a test, so the folder is
        // ours and the expected owner is someone else.
        let base = scratch.sub("planted")
        mkdir(base, 0o700)
        #expect(throws: SocketDirectory.Unsafe(path: base, reason: "it belongs to another account")) {
            try SocketDirectory.prepare(base: base, vmID: vmID, uid: getuid() + 1)
        }
    }

    @Test("the refusal says what failed and what to do next")
    func refusalIsActionable() {
        let error = SocketDirectory.Unsafe(path: "/tmp/avm-501", reason: "it belongs to another account")
        let text = error.localizedDescription
        #expect(text.contains("/tmp/avm-501"))
        #expect(text.contains("Reason: it belongs to another account"))
        #expect(text.contains("Next: restart the Mac"))
    }

    @Test("the longest socket path fits in a unix socket address")
    func longestSocketPathFits() {
        // usbredir-8.sock is the longest name AVM puts in the folder.
        let longest = SocketDirectory.basePath(uid: uid_t(UInt32.max))
            + "/" + UUID().uuidString + "/usbredir-8.sock"
        #expect(longest.utf8CString.count <= StreamSocket.maxPathBytes)
    }

    @Test("the base folder is per user and outside the old shared /tmp/avm")
    func basePathIsPerUser() {
        #expect(SocketDirectory.basePath(uid: 501) == "/tmp/avm-501")
        #expect(SocketDirectory.basePath(uid: 502) != SocketDirectory.basePath(uid: 501))
    }
}
