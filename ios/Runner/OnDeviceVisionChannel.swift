import Flutter
import Foundation

/// Bridges Dart ↔ Swift for on-device vision and Gemma inference.
/// Registers a MethodChannel for request/response calls and EventChannels
/// for streaming Gemma tokens, Foundation Models tokens, and download progress.
final class OnDeviceVisionChannel: NSObject {

    static let methodChannelName            = "com.ican/on_device_vision"
    static let gemmaStreamChannelName         = "com.ican/gemma_stream"
    static let fmStreamChannelName          = "com.ican/fm_stream"
    static let downloadProgressChannelName  = "com.ican/model_download_progress"

    private static var methodChannel:           FlutterMethodChannel?
    private static var gemmaStreamChannel:        FlutterEventChannel?
    private static var fmStreamChannel:         FlutterEventChannel?
    private static var downloadProgressChannel: FlutterEventChannel?
    private static var registeredMessenger: AnyObject?

    // Event sinks for streaming data back to Dart
    private static var gemmaEventSink:      FlutterEventSink?
    private static var fmEventSink:       FlutterEventSink?
    private static var downloadEventSink: FlutterEventSink?

    /// Call after the FlutterViewController exists.
    static func register(with messenger: FlutterBinaryMessenger) {
        let messengerObject = messenger as AnyObject
        if registeredMessenger === messengerObject { return }
        registeredMessenger = messengerObject

        let method = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        method.setMethodCallHandler(handleMethodCall)
        methodChannel = method

        let gemmaStream = FlutterEventChannel(name: gemmaStreamChannelName, binaryMessenger: messenger)
        gemmaStream.setStreamHandler(gemmaStreamHandler())
        gemmaStreamChannel = gemmaStream

        let fmStream = FlutterEventChannel(name: fmStreamChannelName, binaryMessenger: messenger)
        fmStream.setStreamHandler(FmStreamHandler())
        fmStreamChannel = fmStream

        let downloadStream = FlutterEventChannel(name: downloadProgressChannelName, binaryMessenger: messenger)
        downloadStream.setStreamHandler(DownloadProgressHandler())
        downloadProgressChannel = downloadStream
    }

    // MARK: - Method Call Dispatch

    private static func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ping":
            result(true)

        case "isAppleVisionAvailable":
            result(true)

        // ── Layer 1: Legacy Apple Vision (backward-compat) ───────────────────
        case "analyzeWithVision":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            Task {
                let analysis = await VisionService.analyze(jpegData: imageBytes)
                DispatchQueue.main.async { result(analysis) }
            }

        case "analyzeLiveFrame":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            Task {
                let analysis = await VisionService.analyze(jpegData: imageBytes)
                DispatchQueue.main.async { result(analysis) }
            }

        // ── Layer 1: Full perception pipeline (Vision + Depth + YOLO) ────────
        case "analyzeScene":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            Task {
                let perception = await PerceptionLayer.shared.analyze(jpegData: imageBytes)
                DispatchQueue.main.async { result(perception.toChannelMap()) }
            }

        // ── YOLOv3 object detection availability ──────────────────────────────
        case "isObjectDetectionAvailable":
            result(ObjectDetector.shared.isAvailable)

        // ── Depth Anything availability ─────────────────────────────────────
        case "isDepthEstimationAvailable":
            result(DepthEstimator.shared.isAvailable)

        case "getNativeModelDiagnostics":
            result([
                "object_detector": ObjectDetector.shared.diagnostic,
                "depth_estimator": DepthEstimator.shared.diagnostic
            ])

        // ── Layer 3: Foundation Models availability check ────────────────────
        case "isFoundationModelsAvailable":
            result(FoundationModelSynthesizer.isAvailable)

        // ── Layer 3: Why Foundation Models is (un)available ─────────────────
        case "foundationModelsAvailabilityReason":
            result(FoundationModelSynthesizer.availabilityReason)

