// WindowsAppList.swift
// AVM — Accessible Virtual Machine
//
// The apps Install Apps offers (2026-11-03, the user's request), and what's
// decided from winget's public package manifests: which installer suits
// this machine, and the PowerShell that fetches it, checks it and runs it
// silently. Apart from the window (InstallApps.swift), so the logic tests
// reach it.
//
// Not winget itself: it isn't there for the guest agent's SYSTEM account. Its
// manifests say the same things, and each installer comes straight from its
// maker to Windows, checked against the manifest's SHA-256.

import Foundation

nonisolated struct WindowsApp: Sendable, Hashable, Identifiable {
    let name: String
    let what: String
    /// winget's package ID.
    let id: String
    /// How its entry in Windows' installed list starts.
    let listedAs: String

    /// Where its releases are in microsoft/winget-pkgs.
    var manifestFolder: String {
        "manifests/\(id.prefix(1).lowercased())/" + id.replacingOccurrences(of: ".", with: "/")
    }

    /// Each one really installed in Windows on ARM on 2026-11-03: a machine-wide
    /// installer that runs with no questions. Not Adobe Acrobat Reader: its
    /// installer ended at 0 with nothing in Windows' list. Nor Office, which is
    /// its own installer and needs a sign-in.
    static let all: [WindowsApp] = [
        WindowsApp(name: "Google Chrome", what: "Web browser", id: "Google.Chrome", listedAs: "Google Chrome"),
        WindowsApp(name: "Mozilla Firefox", what: "Web browser", id: "Mozilla.Firefox", listedAs: "Mozilla Firefox"),
        WindowsApp(name: "Mozilla Thunderbird", what: "Email", id: "Mozilla.Thunderbird", listedAs: "Mozilla Thunderbird"),
        WindowsApp(name: "LibreOffice", what: "Documents and spreadsheets", id: "TheDocumentFoundation.LibreOffice", listedAs: "LibreOffice"),
        WindowsApp(name: "Zoom", what: "Video meetings", id: "Zoom.Zoom", listedAs: "Zoom"),
        WindowsApp(name: "VLC", what: "Audio and video player", id: "VideoLAN.VLC", listedAs: "VLC media player"),
        WindowsApp(name: "Audacity", what: "Audio editor", id: "Audacity.Audacity", listedAs: "Audacity"),
        WindowsApp(name: "7-Zip", what: "Compressed files", id: "7zip.7zip", listedAs: "7-Zip"),
        WindowsApp(name: "Notepad++", what: "Text editor", id: "Notepad++.Notepad++", listedAs: "Notepad++"),
        WindowsApp(name: "Visual Studio Code", what: "Code editor", id: "Microsoft.VisualStudioCode", listedAs: "Microsoft Visual Studio Code"),
        WindowsApp(name: "Git", what: "Version control", id: "Git.Git", listedAs: "Git"),
        WindowsApp(name: "Python", what: "Programming language", id: "Python.Python.3.13", listedAs: "Python 3.13"),
    ]

    /// `Git`, not `GitHub Desktop`: what follows the name isn't more of a word.
    func isListed(in names: [String]) -> Bool {
        names.contains { name in
            guard name.hasPrefix(listedAs) else { return false }
            guard let next = name.dropFirst(listedAs.count).first else { return true }
            return !next.isLetter && !next.isNumber
        }
    }
}

/// One installer a manifest offers.
nonisolated struct WindowsAppInstaller: Sendable, Equatable {
    let url: URL
    let sha256: String
    let type: String
    let arguments: String
    let successCodes: [Int]
}

