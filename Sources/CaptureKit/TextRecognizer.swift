import CoreGraphics
import Vision

/// On-device OCR with Vision's `VNRecognizeTextRequest`.
public enum TextRecognizer {
    /// Returns recognised lines top-to-bottom, joined by newlines.
    public static func recognizeText(in image: CGImage, accurate: Bool = true) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let observations = request.results ?? []
        // Vision's coordinates are bottom-left origin, so a higher midY means higher on screen.
        return observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
