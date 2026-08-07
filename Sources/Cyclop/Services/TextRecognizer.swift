import AppKit
import Vision

/// Reads the text out of a picture.
///
/// Vision, on the device, with no permission and no network — the same bargain
/// the translate tab already makes. Nothing is uploaded, which for a tool whose
/// whole job is pointed at whatever happens to be on the user's screen is not a
/// nice-to-have.
enum TextRecognizer {
    /// Languages Vision can actually read, in the order it prefers them.
    ///
    /// Asked of the framework rather than listed by hand: the set grows with
    /// macOS releases, and a hard-coded list would be a promise this app cannot
    /// keep on a machine newer than it.
    static let supported: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }()

    /// What the picker calls a language: "Русский", "English (US)".
    static func name(for identifier: String) -> String {
        let locale = Locale(identifier: appLanguage)
        if let name = locale.localizedString(forIdentifier: identifier) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return identifier
    }

    /// Reads `image`, honouring the chosen languages.
    ///
    /// An empty list means "whatever Vision would choose", which is driven by
    /// the user's own preferred languages and is right often enough to be the
    /// default. Naming a language is what rescues the cases where it is not:
    /// Cyrillic read as Latin comes back as confident nonsense rather than as
    /// an error, and no amount of retrying fixes it.
    static func recognize(_ image: CGImage, languages: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: assemble(observations))
            }
            request.recognitionLevel = .accurate
            // Vision's own dictionary correction. Worth it for prose, and the
            // thing that turns a smudged "rn" into "m"; it is also why a serial
            // number occasionally comes back spell-corrected, which is the
            // trade every OCR makes.
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            // Off the main thread: recognition on a full-screen grab takes long
            // enough to drop frames, and the editor is still on screen.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    NSLog("Cyclop: text recognition failed: \(error.localizedDescription)")
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Puts the fragments back into something a person would call text.
    ///
    /// Vision returns boxes, not paragraphs, and in no particular order. Sorted
    /// top to bottom and then left to right, two columns of a table come out as
    /// two columns rather than interleaved; boxes that share a line — the same
    /// vertical band — are joined with a space instead of a newline, which is
    /// what keeps a sentence broken across two boxes from becoming two lines.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let pieces = observations.compactMap { observation -> (CGRect, String)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, candidate.string)
        }
        guard !pieces.isEmpty else { return "" }

        // Vision's boxes are in a unit square with the origin at the bottom
        // left, so "higher on the page" is a larger y.
        let sorted = pieces.sorted { left, right in
            if abs(left.0.midY - right.0.midY) > 0.01 { return left.0.midY > right.0.midY }
            return left.0.minX < right.0.minX
        }

        var lines: [String] = []
        var current = ""
        var currentY: CGFloat?
        // A share of the box's own height, so the threshold scales with the
        // type: what counts as "the same line" is much tighter for a caption
        // than for a heading.
        for (box, text) in sorted {
            if let y = currentY, abs(y - box.midY) <= box.height * 0.6 {
                current += " " + text
            } else {
                if !current.isEmpty { lines.append(current) }
                current = text
            }
            currentY = box.midY
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }
}
