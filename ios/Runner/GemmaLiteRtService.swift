import Foundation
import Darwin
import os
import UIKit

/// Native boundary for Google AI Edge LiteRT-LM Gemma image-to-text.
///
/// This file deliberately does not fake inference. Until the LiteRT-LM iOS
/// runtime is linked into Runner, readiness and self-test fail closed with a
/// copyable diagnostic. Model download/storage is real so devices can cache
/// the pinned `.litertlm` artifact before the runtime is connected.
final class GemmaLiteRtService {

    static let shared = GemmaLiteRtService()

    static let modelFilename = "gemma-4-E2B-it.litertlm"
    static let modelName = "Gemma 4 E2B IT LiteRT-LM"
    static let modelRepo = "litert-community/gemma-4-E2B-it-litert-lm"
    static let modelRevision = "7022fb75cac85d830562b14e8b583bdb7f8cb322"
    static let modelSizeBytes: UInt64 = 2_583_085_056
    static let modelSHA256 = "ab7838cdfc8f77e54d8ca45eadceb20452d9f01e4bfade03e5dce27911b27e42"

    private init() {}

    var runtimeLinked: Bool {
        false
    }

    func noteMemoryWarning() {}

    func getModelStatus() -> String {
        if modelExistsOnDisk() { return "ready" }
        return "not_downloaded"
    }

    func modelExistsOnDisk() -> Bool {
        let url = Self.modelURL()
        return FileManager.default.fileExists(atPath: url.path)
            && Self.fileSize(at: url) > 0
    }

    func readinessContext() -> [String: Any] {
        [
            "runtimeLinked": runtimeLinked,
            "liteRtLinked": runtimeLinked,
            "modelName": Self.modelName,
            "modelRepo": Self.modelRepo,
            "modelRevision": Self.modelRevision,
            "modelsDirectory": Self.modelsDirectory().path,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": "iOS \(UIDevice.current.systemVersion)",
            "deviceModel": Self.deviceModelIdentifier(),
            "files": GemmaModelDownloadManager.shared.getModelFileIntegrityReport(verifyHash: false),
        ]
    }

    static func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    static func modelURL() -> URL {
        modelsDirectory().appendingPathComponent(modelFilename)
    }

    func loadModel() async -> Bool {
        print("[GemmaLiteRT] LiteRT-LM runtime is not linked; Gemma inference disabled")
        return false
    }

    func unloadModel() {}

    func describeImage(
        jpegData: Data,
        systemPrompt: String,
        visionContext: String?,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) async {
        onError("Gemma 4 E2B is unavailable because LiteRT-LM iOS runtime is not linked")
    }

    func runSelfTest(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        [
            "liteRtLinked": runtimeLinked,
            "runtimeLinked": runtimeLinked,
            "modelsDirectory": Self.modelsDirectory().path,
            "modelStatusBefore": getModelStatus(),
            "modelStatusAfterLoad": getModelStatus(),
            "jpegBytes": jpegData.count,
            "jpegDecodeSuccess": UIImage(data: jpegData)?.cgImage != nil,
            "loadSuccess": false,
            "textModel": Self.fileReport(),
            "downloadInfo": GemmaModelDownloadManager.shared.getModelInfo(),
            "stage": "runtime",
            "error": "Gemma 4 E2B is unavailable because LiteRT-LM iOS runtime is not linked",
        ]
    }

    func runReadinessProbe(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        var report = readinessContext()
        let files = GemmaModelDownloadManager.shared.getModelFileIntegrityReport(verifyHash: true)
        let filesPresent = files.allSatisfy {
            ($0["present"] as? Bool) == true
        }
        let shaVerified = files.allSatisfy {
            ($0["shaVerified"] as? Bool) == true && ($0["valid"] as? Bool) == true
        }

        report["files"] = files
        report["runtimeLinked"] = runtimeLinked
        report["liteRtLinked"] = runtimeLinked
        report["filesPresent"] = filesPresent
        report["shaVerified"] = shaVerified
        report["loadSuccess"] = false
        report["jpegBytes"] = jpegData.count
        report["memoryBeforeBytes"] = Self.availableMemoryBytes()
        report["memoryAfterLoadBytes"] = Self.availableMemoryBytes()
        report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
        report["loadLatencyMs"] = 0
        report["imageEvalLatencyMs"] = 0
        report["firstTokenLatencyMs"] = -1
        report["totalLatencyMs"] = 0
        report["tokenCount"] = 0
        report["sanitizedOutput"] = ""
        report["passed"] = false
        report["failureReason"] = runtimeLinked
            ? "Gemma 4 E2B did not produce a passing readiness report."
            : "LiteRT-LM runtime is not linked."
        return report
    }

    private static func fileReport() -> [String: Any] {
        let url = modelURL()
        let exists = FileManager.default.fileExists(atPath: url.path)
        return [
            "fileName": modelFilename,
            "path": url.path,
            "present": exists,
            "sizeBytes": Int(fileSize(at: url)),
            "expectedSizeBytes": Int(modelSizeBytes),
            "sha256": modelSHA256,
        ]
    }

    static func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func availableMemoryBytes() -> Int {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int(bytes) : 0
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            identifier.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}
