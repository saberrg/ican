import CryptoKit
import Foundation

/// Downloads and validates the Gemma 4 E2B LiteRT-LM `.litertlm` model file.
final class GemmaModelDownloadManager: NSObject {

    struct ModelFile {
        let name: String
        let url: String
        let sizeBytes: UInt64
        let sha256: String
    }

    static let shared = GemmaModelDownloadManager()

    private static let baseURL =
        "https://huggingface.co/\(GemmaLiteRtService.modelRepo)/resolve/\(GemmaLiteRtService.modelRevision)"
    private static let files: [ModelFile] = [
        ModelFile(
            name: GemmaLiteRtService.modelFilename,
            url: "\(baseURL)/\(GemmaLiteRtService.modelFilename)",
            sizeBytes: GemmaLiteRtService.modelSizeBytes,
            sha256: GemmaLiteRtService.modelSHA256
        ),
    ]

    private static let minimumFreeSpaceBufferBytes: Int64 = 300 * 1024 * 1024

    private var downloadTasks: [URLSessionDownloadTask] = []
    private var session: URLSession?
    private var progressCallback: (([String: Any]) -> Void)?
    private var completionCallback: ((Bool, String?) -> Void)?
    private var filesDownloaded = 0
    private var currentFileProgress: Double = 0
    private var completed = false

    private(set) var isDownloading = false

    private override init() {
        super.init()
    }

