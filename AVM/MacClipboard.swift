// MacClipboard.swift
// AVM — Accessible Virtual Machine
//
// Copy and paste between the Mac and a macOS machine (2026-10-26). Apple's
// Virtualization framework has no clipboard for macOS machines, so AVM
// shares one more folder with the machine, "AVM Clipboard", and both sides
// keep it in step:
//   - the Mac side (this file) writes what is copied on the Mac to
//     to-macos.txt, and puts what macOS wrote to from-macos.txt on the
//     Mac's clipboard;
//   - the macOS side is a small script that runs in the background
//     (a LaunchAgent), installed once by opening "Install Clipboard
//     Sharing.command" in the machine's Finder, in My Shared Files, AVM
//     Clipboard. It does the same with pbcopy and pbpaste.
// Text only. The files are readable by the user alone and are emptied
// when the machine stops; nothing is logged but that copying happened.
// Off when the machine's Share the Clipboard setting is off.

import AppKit

@MainActor
final class MacClipboard {

    static let folderName = "AVM Clipboard"
    private let folder: URL
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastFromMacOS: Date?

    private var toMacOS: URL { folder.appendingPathComponent("to-macos.txt") }
    private var fromMacOS: URL { folder.appendingPathComponent("from-macos.txt") }

    /// The folder to share with the machine, made ready.
    init(vmFolder: URL) throws {
        folder = vmFolder.appendingPathComponent("clipboard", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Emptied at every start, not only at a clean stop (2026-10-26, code
        // audit): after Quit Now or a crash the last copied text stayed on
        // disk and was pasted into macOS again at the next start.
        for file in [toMacOS, fromMacOS] {
            try? fm.removeItem(at: file)
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let installer = folder.appendingPathComponent("Install Clipboard Sharing.command")
        try Self.installerScript.write(to: installer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.path)
        lastFromMacOS = (try? fm.attributesOfItem(atPath: fromMacOS.path))?[.modificationDate] as? Date
    }

    var sharedDirectory: URL { folder }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        AVMLog.write("AVM: MacClipboard — sharing the clipboard with the macOS machine.")
    }

    /// Stops, and empties both files: nothing copied stays on disk.
    func stop() {
        timer?.invalidate()
        timer = nil
        for file in [toMacOS, fromMacOS] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Written fresh, never through what's there: macOS in the machine can
    /// change the shared folder, and a link put in a file's place would
    /// otherwise make AVM write over a file of the Mac's.
    private func writeFresh(_ text: String, to file: URL) {
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    /// A plain file's text, or nil for anything else (a link especially).
    private func readPlain(_ file: URL) -> String? {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.type] as? FileAttributeType,
              type == .typeRegular else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Copies password managers mark as secret or passing (the nspasteboard
    /// .org conventions Passwords and 1Password follow) stay on the Mac.
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private func sync() {
        let board = NSPasteboard.general
        // The Mac's clipboard changed: to macOS.
        if board.changeCount != lastChangeCount {
            lastChangeCount = board.changeCount
            let isPrivate = !(board.types.map(Set.init) ?? []).isDisjoint(with: Self.privateTypes)
            if !isPrivate, let text = board.string(forType: .string) {
                writeFresh(text, to: toMacOS)
            }
        }
        // macOS's clipboard changed: to the Mac.
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: fromMacOS.path))?[.modificationDate] as? Date,
              modified != lastFromMacOS else { return }
        lastFromMacOS = modified
        guard let text = readPlain(fromMacOS), !text.isEmpty,
              text != board.string(forType: .string) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
        lastChangeCount = board.changeCount   // not sent back
    }

    /// Run once in the machine. Puts the sync script in the user's Library
    /// and a LaunchAgent that keeps it running at every login.
    private static let installerScript = #"""
    #!/bin/bash
    # Installs AVM's clipboard sharing in this macOS machine. Run it once.
    set -e
    SHARE="/Volumes/My Shared Files/AVM Clipboard"
    [ -d "$SHARE" ] || SHARE="$(cd "$(dirname "$0")" && pwd)"
    DIR="$HOME/Library/Application Support/AVM Clipboard"
    AGENT="$HOME/Library/LaunchAgents/com.alllisonmeloy.avm-clipboard.plist"
    mkdir -p "$DIR" "$HOME/Library/LaunchAgents"
    cat > "$DIR/sync.sh" <<'SYNC'
    #!/bin/bash
    # AVM clipboard sharing: keeps this machine's clipboard and the Mac's in
    # step through the shared AVM Clipboard folder. Text only.
    SHARE="/Volumes/My Shared Files/AVM Clipboard"
    last_mine=""
    last_theirs=""
    while true; do
        if [ -d "$SHARE" ]; then
            # By content, not modification time: two Mac copies in the same
            # second share a time (2026-10-26, code audit).
            theirs=$(shasum "$SHARE/to-macos.txt" 2>/dev/null | cut -c1-40)
            if [ -n "$theirs" ] && [ "$theirs" != "$last_theirs" ]; then
                last_theirs="$theirs"
                if [ -s "$SHARE/to-macos.txt" ]; then
                    pbcopy < "$SHARE/to-macos.txt"
                    last_mine=$(pbpaste | shasum | cut -c1-40)
                fi
            fi
            mine=$(pbpaste | shasum | cut -c1-40)
            if [ "$mine" != "$last_mine" ]; then
                last_mine="$mine"
                pbpaste > "$SHARE/from-macos.txt"
            fi
        fi
        sleep 0.5
    done
    SYNC
    chmod 700 "$DIR/sync.sh"
    cat > "$AGENT" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>com.alllisonmeloy.avm-clipboard</string>
      <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DIR/sync.sh</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
    </dict></plist>
    PLIST
    launchctl bootout "gui/$(id -u)/com.alllisonmeloy.avm-clipboard" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    say "Clipboard sharing with your Mac is on. You can close this window."
    echo "Clipboard sharing with your Mac is on. You can close this window."
    """#
}
