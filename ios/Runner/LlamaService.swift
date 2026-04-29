import Foundation
import Darwin
import os
import UIKit

#if canImport(llama)
import llama
#endif

/// Wraps the llama.cpp mtmd C API for SmolVLM2-500M on-device multimodal inference.
///
/// **Setup required before this works:**
/// 1. Build llama.xcframework: `./scripts/build_llama_ios.sh ~/path/to/llama.cpp`
/// 2. Add ios/Frameworks/llama.xcframework to the Runner target in Xcode
/// 3. Download model files via ModelDownloadManager (or manually place in Documents/models/)
#if canImport(llama)
final class LlamaService {

    static let shared = LlamaService()

    static let textModelFilename       = "SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
    static let visionProjectorFilename = "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"

    private var llamaModel: OpaquePointer?
    private var llamaCtx:   OpaquePointer?
    private var mtmdCtx:    OpaquePointer?
    private var isLoaded    = false
    private var memoryWarningCount = 0

    private init() {}

    func noteMemoryWarning() {
        memoryWarningCount += 1
    }

    // MARK: - Status

    func getModelStatus() -> String {
        if isLoaded            { return "loaded" }
        if modelsExistOnDisk() { return "ready" }
        return "not_downloaded"
    }

    func modelsExistOnDisk() -> Bool {
        let dir = Self.modelsDirectory()
        let textPath = dir.appendingPathComponent(Self.textModelFilename).path
        let projPath = dir.appendingPathComponent(Self.visionProjectorFilename).path
        return FileManager.default.fileExists(atPath: textPath)
            && FileManager.default.fileExists(atPath: projPath)
    }

    func readinessContext() -> [String: Any] {
        [
            "runtimeLinked": true,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": "iOS \(UIDevice.current.systemVersion)",
            "deviceModel": Self.deviceModelIdentifier(),
            "files": ModelDownloadManager.shared.getModelFileIntegrityReport(verifyHash: false),
        ]
    }

    static func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    // MARK: - Lifecycle

    func loadModel() async -> Bool {
        guard !isLoaded else { return true }
        guard modelsExistOnDisk() else {
            print("[LlamaService] Model files not on disk")
            return false
        }

        let dir      = Self.modelsDirectory()
        let textPath = dir.appendingPathComponent(Self.textModelFilename).path
        let projPath = dir.appendingPathComponent(Self.visionProjectorFilename).path

        return await Task.detached(priority: .userInitiated) {
            // ── 1. Load text model onto Metal GPU ─────────────────────────────
            var mparams          = llama_model_default_params()
            mparams.n_gpu_layers = 99
            guard let model = llama_model_load_from_file(textPath, mparams) else {
                print("[LlamaService] Failed to load text model")
                return false
            }

            // ── 2. Create inference context ────────────────────────────────────
            var cparams       = llama_context_default_params()
            cparams.n_ctx     = 4096
            cparams.n_batch   = 512
            cparams.n_threads = 4
            guard let ctx = llama_init_from_model(model, cparams) else {
                llama_model_free(model)
                print("[LlamaService] Failed to create llama context")
                return false
            }

            // ── 3. Load vision projector ───────────────────────────────────────
            var mmparams           = mtmd_context_params_default()
            mmparams.use_gpu       = true
            mmparams.n_threads     = 4
            mmparams.print_timings = false
            guard let mctx = mtmd_init_from_file(projPath, model, mmparams) else {
                llama_free(ctx)
                llama_model_free(model)
                print("[LlamaService] Failed to load vision projector")
                return false
            }

            self.llamaModel = model
            self.llamaCtx   = ctx
            self.mtmdCtx    = mctx
            self.isLoaded   = true
            print("[LlamaService] SmolVLM2-500M loaded")
            return true
        }.value
    }

    func unloadModel() {
        if let mctx = mtmdCtx    { mtmd_free(mctx);        mtmdCtx    = nil }
        if let ctx  = llamaCtx   { llama_free(ctx);         llamaCtx   = nil }
        if let m    = llamaModel { llama_model_free(m);     llamaModel = nil }
        isLoaded = false
        print("[LlamaService] Model unloaded")
    }

