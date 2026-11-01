// DescribeScreenLogic.swift
// AVM — Accessible Virtual Machine
//
// Describe Screen's pure parts (2026-10-31, the user's request): the words
// for what the Mac's own recognition found, and the request to Claude and
// its answer, for the optional description by Claude. DescribeScreen.swift
// takes the picture, asks, and speaks.

import Foundation

nonisolated enum ScreenDescription {

    /// What Vision found, in a few sentences: the screen's colour, how
    /// much text, and the text by where it is (top, middle, bottom).
    /// `lines` are the recognised lines with their vertical middle, 0 at
    /// the top and 1 at the bottom.
    static func onDevice(colour: String?, lines: [(text: String, y: Double)]) -> String {
        var parts: [String] = []
        let count = lines.count
        let amount = count == 0 ? "no text" : count == 1 ? "one line of text" : "\(count) lines of text"
        parts.append((colour.map { "A mostly \($0) screen with " } ?? "A screen with ") + amount + ".")
        for (name, range) in [("At the top", 0.0..<0.33), ("In the middle", 0.33..<0.67), ("At the bottom", 0.67..<1.01)] {
            let here = lines.filter { range.contains($0.y) }.map(\.text)
            guard !here.isEmpty else { continue }
            let shown = here.prefix(4).joined(separator: ". ")
            parts.append("\(name): \(shown)" + (here.count > 4 ? ", and \(here.count - 4) more lines." : "."))
        }
        return parts.joined(separator: " ")
    }

    /// The colour a screen is mostly, by name, from its average RGB (0-1).
    static func colourName(r: Double, g: Double, b: Double) -> String? {
        let high = max(r, g, b), low = min(r, g, b)
        if high < 0.15 { return "black" }
        if low > 0.85 { return "white" }
        if high - low < 0.08 { return high > 0.5 ? "light grey" : "dark grey" }
        if b == high && b > r + 0.15 && b > g + 0.05 { return low > 0.45 ? "light blue" : "blue" }
        if g == high && g > r + 0.1 && g > b + 0.1 { return "green" }
        if r == high && r > g + 0.2 && r > b + 0.2 { return "red" }
        return nil
    }
}

// MARK: - Described by Claude (opt-in)

nonisolated enum ClaudeDescribe {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5-5"
    /// Settings, Describe Screen: off until turned on.
    static let enabledKey = "AVMDescribeWithClaude"
    /// The machines whose screens the person agreed may go to Claude.
    static let allowedMachinesKey = "AVMDescribeWithClaudeMachines"

    static let prompt = """
        This is a screenshot of a virtual machine's screen, for a blind person who uses a screen reader. \
        Describe it in a few short sentences they can act on: what this screen is (which app, installer, \
        firmware or error), what it says that matters, what can be chosen or pressed and which is selected, \
        and what it seems to be waiting for. Read out any error or stop code exactly. Plain sentences, no \
        lists or markdown, under 120 words.
        """

    /// The Messages API request: the picture as a base64 PNG, then the ask.
    /// Low effort: a description, not a hard problem. "default" fallbacks
    /// re-run a declined request on Anthropic's recommended model.
    static func request(png: Data, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    enum Answer: Equatable {
        case description(String)
        case declined
        case failed(String)
    }

    /// The text blocks of a response, or why there's none.
    static func answer(status: Int, data: Data) -> Answer {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("Claude's answer couldn't be read (HTTP \(status)).")
        }
        if status != 200 {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            return .failed(status == 401 ? "Claude refused the API key. Check it in AVM's Settings." : message)
        }
        if json["stop_reason"] as? String == "refusal" { return .declined }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failed("Claude gave no description.") : .description(text)
    }
}
