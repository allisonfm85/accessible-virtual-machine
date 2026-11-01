// DescribeScreen.swift
// AVM — Accessible Virtual Machine
//
// Describe Screen (2026-10-31, the user's request): Read Screen finds only
// text, so a firmware page, a picture, or an app a screen reader can't
// read gave nothing. Virtual Machine > Describe Screen says what the
// screen is like, two ways:
//   - On the Mac (always): Vision's text, by where it is on the screen,
//     and the screen's main colour (a blue stop screen, a black firmware
//     page). Nothing leaves the Mac. Not Vision's image labels: MEASURED
//     2026-10-31, a black Windows screen came back "night sky", which
//     would mislead someone who can't look.
//   - By Claude (off until turned on in Settings, with an API key): the
//     picture goes to Anthropic's API for a written description. AVM asks
//     before the first one for each machine, and remembers the answer.
//     If Claude can't answer, the Mac's description is said instead.
// The picture is QEMU's screendump, as Read Screen's; nothing is kept or
// logged but that a description was said.

import AppKit
import ImageIO

extension VMManager {

    /// Virtual Machine > Describe Screen.
    func describeScreen() async {
        let machine = machineName
        guard let path = await captureScreendump(),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Announcer.shared.announce("\(machine)'s screen couldn't be described. Next: make sure it's running, then try again.", tone: .failure)
            return
        }
        if UserDefaults.standard.bool(forKey: ClaudeDescribe.enabledKey), let key = ClaudeKey.load(), await mayUseClaude(for: machine) {
            Announcer.shared.announce("Asking Claude to describe \(machine)'s screen.", tone: .info)
            if let png = Self.png(image, longestSide: 1568) {
                switch await Self.askClaude(png: png, apiKey: key) {
                case .description(let text):
                    AVMLog.write("AVM: Describe Screen — described by Claude")
                    Announcer.shared.announce(text, tone: .info)
                    return
                case .declined:
                    Announcer.shared.announce("Claude didn't describe this screen. Here is the Mac's description.", tone: .info)
                case .failed(let why):
                    Announcer.shared.announce("Claude couldn't describe it: \(why) Here is the Mac's description.", tone: .info)
                }
            }
        }
        let text = await Task.detached(priority: .userInitiated) { Self.describeOnDevice(image) }.value
        AVMLog.write("AVM: Describe Screen — described on the Mac")
        Announcer.shared.announce(text, tone: .info)
    }

    /// Asks once per machine before its screen goes to Claude.
    private func mayUseClaude(for machine: String) async -> Bool {
        var allowed = Set(UserDefaults.standard.stringArray(forKey: ClaudeDescribe.allowedMachinesKey) ?? [])
        if allowed.contains(machine) { return true }
        let alert = NSAlert()
        alert.messageText = "Send \(machine)'s screen to Claude?"
        alert.informativeText = "Describe Screen can send a picture of \(machine)'s screen to Anthropic's Claude for a fuller description. Whatever is on the screen goes with it. Choose Use the Mac Only to describe it without anything leaving your Mac."
        alert.addButton(withTitle: "Send, and Don't Ask Again for \(machine)")
        alert.addButton(withTitle: "Use the Mac Only")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        allowed.insert(machine)
        UserDefaults.standard.set(Array(allowed), forKey: ClaudeDescribe.allowedMachinesKey)
        return true
    }

    nonisolated private static func askClaude(png: Data, apiKey: String) async -> ClaudeDescribe.Answer {
        do {
            let (data, response) = try await URLSession.shared.data(for: ClaudeDescribe.request(png: png, apiKey: apiKey))
            return ClaudeDescribe.answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The picture as PNG, scaled down so its longest side fits.
    nonisolated static func png(_ image: CGImage, longestSide: Int) -> Data? {
        let scale = min(1, Double(longestSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    /// Vision's text by where it is, and the screen's main colour.
    nonisolated static func describeOnDevice(_ image: CGImage) -> String {
        let lines = (ScreenText.lines(in: image) ?? []).map { (text: $0.text, y: Double($0.frame.midY) / Double(image.height)) }
        return ScreenDescription.onDevice(colour: averageColourName(image), lines: lines)
    }

    nonisolated private static func averageColourName(_ image: CGImage) -> String? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return ScreenDescription.colourName(r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
    }
}

/// The Anthropic API key for Describe Screen, in the keychain.
enum ClaudeKey {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "com.alllisonmeloy.AVM.anthropic",
                                               kSecAttrAccount as String: "api-key"]

    @discardableResult
    static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "AVM Describe Screen (Anthropic API key)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }
}
