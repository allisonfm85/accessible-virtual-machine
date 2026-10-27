// WindowsSetupAnswers.swift
// AVM — Accessible Virtual Machine
//
// The answers the setup wizard collects for Windows Setup (2026-10-26),
// written into this machine's own answer file, so Windows doesn't ask
// them on screens the user can only hear through Narrator:
//   - region and keyboard (WindowsRegion.swift has the Mac mappings);
//   - the computer's name;
//   - the time zone, in Windows' own names ("Central Standard Time"),
//     from the Mac's via ICU;
//   - privacy: the most private choice, or Windows' recommended settings;
//   - the account: a Microsoft account, signed in during setup as before,
//     or a local account created from the wizard's name and password,
//     which skips Windows' sign-in screens and signs in once by itself so
//     NVDA installs and starts with no one at the keyboard.
// Anything left unanswered stays out of the answer file, and Windows asks.
//
// THE PASSWORD: never stored as typed. The answer file's own encoding is
// kept instead (base64 of UTF-16LE password + "Password", which Windows
// reads), in windows-setup.json in the VM's folder, owner-only, until the
// install media is built; then it is removed. That encoding is only a
// scramble, so the answer file itself is taken off the UNATTEND volume
// once Windows is installed (VMManager.removeFinishedWindowsMedia); Windows
// masks the passwords in the copy it keeps in C:\Windows\Panther.

import Foundation

