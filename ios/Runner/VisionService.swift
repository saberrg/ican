import Foundation
import Vision
import UIKit

/// Wraps Apple Vision framework APIs for on-device image analysis.
/// Runs OCR, scene classification, and person detection in parallel on the Neural Engine.
final class VisionService {
    private static let maxVisionDimension: CGFloat = 1600

    /// Analyze a JPEG image using Apple Vision framework.
    /// Returns structured results: OCR text, scene classification, and person count.
    static func analyze(jpegData: Data) async -> [String: Any] {
        let prepared = prepareImageForVision(jpegData: jpegData)
        guard let cgImage = prepared.cgImage else {
            NSLog("[VisionService] decode failed")
            return [
                "error": prepared.error ?? "Failed to decode image",
                "diagnostic_stage": "decode"
            ]
        }
        var warnings = prepared.warnings

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        let classificationRequest = VNClassifyImageRequest()

        let humanRequest = VNDetectHumanRectanglesRequest()
        if #available(iOS 15.0, *) {
            humanRequest.upperBodyOnly = false
        }

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest])
        } catch {
            let message = "ocr failed: \(error.localizedDescription)"
            warnings.append(message)
            NSLog("[VisionService] %@", message)
        }

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([classificationRequest])
        } catch {
            let message = "classification failed: \(error.localizedDescription)"
            warnings.append(message)
            NSLog("[VisionService] %@", message)
        }

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([humanRequest])
        } catch {
            let message = "person detection failed: \(error.localizedDescription)"
            warnings.append(message)
            NSLog("[VisionService] %@", message)
        }

        // --- Extract OCR results ---
        var ocrTexts: [String] = []
        if let textResults = textRequest.results {
            for observation in textResults {
                if let candidate = observation.topCandidates(1).first,
                   candidate.confidence > 0.5 {
                    ocrTexts.append(candidate.string)
                }
            }
        }

        // --- Extract scene classification ---
        var sceneClassification = "unknown"
        var sceneConfidence: Float = 0.0
        if let classResults = classificationRequest.results {
            // Get top classification with reasonable confidence
            if let topResult = classResults.first, topResult.confidence > 0.15 {
                sceneClassification = topResult.identifier
                sceneConfidence = topResult.confidence
            }
        }

        // --- Extract person detection ---
        var personCount = 0
        var personRects: [[String: Double]] = []
        if let humanResults = humanRequest.results {
            personCount = humanResults.count
            for observation in humanResults {
                let box = observation.boundingBox
                personRects.append([
                    "x": Double(box.origin.x),
                    "y": Double(box.origin.y),
                    "w": Double(box.size.width),
                    "h": Double(box.size.height),
                ])
            }
        }

        return [
            "ocr_texts": ocrTexts,
            "scene_classification": sceneClassification,
            "scene_confidence": sceneConfidence,
            "person_count": personCount,
            "person_rects": personRects,
            "vision_warnings": warnings,
            "diagnostic_stage": warnings.isEmpty ? "complete" : "partial",
            "image_width": cgImage.width,
            "image_height": cgImage.height,
        ]
    }

    private static func prepareImageForVision(jpegData: Data) -> (cgImage: CGImage?, warnings: [String], error: String?) {
        guard let image = UIImage(data: jpegData) else {
            return (nil, [], "Failed to decode image")
        }

        guard let originalCGImage = image.cgImage else {
            return (nil, [], "Decoded image did not contain CGImage data")
        }

        let width = CGFloat(originalCGImage.width)
        let height = CGFloat(originalCGImage.height)
        let longest = max(width, height)
        if longest <= maxVisionDimension {
            return (originalCGImage, [], nil)
        }

        let scale = maxVisionDimension / longest
        let targetSize = CGSize(
            width: max(1, floor(width * scale)),
            height: max(1, floor(height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let resizedCGImage = resized.cgImage else {
            return (originalCGImage, ["downscale failed; used original image"], nil)
        }

        let warning = "downscaled image from \(Int(width))x\(Int(height)) to \(Int(targetSize.width))x\(Int(targetSize.height))"
        NSLog("[VisionService] %@", warning)
        return (resizedCGImage, [warning], nil)
    }
}