    func runSelfTest(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        let startedAt = Date()
        let directory = Self.modelsDirectory()
        let warningCountBefore = memoryWarningCount
        var report: [String: Any] = [
            "llamaLinked": true,
            "runtimeLinked": true,
            "modelsDirectory": directory.path,
            "modelStatusBefore": getModelStatus(),
            "jpegBytes": jpegData.count,
            "jpegDecodeSuccess": UIImage(data: jpegData)?.cgImage != nil,
            "memoryBeforeBytes": Self.availableMemoryBytes(),
            "memoryWarningCountBefore": warningCountBefore,
            "textModel": Self.fileReport(filename: Self.textModelFilename),
            "visionProjector": Self.fileReport(filename: Self.visionProjectorFilename),
            "downloadInfo": ModelDownloadManager.shared.getModelInfo(),
        ]

        let loadStartedAt = Date()
        let loaded = await loadModel()
        report["loadSuccess"] = loaded
        report["loadLatencyMs"] = Self.elapsedMs(since: loadStartedAt)
        report["memoryAfterLoadBytes"] = Self.availableMemoryBytes()
        report["modelStatusAfterLoad"] = getModelStatus()

        guard loaded,
              let model = llamaModel,
              let ctx = llamaCtx,
              let mctx = mtmdCtx
        else {
            report["stage"] = "load"
            report["error"] = "SmolVLM2 did not load. Check linked runtime, file sizes, hashes, memory, and Metal availability."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }

        let bitmapStartedAt = Date()
        guard let bitmap: OpaquePointer = jpegData.withUnsafeBytes({ rawBuf in
            guard let ptr = rawBuf.baseAddress else { return nil }
            return mtmd_helper_bitmap_init_from_buf(
                mctx,
                ptr.assumingMemoryBound(to: UInt8.self),
                jpegData.count
            )
        }) else {
            report["stage"] = "jpeg_decode"
            report["bitmapDecodeSuccess"] = false
            report["bitmapDecodeLatencyMs"] = Self.elapsedMs(since: bitmapStartedAt)
            report["error"] = "mtmd failed to decode the JPEG."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }
        defer { mtmd_bitmap_free(bitmap) }
        report["bitmapDecodeSuccess"] = true
        report["bitmapDecodeLatencyMs"] = Self.elapsedMs(since: bitmapStartedAt)

        let marker = String(cString: mtmd_default_marker())
        let prompt = systemPrompt.isEmpty
            ? "Describe this image in one concise sentence."
            : systemPrompt
        let fullPrompt = "\(marker)\n\(prompt)"

        let tokenizeStartedAt = Date()
        guard let chunks = mtmd_input_chunks_init() else {
            report["stage"] = "tokenize"
            report["tokenizeResult"] = -999
            report["error"] = "Failed to allocate mtmd input chunks."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }
        defer { mtmd_input_chunks_free(chunks) }

        var tokenizeResult: Int32 = -1
        fullPrompt.withCString { cStr in
            var inputText = mtmd_input_text()
            inputText.text = cStr
            inputText.add_special = true
            inputText.parse_special = true

            var bitmapPtr: OpaquePointer? = bitmap
            withUnsafeMutablePointer(to: &bitmapPtr) { bitmapPtrPtr in
                tokenizeResult = mtmd_tokenize(mctx, chunks, &inputText, bitmapPtrPtr, 1)
            }
        }
        report["tokenizeResult"] = Int(tokenizeResult)
        report["tokenizeLatencyMs"] = Self.elapsedMs(since: tokenizeStartedAt)
        guard tokenizeResult == 0 else {
            report["stage"] = "tokenize"
            report["error"] = "mtmd_tokenize failed with code \(tokenizeResult)."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }

        let evalStartedAt = Date()
        var nPast: llama_pos = 0
        let evalResult = mtmd_helper_eval_chunks(mctx, ctx, chunks, 0, 0, 512, true, &nPast)
        report["imageEvalResult"] = Int(evalResult)
        report["imageEvalLatencyMs"] = Self.elapsedMs(since: evalStartedAt)
        guard evalResult == 0 else {
            report["stage"] = "image_eval"
            report["error"] = "mtmd image eval failed with code \(evalResult)."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }

        let generationStartedAt = Date()
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            report["stage"] = "sampler"
            report["error"] = "Failed to create llama sampler."
            report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
            report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
            return report
        }
        defer { llama_sampler_free(sampler) }

        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))

        let vocab = llama_model_get_vocab(model)
        var pieceBuffer = [CChar](repeating: 0, count: 256)
        var output = ""
        var outputTokenCount = 0
        var firstTokenLatencyMs: Int?
        var decodeResult = 0

        for _ in 0..<48 {
            let tokenId = llama_sampler_sample(sampler, ctx, -1)
            llama_sampler_accept(sampler, tokenId)
            if llama_vocab_is_eog(vocab, tokenId) { break }

            let n = llama_token_to_piece(vocab, tokenId, &pieceBuffer, Int32(pieceBuffer.count), 0, false)
            if n > 0 {
                let bytes = pieceBuffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
                if let piece = String(bytes: bytes, encoding: .utf8), !piece.isEmpty {
                    if firstTokenLatencyMs == nil {
                        firstTokenLatencyMs = Self.elapsedMs(since: generationStartedAt)
                    }
                    output += piece
                    outputTokenCount += 1
                }
            }

            var nextToken = tokenId
            withUnsafeMutablePointer(to: &nextToken) { tokenPtr in
                var batch = llama_batch_get_one(tokenPtr, 1)
                decodeResult = Int(llama_decode(ctx, batch))
            }
            if decodeResult != 0 { break }
            nPast += 1
        }

        llama_memory_clear(llama_get_memory(ctx), false)
        report["firstTokenLatencyMs"] = firstTokenLatencyMs ?? -1
        report["tokenCount"] = outputTokenCount
        report["generationLatencyMs"] = Self.elapsedMs(since: generationStartedAt)
        report["decodeResult"] = decodeResult
        report["outputPreview"] = String(output.prefix(240))
        report["sanitizedOutput"] = Self.sanitizeReadinessOutput(output)
        report["stage"] = outputTokenCount > 0 ? "complete" : "generation"
        if outputTokenCount == 0 {
            report["error"] = "SmolVLM2 completed eval but produced no text tokens."
        }
        report["totalLatencyMs"] = Self.elapsedMs(since: startedAt)
        report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
        report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
        return report
    }

    func runReadinessProbe(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        let startedAt = Date()
        let warningCountBefore = memoryWarningCount
        var report = readinessContext()
        let files = ModelDownloadManager.shared.getModelFileIntegrityReport(verifyHash: true)
        let filesPresent = files.allSatisfy {
            ($0["present"] as? Bool) == true && ($0["sizeMatches"] as? Bool) == true
        }
        let shaVerified = files.allSatisfy {
            ($0["shaVerified"] as? Bool) == true && ($0["valid"] as? Bool) == true
        }

        report["files"] = files
        report["runtimeLinked"] = true
        report["filesPresent"] = filesPresent
        report["shaVerified"] = shaVerified
        report["loadSuccess"] = false
        report["jpegBytes"] = jpegData.count
        report["memoryBeforeBytes"] = Self.availableMemoryBytes()
        report["memoryWarningCountBefore"] = warningCountBefore

        if !filesPresent || !shaVerified || Self.intValue(report["memoryBeforeBytes"]) < 1_100_000_000 {
            return Self.finishReadinessReport(report, startedAt: startedAt)
        }

        let selfTest = await runSelfTest(jpegData: jpegData, systemPrompt: systemPrompt)
        for (key, value) in selfTest {
            report[key] = value
        }
        report["files"] = files
        report["filesPresent"] = filesPresent
        report["shaVerified"] = shaVerified
        report["memoryWarningDuringProbe"] = memoryWarningCount != warningCountBefore
        if report["memoryAfterInferenceBytes"] == nil {
            report["memoryAfterInferenceBytes"] = Self.availableMemoryBytes()
        }
        return Self.finishReadinessReport(report, startedAt: startedAt)
    }

    // MARK: - Inference

    func describeImage(
        jpegData:      Data,
        systemPrompt:  String,
        visionContext: String?,
        onToken:       @escaping (String) -> Void,
        onComplete:    @escaping () -> Void,
        onError:       @escaping (String) -> Void
    ) async {
        guard isLoaded,
              let model = llamaModel,
              let ctx   = llamaCtx,
              let mctx  = mtmdCtx
        else {
            onError("SmolVLM2 not loaded — call loadModel() first")
            return
        }

        await Task.detached(priority: .userInitiated) {
            // ── 1. Decode JPEG → RGB bitmap ────────────────────────────────────
            guard let bitmap: OpaquePointer = jpegData.withUnsafeBytes({ rawBuf in
                guard let ptr = rawBuf.baseAddress else { return nil }
                return mtmd_helper_bitmap_init_from_buf(
                    mctx,
                    ptr.assumingMemoryBound(to: UInt8.self),
                    jpegData.count
                )
            }) else {
                onError("Failed to decode image")
                return
            }
            defer { mtmd_bitmap_free(bitmap) }

            // ── 2. Build prompt with image marker ──────────────────────────────
            // The Dart side passes the current hazard-first spoken contract in
            // `systemPrompt`; honour it instead of silently overriding with a
            // generic prompt. Fall back to the old blind-user prompt only when
            // no system prompt was supplied (legacy callers).
            let marker  = String(cString: mtmd_default_marker())
            let defaultUserMsg = visionContext.map { "\($0)\n\nDescribe this scene." }
                ?? "Describe this scene for a blind person. Use clock positions (12 o'clock = straight ahead, 3 o'clock = right, 9 o'clock = left). Be concise."
            let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullPrompt: String
            if trimmedSystem.isEmpty {
                fullPrompt = "\(marker)\n\(defaultUserMsg)"
            } else if let ctx = visionContext, !ctx.isEmpty {
                fullPrompt = "\(trimmedSystem)\n\n\(ctx)\n\n\(marker)\nDescribe this scene now."
            } else {
                fullPrompt = "\(trimmedSystem)\n\n\(marker)\nDescribe this scene now."
            }

            // ── 3. Tokenize ────────────────────────────────────────────────────
            guard let chunks = mtmd_input_chunks_init() else {
                onError("Failed to init input chunks")
                return
            }
            defer { mtmd_input_chunks_free(chunks) }

            var tokenizeOk: Int32 = -1
            fullPrompt.withCString { cStr in
                var inputText           = mtmd_input_text()
                inputText.text          = cStr
                inputText.add_special   = true
                inputText.parse_special = true

                var bitmapPtr: OpaquePointer? = bitmap
                withUnsafeMutablePointer(to: &bitmapPtr) { bitmapPtrPtr in
                    tokenizeOk = mtmd_tokenize(mctx, chunks, &inputText, bitmapPtrPtr, 1)
                }
            }
            guard tokenizeOk == 0 else {
                onError("Tokenize failed: \(tokenizeOk)")
                return
            }

            // ── 4. Encode image + prefill KV cache ─────────────────────────────
            var nPast: llama_pos = 0
            let evalRet = mtmd_helper_eval_chunks(mctx, ctx, chunks, 0, 0, 512, true, &nPast)
            guard evalRet == 0 else {
                onError("Image eval failed: \(evalRet)")
                return
            }

            // ── 5. Sampler chain ───────────────────────────────────────────────
            guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
                onError("Failed to create sampler")
                return
            }
            defer { llama_sampler_free(sampler) }

            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))

            let vocab = llama_model_get_vocab(model)

            // ── 6. Generate tokens ─────────────────────────────────────────────
            var pieceBuf = [CChar](repeating: 0, count: 256)

            for _ in 0..<300 {
                let tokenId = llama_sampler_sample(sampler, ctx, -1)
                llama_sampler_accept(sampler, tokenId)

                if llama_vocab_is_eog(vocab, tokenId) { break }

                let n = llama_token_to_piece(vocab, tokenId, &pieceBuf, Int32(pieceBuf.count), 0, false)
                if n > 0 {
                    let bytes = pieceBuf[0..<Int(n)].map { UInt8(bitPattern: $0) }
                    if let piece = String(bytes: bytes, encoding: .utf8), !piece.isEmpty {
                        onToken(piece)
                    }
                }

                var tid = tokenId
                var decodeResult = 0
                withUnsafeMutablePointer(to: &tid) { tidPtr in
                    var batch = llama_batch_get_one(tidPtr, 1)
                    decodeResult = Int(llama_decode(ctx, batch))
                }
                if decodeResult != 0 {
                    llama_memory_clear(llama_get_memory(ctx), false)
                    onError("Token decode failed: \(decodeResult)")
                    return
                }
                nPast += 1
            }

            // ── 7. Reset KV cache ──────────────────────────────────────────────
            llama_memory_clear(llama_get_memory(ctx), false)
            onComplete()
        }.value
    }

    private static func fileReport(filename: String) -> [String: Any] {
        let url = modelsDirectory().appendingPathComponent(filename)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return [
            "fileName": filename,
            "path": url.path,
            "present": exists,
            "sizeBytes": Int(fileSize(at: url)),
        ]
    }

    private static func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func finishReadinessReport(_ input: [String: Any], startedAt: Date) -> [String: Any] {
        var report = input
        report["totalLatencyMs"] = report["totalLatencyMs"] ?? elapsedMs(since: startedAt)
        report["memoryAfterLoadBytes"] = report["memoryAfterLoadBytes"] ?? availableMemoryBytes()
        report["memoryAfterInferenceBytes"] = report["memoryAfterInferenceBytes"] ?? availableMemoryBytes()
        let failure = readinessFailureReason(report)
        report["passed"] = failure == nil
        report["failureReason"] = failure ?? ""
        return report
    }

    private static func readinessFailureReason(_ report: [String: Any]) -> String? {
        let memoryBefore = intValue(report["memoryBeforeBytes"])
        let memoryAfterLoad = intValue(report["memoryAfterLoadBytes"])
        let memoryAfterInference = intValue(report["memoryAfterInferenceBytes"])
        let loadLatency = intValue(report["loadLatencyMs"])
        let firstTokenLatency = intValue(report["firstTokenLatencyMs"])
        let totalLatency = intValue(report["totalLatencyMs"])
        let tokenCount = intValue(report["tokenCount"])
        let output = report["sanitizedOutput"] as? String ?? report["outputPreview"] as? String ?? ""

        if boolValue(report["runtimeLinked"]) == false { return "llama runtime is not linked." }
        if boolValue(report["filesPresent"]) == false { return "SmolVLM2 model files are missing." }
        if boolValue(report["shaVerified"]) == false { return "SmolVLM2 model files did not match expected SHA-256." }
        if memoryBefore < 1_100_000_000 { return "Available memory before load is below 1.1 GB." }
        if boolValue(report["loadSuccess"]) == false { return "SmolVLM2 failed to load." }
        if loadLatency <= 0 || loadLatency > 20_000 { return "SmolVLM2 load exceeded the 20 second limit." }
        if memoryAfterLoad < 300_000_000 || memoryAfterInference < 300_000_000 {
            return "Available memory after probe is below 300 MB."
        }
        if boolValue(report["memoryWarningDuringProbe"]) == true {
            return "iOS reported memory pressure during the SmolVLM2 probe."
        }
        if firstTokenLatency <= 0 || firstTokenLatency > 25_000 {
            return "SmolVLM2 first token exceeded the 25 second limit."
        }
        if totalLatency <= 0 || totalLatency > 45_000 {
            return "SmolVLM2 self-test exceeded the 45 second limit."
        }
        if tokenCount <= 0 || !hasUsefulReadinessOutput(output) {
            return "SmolVLM2 output did not pass spoken quality checks."
        }
        return nil
    }

    private static func sanitizeReadinessOutput(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "" }
        if collapsed.range(of: #"[.!?]["')\]]*$"#, options: .regularExpression) != nil {
            return collapsed
        }
        return collapsed + "."
    }

    private static func hasUsefulReadinessOutput(_ text: String) -> Bool {
        let output = sanitizeReadinessOutput(text)
        let wordRegex = try? NSRegularExpression(pattern: #"[A-Za-z0-9']+"#)
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let words = wordRegex?.numberOfMatches(in: output, range: range) ?? 0
        if words < 8 { return false }
        let lower = output.lowercased()
        let banned = #"\b(smolvlm|llama|model|prompt|token|assistant|system|user|image\s+shows|as\s+an\s+ai)\b"#
        if lower.range(of: banned, options: .regularExpression) != nil { return false }
        let tokens = lower.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
        guard tokens.count >= 8 else { return false }
        for i in 0...(tokens.count - 8) {
            if tokens[i..<(i + 4)].joined(separator: " ") == tokens[(i + 4)..<(i + 8)].joined(separator: " ") {
                return false
            }
        }
        return true
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        let raw = "\(value ?? "")".lowercased()
        return raw == "true" || raw == "1" || raw == "yes"
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return Int("\(value ?? "")") ?? 0
    }

    private static func availableMemoryBytes() -> Int {
        let bytes: UInt64 = os_proc_available_memory()
        let maxIntBytes = UInt64(Int.max)
        if bytes > maxIntBytes {
            return Int.max
        }
        return Int(bytes)
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
#else
final class LlamaService {

    static let shared = LlamaService()

    static let textModelFilename       = "SmolVLM2-500M-Video-Instruct-Q8_0.gguf"
    static let visionProjectorFilename = "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"

    private init() {}

    func noteMemoryWarning() {}

    func getModelStatus() -> String {
        "not_available"
    }

    func modelsExistOnDisk() -> Bool {
        false
    }

    static func modelsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("models", isDirectory: true)
    }

    func readinessContext() -> [String: Any] {
        [
            "runtimeLinked": false,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "osVersion": "iOS \(UIDevice.current.systemVersion)",
            "deviceModel": Self.deviceModelIdentifier(),
            "files": ModelDownloadManager.shared.getModelFileIntegrityReport(verifyHash: false),
        ]
    }

    func loadModel() async -> Bool {
        print("[LlamaService] llama.xcframework is not linked; SmolVLM2 disabled")
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
        onError("SmolVLM2 is unavailable because llama.xcframework is not linked")
    }

    func runSelfTest(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        [
            "llamaLinked": false,
            "runtimeLinked": false,
            "modelsDirectory": Self.modelsDirectory().path,
            "modelStatusBefore": getModelStatus(),
            "modelStatusAfterLoad": getModelStatus(),
            "jpegBytes": jpegData.count,
            "jpegDecodeSuccess": UIImage(data: jpegData)?.cgImage != nil,
            "loadSuccess": false,
            "textModel": Self.fileReport(filename: Self.textModelFilename),
            "visionProjector": Self.fileReport(filename: Self.visionProjectorFilename),
            "stage": "runtime",
            "error": "SmolVLM2 is unavailable because llama.xcframework is not linked",
        ]
    }

    func runReadinessProbe(jpegData: Data, systemPrompt: String) async -> [String: Any] {
        var report = readinessContext()
        report["llamaLinked"] = false
        report["runtimeLinked"] = false
        report["filesPresent"] = false
        report["shaVerified"] = false
        report["loadSuccess"] = false
        report["memoryBeforeBytes"] = 0
        report["memoryAfterLoadBytes"] = 0
        report["memoryAfterInferenceBytes"] = 0
        report["loadLatencyMs"] = 0
        report["imageEvalLatencyMs"] = 0
        report["firstTokenLatencyMs"] = -1
        report["totalLatencyMs"] = 0
        report["tokenCount"] = 0
        report["sanitizedOutput"] = ""
        report["passed"] = false
        report["failureReason"] = "SmolVLM2 is unavailable because llama.xcframework is not linked"
        return report
    }

    private static func fileReport(filename: String) -> [String: Any] {
        let url = modelsDirectory().appendingPathComponent(filename)
        let exists = FileManager.default.fileExists(atPath: url.path)
        return [
            "fileName": filename,
            "path": url.path,
            "present": exists,
            "sizeBytes": Int(fileSize(at: url)),
        ]
    }

    private static func fileSize(at url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
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
#endif