nonisolated struct WindowsSetupAnswers: Codable, Equatable, Sendable {

    enum Privacy: String, Codable, CaseIterable, Sendable {
        /// ProtectYourPC 3: no optional data, no tailored experiences.
        case mostPrivate
        /// ProtectYourPC 1: Windows' recommended settings.
        case recommended
    }

    struct LocalAccount: Codable, Equatable, Sendable {
        var userName: String
        var displayName: String
        /// The answer file's encoding of the password, not the password.
        var encodedPassword: String?
    }

    /// "en-US"; nil lets Windows ask.
    var locale: String?
    /// "0409:00000409"; nil lets Windows ask.
    var inputLocale: String?
    /// Up to 15 characters; nil lets Windows make one up.
    var computerName: String?
    /// "Central Standard Time"; nil leaves Windows to set it.
    var timeZone: String?
    var privacy: Privacy = .mostPrivate
    /// nil: a Microsoft account, signed in during setup.
    var localAccount: LocalAccount?
    /// NVDA's laptop keyboard layout, written before NVDA first starts: a
    /// Mac keyboard has no Insert key or number pad. nil or true: laptop.
    var nvdaLaptopLayout: Bool?

    // MARK: Defaults from the Mac

    @MainActor
    static func fromThisMac(computerName: String?) -> WindowsSetupAnswers {
        let region = WindowsRegion.current()
        return WindowsSetupAnswers(
            locale: region.locale,
            inputLocale: region.inputLocale,
            computerName: computerName,
            timeZone: windowsTimeZone(for: TimeZone.current.identifier)
        )
    }

    // MARK: Password

    static func encode(password: String) -> String {
        var bytes = Data()
        for unit in (password + "Password").utf16 {
            bytes.append(UInt8(unit & 0xff))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes.base64EncodedString()
    }

    // MARK: Checks (the wizard says these as written)

    static func problem(withComputerName name: String) -> String? {
        if name.isEmpty || name.count > 15 {
            return "The computer name must be 1 to 15 characters."
        }
        if name.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) == nil {
            return "The computer name can use only letters, digits and hyphens."
        }
        if name.hasPrefix("-") || name.hasSuffix("-") {
            return "The computer name can't start or end with a hyphen."
        }
        if name.allSatisfy(\.isNumber) {
            return "The computer name can't be only digits."
        }
        return nil
    }

    /// Accounts Windows already has, which Setup refuses.
    static let reservedUserNames: Set<String> = [
        "administrator", "guest", "defaultaccount", "wdagutilityaccount", "system",
        "localsystem", "networkservice", "localservice", "user", "users", "admin",
        "administrators", "everyone", "none",
    ]

    static func problem(withUserName name: String, computerName: String?) -> String? {
        if name.isEmpty || name.count > 20 {
            return "The Windows user name must be 1 to 20 characters."
        }
        if name.rangeOfCharacter(from: CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@")) != nil {
            return "The Windows user name can't contain any of these: \" / \\ [ ] : ; | = , + * ? < > @"
        }
        if name.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty || name.hasSuffix(".") {
            return "The Windows user name can't be only dots and spaces, or end with a dot."
        }
        if reservedUserNames.contains(name.lowercased()) {
            return "Windows already has an account called \(name). Please choose another user name."
        }
        if let computerName, name.caseInsensitiveCompare(computerName) == .orderedSame {
            return "The Windows user name can't be the same as the computer name."
        }
        return nil
    }

    /// "Amena's PC" -> "Amenas-PC": the VM's name as a computer name.
    static func suggestedComputerName(from vmName: String) -> String {
        var name = vmName.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : (scalar == "'" ? "\u{0}" : "-")
        }.filter { $0 != "\u{0}" }.reduce(into: "") { $0.append($1) }
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = String(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(15))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return problem(withComputerName: name) == nil ? name : "AVM-PC"
    }

    // MARK: Time zones

    private typealias WindowsZoneFunction = @convention(c) (
        UnsafePointer<UInt16>, Int32, UnsafeMutablePointer<UInt16>, Int32, UnsafeMutablePointer<Int32>) -> Int32

    /// ICU's own table (CLDR windowsZones), from macOS's libicucore.
    private static let windowsZoneFunction: WindowsZoneFunction? = {
        guard let handle = dlopen("/usr/lib/libicucore.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "ucal_getWindowsTimeZoneID") else { return nil }
        return unsafeBitCast(symbol, to: WindowsZoneFunction.self)
    }()

    /// "America/Chicago" -> "Central Standard Time"; nil if ICU has none.
    static func windowsTimeZone(for identifier: String) -> String? {
        guard let function = windowsZoneFunction else { return nil }
        let id = Array(identifier.utf16)
        var out = [UInt16](repeating: 0, count: 128)
        var status: Int32 = 0
        let length = function(id, Int32(id.count), &out, Int32(out.count), &status)
        guard status <= 0, length > 0 else { return nil }
        return String(utf16CodeUnits: out, count: Int(length))
    }

    /// Every Windows time zone, sorted, for the wizard's picker.
    static let allWindowsTimeZones: [String] = {
        Array(Set(TimeZone.knownTimeZoneIdentifiers.compactMap { windowsTimeZone(for: $0) })).sorted()
    }()

    // MARK: Answer file sections

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let componentAttributes = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance""#

    /// The marker in Resources/autounattend.xml each section replaces.
    var answerFileSections: [String: String] {
        [
            "<!--AVM_SPECIALIZE_SHELL-->": specializeShellComponent,
            "<!--AVM_INTERNATIONAL-->": WindowsRegion(locale: locale, inputLocale: inputLocale).answerFileComponent,
            "<!--AVM_AUTOLOGON-->": autoLogon,
            "<!--AVM_OOBE_ACCOUNT-->": localAccount == nil ? "" : "<HideLocalAccountScreen>true</HideLocalAccountScreen>\n        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>",
            "AVM_PROTECT_YOUR_PC": privacy == .mostPrivate ? "3" : "1",
            "<!--AVM_TIMEZONE_ACCOUNTS-->": timeZoneAndAccounts,
            "<!--AVM_NVDA_SETTINGS-->": nvdaSettings,
        ]
    }

    private var specializeShellComponent: String {
        guard let computerName, Self.problem(withComputerName: computerName) == nil else { return "" }
        return """
        <component name="Microsoft-Windows-Shell-Setup" \(Self.componentAttributes)>
              <ComputerName>\(computerName)</ComputerName>
            </component>
        """
    }

    private var autoLogon: String {
        guard let account = localAccount else { return "" }
        return """
        <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>\(Self.xml(account.userName))</Username>
                <Password>
                  <Value>\(account.encodedPassword ?? Self.encode(password: ""))</Value>
                  <PlainText>false</PlainText>
                </Password>
              </AutoLogon>
        """
    }

    /// At the first sign-in, after NVDA installs and before it starts:
    /// NVDA's own settings file (configobj) with the laptop layout, only if
    /// NVDA is there and has no settings yet. NVDA's welcome dialog then
    /// shows laptop already chosen.
    private var nvdaSettings: String {
        guard nvdaLaptopLayout ?? true else { return "" }
        return """
        <SynchronousCommand wcm:action="add">
                  <Order>2</Order>
                  <Description>AVM: NVDA laptop keyboard layout</Description>
                  <CommandLine>cmd /c if exist "%ProgramFiles%\\NVDA\\nvda.exe" if not exist "%APPDATA%\\nvda\\nvda.ini" (mkdir "%APPDATA%\\nvda" 2&gt;nul &amp; (echo [keyboard]&amp; echo keyboardLayout = laptop)&gt;"%APPDATA%\\nvda\\nvda.ini")</CommandLine>
                </SynchronousCommand>
        """
    }

    private var timeZoneAndAccounts: String {
        var parts: [String] = []
        if let timeZone {
            parts.append("<TimeZone>\(Self.xml(timeZone))</TimeZone>")
        }
        if let account = localAccount {
            parts.append("""
            <UserAccounts>
                    <LocalAccounts>
                      <LocalAccount wcm:action="add">
                        <Name>\(Self.xml(account.userName))</Name>
                        <DisplayName>\(Self.xml(account.displayName))</DisplayName>
                        <Group>Administrators</Group>
                        <Password>
                          <Value>\(account.encodedPassword ?? Self.encode(password: ""))</Value>
                          <PlainText>false</PlainText>
                        </Password>
                      </LocalAccount>
                    </LocalAccounts>
                  </UserAccounts>
            """)
        }
        return parts.joined(separator: "\n      ")
    }

    // MARK: Storage

    static let fileName = "windows-setup.json"

    /// Owner-only, as UbuntuAccount: the password's encoding is in it.
    func save(inVMDirectory dir: URL) throws {
        let data = try JSONEncoder().encode(self)
        let path = dir.appendingPathComponent(Self.fileName).path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }

    static func load(fromVMDirectory dir: URL) -> WindowsSetupAnswers? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(WindowsSetupAnswers.self, from: data)
    }

    /// Once the media is built the password's encoding is no longer needed.
    static func forgetPassword(inVMDirectory dir: URL) {
        guard var answers = load(fromVMDirectory: dir), answers.localAccount?.encodedPassword != nil else { return }
        answers.localAccount?.encodedPassword = nil
        try? answers.save(inVMDirectory: dir)
    }
}
