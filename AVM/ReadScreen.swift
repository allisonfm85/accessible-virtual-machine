// ReadScreen.swift
// AVM — Accessible Virtual Machine
//
// Read Screen (2026-10-30, the user's request): the machine's screen read
// aloud by the Mac's own text recognition (Vision), for the times no screen
// reader runs in the guest: firmware and boot screens, Windows Setup before
// Narrator or NVDA starts, and recovery pages like "Why did my PC
// restart?", which sat silent on a test install that day. Without it a
// blind user needs VoiceOver's OCR or a sighted helper there.
//
// The picture comes from QEMU (screendump), so it's the machine's own
// screen at full size, whatever window is in front, even with no window.
// Lines are read top to bottom, left to right. Nothing is kept: the
// picture is overwritten at the next read, and the text isn't logged.

import Foundation
import ImageIO
import Vision

extension VMManager {

    /// The text on the machine's screen now, or nil when there's no picture.
    func readScreenText() async -> String? {
        guard let path = await captureScreendump() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.recognizeText(inPicture: URL(fileURLWithPath: path))
        }.value
    }

    /// Text in a picture file, top to bottom; "" when there is none.
    nonisolated static func recognizeText(inPicture url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ScreenText.lines(in: image)?.map(\.text).joined(separator: "\n")
    }
}

/// Lines of text in a picture, with where each is (2026-10-30): Read Screen
/// says them, and automatic macOS setup clicks the buttons it finds.
nonisolated enum ScreenText {
    struct Line {
        let text: String
        /// In the picture's own pixels, origin at the top left.
        let frame: CGRect
    }

    /// Top to bottom, left to right; nil when recognition failed.
    static func lines(in image: CGImage) -> [Line]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let observations = request.results ?? []
        // Vision's boxes have their origin at the bottom left: higher y is
        // nearer the top. Rows within a sliver of each other read as one.
        let sorted = observations.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.015 { return a.boundingBox.midY > b.boundingBox.midY }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return sorted.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Line(text: text, frame: CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h))
        }
    }
}