    func startDownload(
        onProgress: @escaping ([String: Any]) -> Void,
        onComplete: @escaping (Bool, String?) -> Void
    ) {
        guard !isDownloading else {
            onProgress(progressPayload(status: "downloading", phase: "already_running"))
            return
        }

        progressCallback = onProgress
        completionCallback = onComplete
        filesDownloaded = 0
        currentFileProgress = 0
        completed = false
        isDownloading = true

        let modelsDir = GemmaLiteRtService.modelsDirectory()
        do {
            try FileManager.default.createDirectory(
                at: modelsDir,
                withIntermediateDirectories: true
            )
            try excludeFromBackup(modelsDir)
            purgeLegacyModelFiles(in: modelsDir)
            try ensureFreeSpaceForMissingFiles(in: modelsDir)
        } catch {
            finish(success: false, error: error.localizedDescription)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.waitsForConnectivity = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        onProgress(progressPayload(status: "downloading", phase: "starting"))
        downloadNextFile()
    }

    func cancelDownload() {
        for task in downloadTasks {
            task.cancel()
        }
        downloadTasks.removeAll()
        session?.invalidateAndCancel()
        session = nil
        isDownloading = false
        progressCallback = nil
        completionCallback = nil
    }

    func deleteModel() -> Bool {
        let modelsDir = GemmaLiteRtService.modelsDirectory()
        do {
            if FileManager.default.fileExists(atPath: modelsDir.path) {
                try FileManager.default.removeItem(at: modelsDir)
            }
            return true
        } catch {
            print("[GemmaDownload] Failed to delete models: \(error)")
            return false
        }
    }

    func getModelInfo() -> [String: Any] {
        let modelsDir = GemmaLiteRtService.modelsDirectory()
        let fileStates = getModelFileIntegrityReport(verifyHash: false)
        let downloadedBytes = fileStates.reduce(UInt64(0)) { total, state in
            total + UInt64((state["sizeBytes"] as? Int) ?? 0)
        }
        let requiredBytes = Self.files.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let downloaded = fileStates.allSatisfy { ($0["downloaded"] as? Bool) == true }

        return [
            "downloaded": downloaded,
            "valid": downloaded,
            "downloading": isDownloading,
            "sizeBytes": Int(downloadedBytes),
            "requiredBytes": Int(requiredBytes),
            "path": modelsDir.path,
            "modelName": GemmaLiteRtService.modelName,
            "modelRepo": GemmaLiteRtService.modelRepo,
            "modelRevision": GemmaLiteRtService.modelRevision,
            "files": fileStates,
        ]
    }

    func getModelFileIntegrityReport(verifyHash: Bool) -> [[String: Any]] {
        let modelsDir = GemmaLiteRtService.modelsDirectory()
        return Self.files.map { file -> [String: Any] in
            let url = modelsDir.appendingPathComponent(file.name)
            let size = fileSize(at: url)
            let present = FileManager.default.fileExists(atPath: url.path)
            let sizeMatches = size == file.sizeBytes
            let valid = isFileValid(file, at: url, verifyHash: verifyHash)
            return [
                "name": file.name,
                "fileName": file.name,
                "present": present,
                "downloaded": valid,
                "valid": valid,
                "sizeMatches": sizeMatches,
                "shaVerified": verifyHash ? valid : false,
                "sizeBytes": Int(size),
                "expectedSizeBytes": Int(file.sizeBytes),
                "sha256": file.sha256,
            ]
        }
    }

    private func downloadNextFile() {
        guard filesDownloaded < Self.files.count else {
            let allValid = Self.files.allSatisfy {
                isFileValid(
                    $0,
                    at: GemmaLiteRtService.modelsDirectory().appendingPathComponent($0.name),
                    verifyHash: true
                )
            }
            finish(success: allValid, error: allValid ? nil : "Downloaded Gemma model validation failed.")
            return
        }

        let file = Self.files[filesDownloaded]
        let destURL = GemmaLiteRtService.modelsDirectory().appendingPathComponent(file.name)

        if isFileValid(file, at: destURL, verifyHash: true) {
            filesDownloaded += 1
            currentFileProgress = 0
            progressCallback?(progressPayload(status: "downloading", phase: "skipped", fileName: file.name))
            downloadNextFile()
            return
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        guard let url = URL(string: file.url) else {
            finish(success: false, error: "Invalid URL for \(file.name)")
            return
        }

        progressCallback?(progressPayload(status: "downloading", phase: "downloading", fileName: file.name))
        let task = session!.downloadTask(with: url)
        downloadTasks.append(task)
        task.resume()
    }

    private func finish(success: Bool, error: String?) {
        guard !completed else { return }
        completed = true
        isDownloading = false
        session?.finishTasksAndInvalidate()
        session = nil
        downloadTasks.removeAll()
        if success {
            progressCallback?(progressPayload(status: "complete", phase: "validated"))
        }
        completionCallback?(success, error)
    }

    private func progressPayload(
        status: String,
        phase: String,
        fileName: String? = nil
    ) -> [String: Any] {
        let progress = (Double(filesDownloaded) + currentFileProgress) / Double(Self.files.count)
        var payload: [String: Any] = [
            "status": status,
            "phase": phase,
            "progress": max(0, min(progress, 1)),
            "filesDownloaded": filesDownloaded,
            "totalFiles": Self.files.count,
            "requiredBytes": Int(Self.files.reduce(UInt64(0)) { $0 + $1.sizeBytes }),
        ]
        if let fileName {
            payload["fileName"] = fileName
        }
        return payload
    }

    private func ensureFreeSpaceForMissingFiles(in modelsDir: URL) throws {
        let missingBytes = Self.files.reduce(UInt64(0)) { total, file in
            let url = modelsDir.appendingPathComponent(file.name)
            return isFileValid(file, at: url, verifyHash: false) ? total : total + file.sizeBytes
        }
        let values = try modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let required = Int64(missingBytes) + Self.minimumFreeSpaceBufferBytes
        if available < required {
            throw NSError(
                domain: "GemmaModelDownloadManager",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Not enough free storage for Gemma local model. Need about \(formatBytes(UInt64(required)))."
                ]
            )
        }
    }

    private func isFileValid(_ file: ModelFile, at url: URL, verifyHash: Bool) -> Bool {
        let size = fileSize(at: url)
        guard size > 0 else {
            invalidateSidecar(for: url)
            return false
        }
        guard verifyHash else { return true }

        if let sidecar = readSidecar(for: url),
           sidecar.sizeBytes == size,
           sidecar.sha256.caseInsensitiveCompare(file.sha256) == .orderedSame,
           let mtime = fileModificationTime(at: url),
           abs(mtime.timeIntervalSince1970 - sidecar.mtimeEpoch) < 0.001 {
            return true
        }

        guard
            let actual = sha256Hex(of: url),
            actual.caseInsensitiveCompare(file.sha256) == .orderedSame
        else {
            invalidateSidecar(for: url)
            return false
        }
        if let mtime = fileModificationTime(at: url) {
            writeSidecar(
                for: url,
                entry: VerifiedSidecar(
                    sha256: file.sha256,
                    sizeBytes: size,
                    mtimeEpoch: mtime.timeIntervalSince1970
                )
            )
        }
        return true
    }

    private struct VerifiedSidecar {
        let sha256: String
        let sizeBytes: UInt64
        let mtimeEpoch: TimeInterval
    }

    private func sidecarURL(for url: URL) -> URL {
        url.appendingPathExtension("verified")
    }

    private func readSidecar(for url: URL) -> VerifiedSidecar? {
        let sidecar = sidecarURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard
            let sha = obj["sha256"] as? String,
            let size = (obj["size"] as? NSNumber)?.uint64Value,
            let mtime = (obj["mtime"] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        return VerifiedSidecar(sha256: sha, sizeBytes: size, mtimeEpoch: mtime)
    }

    private func writeSidecar(for url: URL, entry: VerifiedSidecar) {
        let sidecar = sidecarURL(for: url)
        let payload: [String: Any] = [
            "sha256": entry.sha256,
            "size": NSNumber(value: entry.sizeBytes),
            "mtime": NSNumber(value: entry.mtimeEpoch),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let tmp = sidecar.appendingPathExtension("tmp")
        do {
            if FileManager.default.fileExists(atPath: tmp.path) {
                try FileManager.default.removeItem(at: tmp)
            }
            try data.write(to: tmp, options: [.atomic])
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.removeItem(at: sidecar)
            }
            try FileManager.default.moveItem(at: tmp, to: sidecar)
            var mutable = sidecar
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        } catch {
            print("[GemmaDownload] Failed to persist sidecar for \(url.lastPathComponent): \(error)")
        }
    }

    private func invalidateSidecar(for url: URL) {
        let sidecar = sidecarURL(for: url)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    private func fileModificationTime(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    private func fileSize(at url: URL) -> UInt64 {
        GemmaLiteRtService.fileSize(at: url)
    }

    private func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func purgeLegacyModelFiles(in modelsDir: URL) {
        let expected = Set(Self.files.map { $0.name })
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            guard ext == "gguf" || ext == "litertlm" || ext == "verified" else { continue }
            if !expected.contains(name) && !expected.contains(url.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
                print("[GemmaDownload] Purged legacy model file: \(name)")
            }
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        return "\(Int(mb.rounded())) MB"
    }
}

extension GemmaModelDownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard filesDownloaded < Self.files.count else { return }

        let file = Self.files[filesDownloaded]
        let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            finish(success: false, error: "Download failed for \(file.name) with HTTP \(statusCode).")
            return
        }

        guard isFileValid(file, at: location, verifyHash: true) else {
            finish(success: false, error: "Downloaded \(file.name) did not match expected SHA-256.")
            return
        }

        let destURL = GemmaLiteRtService.modelsDirectory().appendingPathComponent(file.name)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)
            try excludeFromBackup(destURL)
            filesDownloaded += 1
            currentFileProgress = 0
            progressCallback?(progressPayload(status: "downloading", phase: "verified", fileName: file.name))
            downloadNextFile()
        } catch {
            finish(success: false, error: "Failed to save \(file.name): \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            currentFileProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let fileName = filesDownloaded < Self.files.count ? Self.files[filesDownloaded].name : nil
            progressCallback?(progressPayload(status: "downloading", phase: "downloading", fileName: fileName))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                print("[GemmaDownload] Download cancelled")
            } else {
                finish(success: false, error: error.localizedDescription)
            }
        }
    }
}