        // ── Layer 3: Foundation Models synthesis (streams via fm_stream) ─────
        case "synthesizeDescription":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "context and systemPrompt required",
                                    details: nil))
                return
            }
            let context      = args["context"]      as? String ?? ""
            let systemPrompt = args["systemPrompt"] as? String ?? ""

            Task {
                await FoundationModelSynthesizer.shared.synthesize(
                    context:      context,
                    systemPrompt: systemPrompt,
                    onToken: { token in
                        DispatchQueue.main.async { fmEventSink?(token) }
                    },
                    onComplete: {
                        DispatchQueue.main.async { fmEventSink?(FlutterEndOfEventStream) }
                    },
                    onError: { error in
                        DispatchQueue.main.async {
                            fmEventSink?(FlutterError(code: "FM_ERROR",
                                                      message: error,
                                                      details: nil))
                            fmEventSink?(FlutterEndOfEventStream)
                        }
                    }
                )
                DispatchQueue.main.async { result(true) }
            }

        // ── Layer 2: Gemma 4 E2B model lifecycle ────────────────────────────────
        case "getGemmaStatus":
            if GemmaModelDownloadManager.shared.isDownloading {
                result("downloading")
            } else {
                result(GemmaLiteRtService.shared.getModelStatus())
            }

        case "loadGemmaModel":
            Task {
                let success = await GemmaLiteRtService.shared.loadModel()
                DispatchQueue.main.async { result(success) }
            }

        case "unloadGemmaModel":
            GemmaLiteRtService.shared.unloadModel()
            result(true)

        case "describeImageWithGemma":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            let args         = call.arguments as? [String: Any] ?? [:]
            let systemPrompt = args["systemPrompt"] as? String ?? ""
            let visionCtx    = args["visionContext"] as? String

            Task {
                // Ensure the model is resident in GPU memory before inference.
                // loadGemmaModel() is idempotent, so this is a no-op after the first
                // successful load in this app session. Without this, describes
                // that happened before any readiness probe silently no-op'd
                // with "Gemma 4 E2B not loaded — call loadGemmaModel() first".
                let loaded = await GemmaLiteRtService.shared.loadModel()
                guard loaded else {
                    DispatchQueue.main.async {
                        gemmaEventSink?(FlutterError(code: "GEMMA_NOT_LOADED",
                                                   message: "Gemma 4 E2B could not be loaded",
                                                   details: nil))
                        gemmaEventSink?(FlutterEndOfEventStream)
                        result(false)
                    }
                    return
                }
                await GemmaLiteRtService.shared.describeImage(
                    jpegData:      imageBytes,
                    systemPrompt:  systemPrompt,
                    visionContext: visionCtx,
                    onToken: { token in
                        DispatchQueue.main.async { gemmaEventSink?(token) }
                    },
                    onComplete: {
                        DispatchQueue.main.async { gemmaEventSink?(FlutterEndOfEventStream) }
                    },
                    onError: { error in
                        DispatchQueue.main.async {
                            gemmaEventSink?(FlutterError(code: "GEMMA_ERROR",
                                                       message: error,
                                                       details: nil))
                            gemmaEventSink?(FlutterEndOfEventStream)
                        }
                    }
                )
                DispatchQueue.main.async { result(true) }
            }

        // ── Gemma 4 E2B download management ──────────────────────────────────────
        case "downloadGemmaModel":
            GemmaModelDownloadManager.shared.startDownload { payload in
                DispatchQueue.main.async { downloadEventSink?(payload) }
            } onComplete: { success, error in
                DispatchQueue.main.async {
                    if success {
                        downloadEventSink?(["status": "complete"])
                    } else {
                        downloadEventSink?(FlutterError(code: "DOWNLOAD_ERROR",
                                                        message: error ?? "Unknown error",
                                                        details: nil))
                    }
                    downloadEventSink?(FlutterEndOfEventStream)
                }
            }
            result(true)

        case "cancelGemmaDownload":
            GemmaModelDownloadManager.shared.cancelDownload()
            result(true)

        case "deleteGemmaModel":
            result(GemmaModelDownloadManager.shared.deleteModel())

        case "getGemmaModelInfo":
            result(GemmaModelDownloadManager.shared.getModelInfo())

        case "getGemmaReadinessContext":
            result(GemmaLiteRtService.shared.readinessContext())

        case "runGemmaReadinessProbe":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            let args = call.arguments as? [String: Any] ?? [:]
            let systemPrompt = args["systemPrompt"] as? String ?? ""
            Task {
                let diagnostic = await GemmaLiteRtService.shared.runReadinessProbe(
                    jpegData: imageBytes,
                    systemPrompt: systemPrompt
                )
                DispatchQueue.main.async { result(diagnostic) }
            }

        case "runGemmaSelfTest":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            let args = call.arguments as? [String: Any] ?? [:]
            let systemPrompt = args["systemPrompt"] as? String ?? ""
            Task {
                let diagnostic = await GemmaLiteRtService.shared.runSelfTest(
                    jpegData: imageBytes,
                    systemPrompt: systemPrompt
                )
                DispatchQueue.main.async { result(diagnostic) }
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Helpers

    /// Extract `imageBytes` from a method call's arguments, sending an error on failure.
    private static func imageBytes(from call: FlutterMethodCall,
                                   result: FlutterResult) -> Data? {
        guard let args = call.arguments as? [String: Any],
              let typed = args["imageBytes"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "imageBytes (Uint8List) required",
                                details: nil))
            return nil
        }
        return typed.data
    }

    // MARK: - Event Stream Handlers

    private class gemmaStreamHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            OnDeviceVisionChannel.gemmaEventSink = events
            return nil
        }
        func onCancel(withArguments _: Any?) -> FlutterError? {
            OnDeviceVisionChannel.gemmaEventSink = nil
            return nil
        }
    }

    private class FmStreamHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            OnDeviceVisionChannel.fmEventSink = events
            return nil
        }
        func onCancel(withArguments _: Any?) -> FlutterError? {
            OnDeviceVisionChannel.fmEventSink = nil
            return nil
        }
    }

    private class DownloadProgressHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            OnDeviceVisionChannel.downloadEventSink = events
            return nil
        }
        func onCancel(withArguments _: Any?) -> FlutterError? {
            OnDeviceVisionChannel.downloadEventSink = nil
            return nil
        }
    }
}
