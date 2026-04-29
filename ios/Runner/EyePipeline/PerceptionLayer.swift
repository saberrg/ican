import Foundation

/// Orchestrates the optional full spatial perception pass.
///
/// Live detection does not call this path. It is deliberately snapshot-only
/// because running Apple Vision, object detection, and depth estimation in
/// parallel has proven too easy to destabilize on iPhone.
final class PerceptionLayer {

    static let shared = PerceptionLayer()
    private init() {}

    // MARK: - Public API

    /// Run the full Layer 1 pipeline on a JPEG image.
    ///
    /// The analyzers are sequential to avoid concurrent Core ML memory spikes.
    /// Depth is skipped when object detection returns no objects, because the
    /// current fusion code only needs depth samples for detected boxes.
    func analyze(jpegData: Data) async -> PerceptionResult {
        let vision = await VisionService.analyze(jpegData: jpegData)
        let objects = await ObjectDetector.shared.detectObjects(jpegData: jpegData)
        let depth = objects.isEmpty
            ? nil
            : await DepthEstimator.shared.estimateDepth(jpegData: jpegData)

        let spatialObjects: [SpatialObject] = objects.map { obj in
            let center = obj.normalizedCenter
            let bbox = obj.imageSpaceBoundingBox
            let clock = clockHour(from: center.x)
            let relDepth = depth.map {
                DepthEstimator.shared.sampleDepth($0, at: center)
            }
            return SpatialObject(
                label: obj.label,
                confidence: obj.confidence,
                normalizedCenterX: Float(center.x),
                normalizedCenterY: Float(center.y),
                clockPosition: clock,
                relativeDepth: relDepth,
                bboxX: Float(bbox.origin.x),
                bboxY: Float(bbox.origin.y),
                bboxW: Float(bbox.width),
                bboxH: Float(bbox.height)
            )
        }
        .sorted { ($0.relativeDepth ?? 1.0) < ($1.relativeDepth ?? 1.0) }

        return PerceptionResult(
            ocrTexts: vision["ocr_texts"] as? [String] ?? [],
            sceneClassification: vision["scene_classification"] as? String ?? "unknown",
            sceneConfidence: (vision["scene_confidence"] as? NSNumber)?.floatValue ?? 0,
            personCount: vision["person_count"] as? Int ?? 0,
            detectedObjects: spatialObjects,
            hasDepthMap: depth != nil
        )
    }

    // MARK: - Clock Mapping

    private func clockHour(from normalizedX: CGFloat) -> Int {
        let hours = [9, 10, 11, 12, 1, 2, 3]
        let index = Int((normalizedX * CGFloat(hours.count - 1)).rounded())
        return hours[max(0, min(hours.count - 1, index))]
    }
}
