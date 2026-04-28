import Foundation

/// A single object detected in the scene with spatial context.
/// Produced by fusing YOLOv3 bounding boxes with Depth Anything V2 depth samples.
struct SpatialObject {
    let label: String
    let confidence: Float
    let normalizedCenterX: Float   // 0.0 (left) → 1.0 (right)
    let normalizedCenterY: Float   // 0.0 (top)  → 1.0 (bottom)
    let clockPosition: Int         // 9=hard-left, 12=center, 3=hard-right
    let relativeDepth: Float?      // nil if depth unavailable; 0.0=closest, 1.0=farthest
    let bboxX: Float               // image-space bounding box (top-left origin, normalised 0–1)
    let bboxY: Float
    let bboxW: Float
    let bboxH: Float

    /// Human-readable distance tier derived from relative depth.
    var distanceTier: String? {
        guard let d = relativeDepth else { return nil }
        switch d {
        case ..<0.30: return "very close"
        case 0.30..<0.50: return "close"
        case 0.50..<0.70: return "ahead"
        default: return "far"
        }
    }

    /// E.g. "person at 11 o'clock, close"
    var spatialLabel: String {
        var parts = ["\(label) at \(clockPosition) o'clock"]
        if let tier = distanceTier { parts.append(tier) }
        return parts.joined(separator: ", ")
    }
}

/// Full output from Layer 1 (Perception).
/// Combines Apple Vision Framework + Depth Anything V2 + YOLOv3 Tiny.
struct PerceptionResult {
    let ocrTexts: [String]
    let sceneClassification: String
    let sceneConfidence: Float
    let personCount: Int
    let detectedObjects: [SpatialObject]   // sorted closest-first by relativeDepth
    let hasDepthMap: Bool

    // MARK: - Prompt Context

    /// Build a structured text context string for injecting into VLM / Foundation Models prompts.
    func toPromptContext() -> String {
        var lines: [String] = []

        if sceneClassification != "unknown" && sceneConfidence > 0.15 {
            let label = sceneClassification.replacingOccurrences(of: "_", with: " ")
            lines.append("- Scene type: \(label) (\(Int(sceneConfidence * 100))% confidence)")
        }

        if personCount > 0 {
            lines.append("- People detected: \(personCount)")
        }

        // Safety-first: flag anything very close or close
        let closeObjects = detectedObjects.filter { ($0.relativeDepth ?? 1.0) < 0.50 }
        if !closeObjects.isEmpty {
            let desc = closeObjects.map(\.spatialLabel).joined(separator: "; ")
            lines.append("- Close obstacles: \(desc)")
        }

        // Remaining objects up to 6 (don't flood the prompt)
        let otherObjects = detectedObjects
            .filter { ($0.relativeDepth ?? 0.0) >= 0.50 }
            .prefix(6)
        if !otherObjects.isEmpty {
            let desc = otherObjects.map(\.spatialLabel).joined(separator: "; ")
            lines.append("- Nearby objects: \(desc)")
        }

        if !ocrTexts.isEmpty {
            let quoted = ocrTexts.prefix(4).map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("- Text visible: \(quoted)")
        }

        guard !lines.isEmpty else { return "" }
        return "Context from on-device sensors:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Channel Serialisation

    /// Serialise to a map for the Flutter platform channel.
    func toChannelMap() -> [String: Any] {
        var map: [String: Any] = [
            "ocr_texts": ocrTexts,
            "scene_classification": sceneClassification,
            "scene_confidence": sceneConfidence,
            "person_count": personCount,
            "has_depth_map": hasDepthMap,
            "detected_objects": detectedObjects.map { obj -> [String: Any] in
                var entry: [String: Any] = [
                    "label": obj.label,
                    "confidence": obj.confidence,
                    "clock_position": obj.clockPosition,
                    "center_x": obj.normalizedCenterX,
                    "center_y": obj.normalizedCenterY,
                    "bbox_x": obj.bboxX,
                    "bbox_y": obj.bboxY,
                    "bbox_w": obj.bboxW,
                    "bbox_h": obj.bboxH,
                ]
                if let d = obj.relativeDepth { entry["relative_depth"] = d }
                return entry
            },
        ]

        // Legacy keys for backward-compat with existing analyzeWithVision callers
        map["person_rects"] = [[String: Double]]()
        return map
    }

    // MARK: - Template Fallback

    /// Assemble a spoken description from Layer 1 data alone (no VLM required).
    /// Used as the final fallback when neither Foundation Models nor SmolVLM2 is available.
    func toTemplateDescription() -> String {
        var sentences: [String] = []

        // 1. WHERE
        if sceneClassification != "unknown" && sceneConfidence > 0.15 {
            let label = sceneClassification.replacingOccurrences(of: "_", with: " ")
            sentences.append("You appear to be in a \(label) setting.")
        } else {
            sentences.append("The scene type could not be clearly identified.")
        }

        // 2. SAFETY — close objects first
        let closeObjects = detectedObjects.filter { ($0.relativeDepth ?? 1.0) < 0.50 }
        if !closeObjects.isEmpty {
            let descs = closeObjects.prefix(3).map(\.spatialLabel).joined(separator: ", ")
            sentences.append("Caution: \(descs).")
        }

        // 3. PEOPLE
        if personCount > 0 {
            let noun = personCount == 1 ? "1 person is" : "\(personCount) people are"
            sentences.append("\(noun.capitalized) detected nearby.")
        }

        // 4. TEXT
        if !ocrTexts.isEmpty {
            if ocrTexts.count == 1 {
                sentences.append("Text reads: \(ocrTexts[0]).")
            } else {
                sentences.append("Visible text includes: \(ocrTexts.prefix(3).joined(separator: ", ")).")
            }
        }

        // 5. Other objects
        let otherObjects = detectedObjects
            .filter { ($0.relativeDepth ?? 0.0) >= 0.50 }
            .prefix(4)
        if !otherObjects.isEmpty {
            let descs = otherObjects.map(\.spatialLabel).joined(separator: ", ")
            sentences.append("Also nearby: \(descs).")
        }

        return sentences.joined(separator: " ")
    }
}
