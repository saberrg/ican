import Flutter
import Foundation

/// Bridges Dart ↔ Swift for on-device vision and VLM inference.
/// Registers a MethodChannel for request/response calls and EventChannels
/// for streaming VLM tokens, Foundation Models tokens, and download progress.
final class OnDeviceVisionChannel: NSObject {

    static let methodChannelName            = "com.ican/on_device_vision"
    static let vlmStreamChannelName         = "com.ican/vlm_stream"
    static let fmStreamChannelName          = "com.ican/fm_stream"
    static let downloadProgressChannelName  = "com.ican/model_download_progress"

    private static var methodChannel:           FlutterMethodChannel?
    private static var vlmStreamChannel:        FlutterEventChannel?
    private static var fmStreamChannel:         FlutterEventChannel?
    private static var downloadProgressChannel: FlutterEventChannel?
    private static var registeredMessenger: AnyObject?

    // Event sinks for streaming data back to Dart
    private static var vlmEventSink:      FlutterEventSink?
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

        let vlmStream = FlutterEventChannel(name: vlmStreamChannelName, binaryMessenger: messenger)
        vlmStream.setStreamHandler(VlmStreamHandler())
        vlmStreamChannel = vlmStream

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

        // ── Layer 2: SmolVLM2 model lifecycle ────────────────────────────────
        case "getModelStatus":
            if ModelDownloadManager.shared.isDownloading {
                result("downloading")
            } else {
                result(LlamaService.shared.getModelStatus())
            }

        case "loadModel":
            Task {
                let success = await LlamaService.shared.loadModel()
                DispatchQueue.main.async { result(success) }
            }

        case "unloadModel":
            LlamaService.shared.unloadModel()
            result(true)

        case "describeImage":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            let args         = call.arguments as? [String: Any] ?? [:]
            let systemPrompt = args["systemPrompt"] as? String ?? ""
            let visionCtx    = args["visionContext"] as? String

            Task {
                await LlamaService.shared.describeImage(
                    jpegData:      imageBytes,
                    systemPrompt:  systemPrompt,
                    visionContext: visionCtx,
                    onToken: { token in
                        DispatchQueue.main.async { vlmEventSink?(token) }
                    },
                    onComplete: {
                        DispatchQueue.main.async { vlmEventSink?(FlutterEndOfEventStream) }
                    },
                    onError: { error in
                        DispatchQueue.main.async {
                            vlmEventSink?(FlutterError(code: "VLM_ERROR",
                                                       message: error,
                                                       details: nil))
                            vlmEventSink?(FlutterEndOfEventStream)
                        }
                    }
                )
                DispatchQueue.main.async { result(true) }
            }

        // ── SmolVLM2 download management ──────────────────────────────────────
        case "downloadModel":
            ModelDownloadManager.shared.startDownload { payload in
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

        case "cancelDownload":
            ModelDownloadManager.shared.cancelDownload()
            result(true)

        case "deleteModel":
            result(ModelDownloadManager.shared.deleteModel())

        case "getModelInfo":
            result(ModelDownloadManager.shared.getModelInfo())

        case "runSmolVlmSelfTest":
            guard let imageBytes = imageBytes(from: call, result: result) else { return }
            let args = call.arguments as? [String: Any] ?? [:]
            let systemPrompt = args["systemPrompt"] as? String ?? ""
            Task {
                let diagnostic = await LlamaService.shared.runSelfTest(
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

    private class VlmStreamHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            OnDeviceVisionChannel.vlmEventSink = events
            return nil
        }
        func onCancel(withArguments _: Any?) -> FlutterError? {
            OnDeviceVisionChannel.vlmEventSink = nil
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
