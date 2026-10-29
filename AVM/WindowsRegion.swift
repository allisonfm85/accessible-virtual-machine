// WindowsRegion.swift
// AVM — Accessible Virtual Machine
//
// The Mac's region and keyboard, told to Windows Setup (2026-10-26), so
// OOBE skips its "Is this the right country or region?" and keyboard
// layout pages: two fewer screens to get through with Narrator alone.
// They go into the answer file's oobeSystem pass as the International-Core
// component (UserLocale, SystemLocale, InputLocale).
//
// Only what AVM is sure of is sent. A region that isn't a plain
// language-COUNTRY pair, or a keyboard missing from the table below,
// leaves that setting out, and Windows asks on that page as before;
// a wrong keyboard would be worse than one more question. The display
// language is never set here: it must be one the Windows ISO contains.

import Foundation
import Carbon

nonisolated struct WindowsRegion: Sendable, Equatable {
    /// "en-GB": the Mac's region, for UserLocale and SystemLocale.
    var locale: String?
    /// "0809:00000809": Windows' language:layout pair for the Mac keyboard.
    var inputLocale: String?

    /// Windows keyboard IDs for macOS keyboard layouts. Mac layouts that
    /// Windows has no Mac twin for map to the PC layout of the same name,
    /// as Windows' own Boot Camp does.
    struct Keyboard: Sendable, Equatable {
        /// Windows' language:layout pair, as InputLocale takes it.
        let id: String
        /// The layout's name in Windows, for the wizard.
        let name: String
    }

    static let keyboards: [String: Keyboard] = [
        "com.apple.keylayout.US": Keyboard(id: "0409:00000409", name: "U.S."),
        "com.apple.keylayout.ABC": Keyboard(id: "0409:00000409", name: "U.S."),
        "com.apple.keylayout.USExtended": Keyboard(id: "0409:00000409", name: "U.S."),
        "com.apple.keylayout.USInternational-PC": Keyboard(id: "0409:00020409", name: "U.S. International"),
        "com.apple.keylayout.Dvorak": Keyboard(id: "0409:00010409", name: "U.S. Dvorak"),
        "com.apple.keylayout.British": Keyboard(id: "0809:00000809", name: "British"),
        "com.apple.keylayout.British-PC": Keyboard(id: "0809:00000809", name: "British"),
        "com.apple.keylayout.Irish": Keyboard(id: "1809:00001809", name: "Irish"),
        "com.apple.keylayout.Canadian": Keyboard(id: "1009:00000409", name: "Canadian English"),
        "com.apple.keylayout.Canadian-CSA": Keyboard(id: "0c0c:00011009", name: "Canadian Multilingual"),
        "com.apple.keylayout.French": Keyboard(id: "040c:0000040c", name: "French"),
        "com.apple.keylayout.French-PC": Keyboard(id: "040c:0000040c", name: "French"),
        "com.apple.keylayout.Belgian": Keyboard(id: "080c:0000080c", name: "Belgian French"),
        "com.apple.keylayout.German": Keyboard(id: "0407:00000407", name: "German"),
        "com.apple.keylayout.SwissGerman": Keyboard(id: "0807:00000807", name: "Swiss German"),
        "com.apple.keylayout.SwissFrench": Keyboard(id: "100c:0000100c", name: "Swiss French"),
        "com.apple.keylayout.Austrian": Keyboard(id: "0c07:00000407", name: "German (Austria)"),
        "com.apple.keylayout.Spanish": Keyboard(id: "0c0a:0000040a", name: "Spanish"),
        "com.apple.keylayout.Spanish-ISO": Keyboard(id: "0c0a:0000040a", name: "Spanish"),
        "com.apple.keylayout.LatinAmerican": Keyboard(id: "080a:0000080a", name: "Latin American"),
        "com.apple.keylayout.Italian": Keyboard(id: "0410:00000410", name: "Italian"),
        "com.apple.keylayout.Italian-Pro": Keyboard(id: "0410:00000410", name: "Italian"),
        "com.apple.keylayout.Portuguese": Keyboard(id: "0816:00000816", name: "Portuguese"),
        "com.apple.keylayout.Brazilian": Keyboard(id: "0416:00000416", name: "Portuguese (Brazil ABNT)"),
        "com.apple.keylayout.Brazilian-ABNT2": Keyboard(id: "0416:00000416", name: "Portuguese (Brazil ABNT)"),
        "com.apple.keylayout.Dutch": Keyboard(id: "0413:00020409", name: "U.S. International (Dutch)"),
        "com.apple.keylayout.Danish": Keyboard(id: "0406:00000406", name: "Danish"),
        "com.apple.keylayout.Swedish": Keyboard(id: "041d:0000041d", name: "Swedish"),
        "com.apple.keylayout.Swedish-Pro": Keyboard(id: "041d:0000041d", name: "Swedish"),
        "com.apple.keylayout.Norwegian": Keyboard(id: "0414:00000414", name: "Norwegian"),
        "com.apple.keylayout.Finnish": Keyboard(id: "040b:0000041d", name: "Finnish"),
    ]

    /// "en_US" or "en-US" to "en-US"; anything else to nil.
    static func windowsLocale(fromMac identifier: String) -> String? {
        // "en_GB@rg=gbzzzz": keywords after "@" (region override, calendar)
        // are macOS's own and not part of the locale's name.
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? identifier
        let parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard parts.count >= 2,
              parts[0].range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    /// Each Windows layout once, by name, for the wizard's picker.
    static let windowsKeyboards: [Keyboard] = {
        var seen = Set<String>()
        return keyboards.values.sorted { $0.name < $1.name }.filter { seen.insert($0.id).inserted }
    }()

    /// The Mac's own region and keyboard. Main actor: Text Input Sources.
    @MainActor
    static func current() -> WindowsRegion {
        var region = WindowsRegion()
        region.locale = windowsLocale(fromMac: Locale.current.identifier)
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            region.inputLocale = keyboards[id]?.id
        }
        return region
    }

    /// The oobeSystem International-Core component, or "" when there is
    /// nothing certain to say.
    var answerFileComponent: String {
        guard locale != nil || inputLocale != nil else { return "" }
        var lines = [#"<component name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#]
        if let inputLocale { lines.append("  <InputLocale>\(inputLocale)</InputLocale>") }
        if let locale {
            lines.append("  <SystemLocale>\(locale)</SystemLocale>")
            lines.append("  <UserLocale>\(locale)</UserLocale>")
        }
        lines.append("</component>")
        return lines.joined(separator: "\n    ")
    }
}