nonisolated enum WindowsAppManifest {
    /// The best installer for Windows on ARM: its own build, else x64 by
    /// emulation, else x86. Machine-wide (the agent is SYSTEM, whose own
    /// profile no one signs in to), HTTPS, with a checksum, and a kind that
    /// runs silently. Nil when none is.
    static func installer(yaml: String) -> WindowsAppInstaller? {
        let (root, entries) = blocks(yaml)
        func value(_ key: String, _ entry: [String: String]) -> String? { entry[key] ?? root[key] }
        for architecture in ["arm64", "x64", "x86"] {
            let suitable = entries.filter { entry in
                guard entry["Architecture"] == architecture,
                      let type = value("InstallerType", entry)?.lowercased(),
                      value("NestedInstallerType", entry) == nil,
                      let link = entry["InstallerUrl"].flatMap(URL.init(string:)), link.scheme == "https",
                      entry["InstallerSha256"]?.count == 64,
                      arguments(type: type, silent: value("Silent", entry), scope: value("Scope", entry)) != nil else { return false }
                let scope = value("Scope", entry)?.lowercased()
                return scope == nil || scope == "machine"
            }
            let locale = suitable.first { ["en-US", nil].contains(value("InstallerLocale", $0)) }
            guard let entry = locale ?? suitable.first,
                  let type = value("InstallerType", entry)?.lowercased(),
                  let link = entry["InstallerUrl"].flatMap(URL.init(string:)),
                  let sha = entry["InstallerSha256"],
                  var arguments = arguments(type: type, silent: value("Silent", entry), scope: value("Scope", entry)) else { continue }
            if let custom = value("Custom", entry) { arguments += " " + custom }
            let codes = (value("InstallerSuccessCodes", entry) ?? "").split(separator: ",").compactMap { Int($0) }
            return WindowsAppInstaller(url: link, sha256: sha.uppercased(), type: type, arguments: arguments, successCodes: [0, 3010, 1641] + codes)
        }
        return nil
    }

    /// The manifest's own silent switches, else what its kind of installer takes.
    private static func arguments(type: String, silent: String?, scope: String?) -> String? {
        let allUsers = type == "inno" && scope?.lowercased() == "machine" ? " /ALLUSERS" : ""
        if let silent { return silent + allUsers }
        switch type {
        case "msi", "wix": return "/qn /norestart"
        case "burn": return "/quiet /norestart InstallAllUsers=1"
        case "nullsoft": return "/S"
        case "inno": return "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" + allUsers
        default: return nil
        }
    }

    /// Top-level keys, and each installer's keys. Only the shape winget's
    /// manifests have: an entry starts with "- " at its margin, and a list
    /// under a key (the success codes) is joined with commas.
    private static func blocks(_ yaml: String) -> (root: [String: String], entries: [[String: String]]) {
        var root: [String: String] = [:]
        var entries: [[String: String]] = []
        var inInstallers = false
        var listKey: String?
        func put(_ key: String, _ value: String) {
            if inInstallers, !entries.isEmpty { entries[entries.count - 1][key] = value } else { root[key] = value }
        }
        var skipUnder: Int?
        for raw in yaml.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") || raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if raw.hasPrefix("Installers:") { inInstallers = true; listKey = nil; skipUnder = nil; continue }
            // A key's own nested things (AppsAndFeaturesEntries has an
            // InstallerType of its own) aren't the installer's.
            let indent = raw.prefix { $0 == " " }.count
            if let under = skipUnder {
                if indent > under || (indent == under && raw.dropFirst(indent).hasPrefix("- ")) { continue }
                skipUnder = nil
            }
            var line = raw
            if inInstallers, line.hasPrefix("- ") {
                entries.append([:])
                line = "  " + line.dropFirst(2)
                listKey = nil
            }
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("- ") {
                if let listKey {
                    let item = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let current = inInstallers && !entries.isEmpty ? entries[entries.count - 1][listKey] : root[listKey]
                    put(listKey, current.map { $0 + "," + item } ?? item)
                }
                continue
            }
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[..<colon])
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            listKey = value.isEmpty && key == "InstallerSuccessCodes" ? key : nil
            if value.isEmpty, key != "InstallerSuccessCodes", key != "InstallerSwitches" { skipUnder = line.prefix { $0 == " " }.count }
            if !value.isEmpty { put(key, value) }
        }
        return (root, entries)
    }

    /// Fetches, checks and runs it, as SYSTEM with no window. Its last line is
    /// `AVM-INSTALL ok CODE`, `AVM-INSTALL failed CODE`, `AVM-INSTALL checksum`
    /// or `AVM-INSTALL download`.
    static func script(_ installer: WindowsAppInstaller) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let kind = installer.type == "msi" || installer.type == "wix" ? "msi" : "exe"
        return """
        $ProgressPreference = 'SilentlyContinue'; $ErrorActionPreference = 'Stop'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $dir = Join-Path $env:TEMP ('avm-app-' + [guid]::NewGuid()); New-Item -ItemType Directory $dir | Out-Null
        $file = Join-Path $dir 'setup.\(kind)'
        try {
            try { Invoke-WebRequest -UseBasicParsing -Uri \(quoted(installer.url.absoluteString)) -OutFile $file } catch { 'AVM-INSTALL download'; exit }
            if ((Get-FileHash $file -Algorithm SHA256).Hash -ne \(quoted(installer.sha256))) { 'AVM-INSTALL checksum'; exit }
            $args = \(quoted(installer.arguments))
            if (\(quoted(kind)) -eq 'msi') { $p = Start-Process msiexec.exe -ArgumentList ('/i "' + $file + '" ' + $args) -Wait -PassThru }
            else { $p = Start-Process $file -ArgumentList $args -Wait -PassThru }
            $ok = @(\(installer.successCodes.map(String.init).joined(separator: ","))) -contains $p.ExitCode
            'AVM-INSTALL ' + $(if ($ok) { 'ok' } else { 'failed' }) + ' ' + $p.ExitCode
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
        """
    }

    /// Everything in Windows' installed list, one name a line.
    static let installedListScript = """
    $ErrorActionPreference = 'SilentlyContinue'
    'HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*', 'HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' | ForEach-Object { (Get-ItemProperty $_).DisplayName } | Where-Object { $_ }
    """

    /// A script's result, from its output.
    enum Outcome: Equatable {
        case installed(restartNeeded: Bool)
        case failed(code: Int?)
        case checksum
        case download
        case noAnswer
    }

    static func outcome(of output: String) -> Outcome {
        guard let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("AVM-INSTALL ") }) else { return .noAnswer }
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        switch words.dropFirst().first {
        case "ok":
            let code = words.count > 2 ? Int(words[2]) : nil
            return .installed(restartNeeded: code == 3010 || code == 1641)
        case "checksum": return .checksum
        case "download": return .download
        default: return .failed(code: words.count > 2 ? Int(words[2]) : nil)
        }
    }

    static func encoded(_ script: String) -> String {
        Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
    }
}
