import Foundation

/// Layer 3 — Synthesises a natural-language scene description from structured
/// Layer 1 + Layer 2 context using Apple Foundation Models (iOS 26+).
///
/// **Availability:** Requires an Apple Intelligence-enabled device running iOS 26+.
/// On unsupported devices `isAvailable` returns false and the caller falls back
/// to the enhanced template description from `PerceptionResult.toTemplateDescription()`.
///
/// **API note:** The `FoundationModels` framework ships with the iOS 26 / Xcode 26 SDK.
/// The `#if canImport(FoundationModels)` guards keep this file compiling on earlier
/// SDKs without changes. Upgrade the guarded block when targeting iOS 26+.
final class FoundationModelSynthesizer {

    static let shared = FoundationModelSynthesizer()
    private init() {}

    // MARK: - Availability

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            // Runtime check — Apple Intelligence must be enabled and the system
            // language model must be downloaded on the device.
            return _foundationModelsAvailable()
        }
        #endif
        return false
    }

    /// String reason describing *why* Foundation Models is (un)available. Used
    /// by the Vision Diagnostic screen so the user can see whether they need
    /// to enable Apple Intelligence, wait for the system model to download, or
    /// accept that their device is not eligible.
    static var availabilityReason: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return _foundationModelsAvailabilityReason()
        }
        return "iosTooOld"
        #else
        return "frameworkMissing"
        #endif
    }

    // MARK: - Synthesis

    /// Generate a spoken scene description from structured context text.
    ///
    /// The `context` string comes from `PerceptionResult.toPromptContext()` and
    /// optionally includes a VLM caption. The `systemPrompt` is the shared
    /// spatial-awareness instruction used across all backends.
    ///
    /// Text is streamed sentence-by-sentence via `onToken` so TTS can begin
    /// before the full response is ready.
    func synthesize(
        context: String,
        systemPrompt: String,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            await _synthesizeWithFoundationModels(
                context:      context,
                systemPrompt: systemPrompt,
                onToken:      onToken,
                onComplete:   onComplete,
                onError:      onError
            )
            return
        }
        #endif
        onError("Foundation Models requires iOS 26 — falling back to template")
    }
}

// MARK: - iOS 26 Implementation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
private func _foundationModelsAvailable() -> Bool {
    if case .available = SystemLanguageModel.default.availability {
        return true
    }
    return false
}

@available(iOS 26.0, *)
private func _foundationModelsAvailabilityReason() -> String {
    switch SystemLanguageModel.default.availability {
    case .available:
        return "available"
    case .unavailable(let reason):
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceDisabled"
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .modelNotReady:
            return "modelDownloading"
        @unknown default:
            return "unknown"
        }
    }
}

@available(iOS 26.0, *)
private func _synthesizeWithFoundationModels(
    context:      String,
    systemPrompt: String,
    onToken:      @escaping (String) -> Void,
    onComplete:   @escaping () -> Void,
    onError:      @escaping (String) -> Void
) async {
    guard case .available = SystemLanguageModel.default.availability else {
        onError("Apple Intelligence is not available on this device")
        return
    }

    let session = LanguageModelSession(instructions: systemPrompt)
    let userPrompt = context.isEmpty
        ? "Describe this scene for a blind person."
        : "\(context)\n\nDescribe this scene for a blind person using clock positions for directions."

    do {
        var buffer = ""
        let stream = session.streamResponse(to: userPrompt)
        for try await partial in stream {
            buffer += String(describing: partial)

            // Flush complete sentences for TTS streaming
            while let range = buffer.range(of: "[.!?] ", options: .regularExpression) {
                let sentence = String(buffer[buffer.startIndex..<range.upperBound])
                onToken(sentence)
                buffer = String(buffer[range.upperBound...])
            }
        }
        if !buffer.isEmpty {
            onToken(buffer)
        }
        onComplete()
    } catch {
        onError(error.localizedDescription)
    }
}

#else

// Stubs so the non-guarded call sites still compile on pre-iOS 26 SDKs.
private func _foundationModelsAvailable() -> Bool { false }
private func _foundationModelsAvailabilityReason() -> String { "frameworkMissing" }

#endif
