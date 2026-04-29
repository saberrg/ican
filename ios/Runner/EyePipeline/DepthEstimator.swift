import CoreML
import Vision
import UIKit

/// Runs Depth Anything V2 Small (Apple CoreML) for monocular depth estimation.
///
/// **Setup:** Add `DepthAnythingV2SmallF16P6.mlpackage` to the Xcode project
/// (drag into Navigator → "Add to target: Runner"). If the model is absent the
/// estimator degrades gracefully — depth fields in PerceptionResult will be nil.
///
/// **Depth convention:** normalized output where 0.0 = closest, 1.0 = farthest.
final class DepthEstimator {

    static let shared = DepthEstimator()

    // Both variants accepted — P6 is preferred (smaller, same accuracy on Neural Engine).
    private static let preferredModelName = "DepthAnythingV2SmallF16P6"
    private static let fallbackModelName  = "DepthAnythingV2SmallF16"

    private var vnModel: VNCoreMLModel?
    private(set) var diagnostic: [String: Any] = [
        "name": preferredModelName,
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
        var sawBundle = false
        var sawCompiled = false
        for name in [Self.preferredModelName, Self.fallbackModelName] {
            let packageUrl = Bundle.main.url(forResource: name, withExtension: "mlpackage")
            let compiledUrl = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
            sawBundle = sawBundle || packageUrl != nil || compiledUrl != nil
            sawCompiled = sawCompiled || compiledUrl != nil
            if let url = compiledUrl ?? packageUrl {
                do {
                    let config = MLModelConfiguration()
                    config.computeUnits = .cpuAndNeuralEngine // Explicitly set to ANE
                    let mlModel = try MLModel(contentsOf: url, configuration: config)
                    vnModel = try VNCoreMLModel(for: mlModel)
                    diagnostic = [
                        "name": name,
                        "bundle_found": true,
                        "compiled_model_found": compiledUrl != nil,
                        "loaded": true,
                        "message": "\(name) loaded successfully."
                    ]
                    print("[DepthEstimator] Loaded \(name)")
                    return
                } catch {
                    diagnostic = [
                        "name": name,
                        "bundle_found": true,
                        "compiled_model_found": compiledUrl != nil,
                        "loaded": false,
                        "message": "\(name) failed to load: \(error.localizedDescription)"
                    ]
                    print("[DepthEstimator] Failed to load \(name): \(error)")
                }
            }
        }
        diagnostic = [
            "name": Self.preferredModelName,
            "bundle_found": sawBundle,
            "compiled_model_found": sawCompiled,
            "loaded": false,
            "message": sawBundle
                ? "Depth model was found but did not load."
                : "Depth model was not found in the app bundle."
        ]
        print("[DepthEstimator] No depth model found in bundle — depth estimation disabled")
    }

    // MARK: - Inference

    /// Estimate depth from a JPEG image.
    /// Returns nil if the model is unavailable or inference fails.
    func estimateDepth(jpegData: Data) async -> DepthMap? {
        guard let model = vnModel,
              let cgImage = UIImage(data: jpegData)?.cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { [weak self] req, error in
                guard error == nil else {
                    print("[DepthEstimator] Request error: \(error!)")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self?.extractDepthMap(from: req.results))
            }
            // scaleFill ensures the full image is passed regardless of aspect ratio
            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[DepthEstimator] Handler error: \(error)")
                continuation.resume(returning: nil)
            }
        }
    }

    /// Sample normalized depth at a point in top-left-origin image coords ([0,1] × [0,1]).
    func sampleDepth(_ map: DepthMap, at point: CGPoint) -> Float {
        let px = Int((point.x * CGFloat(map.width - 1)).rounded())
        let py = Int((point.y * CGFloat(map.height - 1)).rounded())
        let cx = max(0, min(map.width  - 1, px))
        let cy = max(0, min(map.height - 1, py))
        return map.values[cy * map.width + cx]
    }

    // MARK: - Private

    private func extractDepthMap(from results: [VNObservation]?) -> DepthMap? {
        guard let results else { return nil }

        // Depth Anything V2 returns a VNCoreMLFeatureValueObservation with an MLMultiArray
        if let featureObs = results.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first,
           let multiArray = featureObs.featureValue.multiArrayValue {
            return DepthMap(from: multiArray)
        }

        // Some model variants wrap output in a CVPixelBuffer observation
        if let pixelObs = results.compactMap({ $0 as? VNPixelBufferObservation }).first {
            return DepthMap(from: pixelObs.pixelBuffer)
        }

        print("[DepthEstimator] Unrecognised output type: \(results.map { type(of: $0) })")
        return nil
    }
}

// MARK: - DepthMap

/// Normalised depth map: values[y * width + x] ∈ [0, 1], where 0=closest, 1=farthest.
struct DepthMap {
    let width: Int
    let height: Int
    let values: [Float]

    /// Construct from an MLMultiArray output.
    /// Handles shapes [H, W], [1, H, W], [1, 1, H, W].
    init?(from multiArray: MLMultiArray) {
        let shape = multiArray.shape.map { $0.intValue }
        let (h, w): (Int, Int)
        switch shape.count {
        case 4:  (h, w) = (shape[2], shape[3])
        case 3:  (h, w) = (shape[1], shape[2])
        case 2:  (h, w) = (shape[0], shape[1])
        default: return nil
        }
        guard h > 0, w > 0 else { return nil }

        self.width  = w
        self.height = h

        let count = h * w
        var raw = [Float](repeating: 0, count: count)

        switch multiArray.dataType {
        case .float32:
            let ptr = multiArray.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count { raw[i] = ptr[i] }
        default:
            // Float16 and other types — use the safe NSNumber bridge
            for i in 0..<count { raw[i] = multiArray[i].floatValue }
        }

        self.values = DepthMap.normalize(raw)
    }

    /// Construct from a CVPixelBuffer (kCVPixelFormatType_DepthFloat32).
    init?(from pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let count = w * h
        let ptr = base.bindMemory(to: Float32.self, capacity: count)
        var raw = [Float](repeating: 0, count: count)
        for i in 0..<count { raw[i] = ptr[i] }

        self.width  = w
        self.height = h
        self.values = DepthMap.normalize(raw)
    }

    // MARK: - Normalisation

    /// Linear normalise values into [0, 1].
    private static func normalize(_ raw: [Float]) -> [Float] {
        guard let lo = raw.min(), let hi = raw.max(), hi > lo else { return raw }
        let range = hi - lo
        return raw.map { ($0 - lo) / range }
    }
}
