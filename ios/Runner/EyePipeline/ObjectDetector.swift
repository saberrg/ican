import CoreML
import Vision
import UIKit

/// Runs YOLOv3 Tiny (Apple CoreML) for real-time object detection.
///
/// **Setup:** Add `YOLOv3Tiny.mlmodel` to the Xcode project
/// (drag into Navigator → "Add to target: Runner"). If the model is absent the
/// detector degrades gracefully — detectedObjects in PerceptionResult will be empty.
///
/// Outputs up to `maxObjects` detections filtered at `confidenceThreshold`,
/// sorted highest-confidence first.
final class ObjectDetector {

    static let shared = ObjectDetector()

    private static let modelName = "YOLOv3Tiny"
    private let confidenceThreshold: Float = 0.35
    private let maxObjects = 12

    private var vnModel: VNCoreMLModel?
    private(set) var diagnostic: [String: Any] = [
        "name": modelName,
        "bundle_found": false,
        "compiled_model_found": false,
        "loaded": false,
        "message": "Model has not been checked yet."
    ]

    private init() {
        loadModel()
    }

    var isAvailable: Bool { vnModel != nil }

    // MARK: - Model Loading

    private func loadModel() {
        let sourceUrl = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodel")
        let compiledUrl = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc")
        guard let url = compiledUrl ?? sourceUrl else {
            diagnostic = [
                "name": Self.modelName,
                "bundle_found": false,
                "compiled_model_found": false,
                "loaded": false,
                "message": "\(Self.modelName) was not found in the app bundle."
            ]
            print("[ObjectDetector] \(Self.modelName).mlmodel not found in bundle — detection disabled")
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine // Explicitly set to ANE
            let mlModel = try MLModel(contentsOf: url, configuration: config)
            vnModel = try VNCoreMLModel(for: mlModel)
            diagnostic = [
                "name": Self.modelName,
                "bundle_found": sourceUrl != nil || compiledUrl != nil,
                "compiled_model_found": compiledUrl != nil,
                "loaded": true,
                "message": "\(Self.modelName) loaded successfully."
            ]
            print("[ObjectDetector] Loaded \(Self.modelName)")
        } catch {
            diagnostic = [
                "name": Self.modelName,
                "bundle_found": sourceUrl != nil || compiledUrl != nil,
                "compiled_model_found": compiledUrl != nil,
                "loaded": false,
                "message": "\(Self.modelName) failed to load: \(error.localizedDescription)"
            ]
            print("[ObjectDetector] Failed to load model: \(error)")
        }
    }

    // MARK: - Inference

    /// Detect objects in a JPEG image.
    /// Returns an empty array if the model is unavailable or inference fails.
    func detectObjects(jpegData: Data) async -> [DetectedObject] {
        guard let model = vnModel,
              let cgImage = UIImage(data: jpegData)?.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { [weak self] req, error in
                guard let self, error == nil else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: self.parseResults(req.results))
            }
            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[ObjectDetector] Handler error: \(error)")
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Private

    private func parseResults(_ results: [VNObservation]?) -> [DetectedObject] {
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            return []
        }

        return observations
            .compactMap { obs -> DetectedObject? in
                guard obs.confidence >= confidenceThreshold,
                      let topLabel = obs.labels.first else { return nil }
                return DetectedObject(
                    label: topLabel.identifier,
                    confidence: obs.confidence,
                    visionBoundingBox: obs.boundingBox   // Vision uses bottom-left origin
                )
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxObjects)
            .map { $0 }
    }
}

// MARK: - DetectedObject

/// A single YOLO detection with coordinate helpers.
struct DetectedObject {
    let label: String
    let confidence: Float
    /// Normalised bounding box in Vision coordinate space (bottom-left origin, y-up).
    let visionBoundingBox: CGRect

    /// Bounding box converted to standard image coords (top-left origin, y-down).
    var imageSpaceBoundingBox: CGRect {
        CGRect(
            x: visionBoundingBox.origin.x,
            y: 1.0 - visionBoundingBox.origin.y - visionBoundingBox.height,
            width:  visionBoundingBox.width,
            height: visionBoundingBox.height
        )
    }

    /// Centre point in top-left-origin image coords ([0,1] × [0,1]).
    /// Used to sample depth and derive clock position.
    var normalizedCenter: CGPoint {
        let box = imageSpaceBoundingBox
        return CGPoint(x: box.midX, y: box.midY)
    }
}
