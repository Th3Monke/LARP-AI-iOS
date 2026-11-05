import Foundation

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let base: String          // the open model it's built on; never shown, only told if someone asks directly
    let size: String
    let bytes: Int64
    let minRAMGB: Double
    let note: String
    let url: URL
    let thinks: Bool          // can reason before answering (turned off with /no_think)
}

/// Phone-sized LARP.AI models, same names as on the PC (all run fully offline once downloaded).
let MODEL_CATALOG: [ModelInfo] = [
    ModelInfo(id: "gemma3-1b", name: "Scout 2.5", base: "Gemma 3 1B", size: "0.8 GB", bytes: 806_058_272, minRAMGB: 3,
              note: "The tiny, quick one. Works on almost any recent iPhone.", url: URL(string: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!, thinks: false),
    ModelInfo(id: "qwen3-1.7b", name: "Forge 3", base: "Qwen3 1.7B", size: "1.8 GB", bytes: 1_834_426_016, minRAMGB: 6,
              note: "Small but smart, good at reasoning and code.", url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf")!, thinks: true),
    ModelInfo(id: "gemma3-4b", name: "Oracle 3.5", base: "Gemma 3 4B", size: "2.5 GB", bytes: 2_489_757_856, minRAMGB: 8,
              note: "The best all-rounder that fits a phone. Needs 8 GB RAM (iPhone 15 Pro or newer).", url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!, thinks: false),
    ModelInfo(id: "qwen3-4b", name: "Forge 3.5", base: "Qwen3 4B", size: "2.5 GB", bytes: 2_497_280_256, minRAMGB: 8,
              note: "The thinker: great at reasoning and code. Needs 8 GB RAM (iPhone 15 Pro or newer).", url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!, thinks: true),
]

/// Scout 2.5 and Forge 3 are tiny: they get a simpler identity prompt (see AppState.identity).
let TINY_MODELS: Set<String> = ["gemma3-1b", "qwen3-1.7b"]
/// For tiny models: (pattern in the user's message, the exact answer to give). Same as the PC app.
let TINY_HINTS: [(String, (String) -> String)] = [
    (#"\bwho\s+(are|r)\s+(you|u)\b|\bwhat\s+(are|r)\s+(you|u)\b|\bwho\s+(made|created|built|owns|programmed|coded|developed)\s+(you|u)\b|\byour\s+(name|creator|maker|developer)\b|\bwhat('?s| is)\s+your\s+name\b"#,
     { n in "the user is asking who you are. Answer: \"I'm \(n), an AI assistant made by Th3Monke.\"" }),
    (#"\b(web\s?site|site|url|link|download)\b"#,
     { _ in "if they ask for LARP.AI's website or where to get it, answer: \"LARP.AI's official website is mylarpai.com.\"" }),
    (#"\b(account|sign\s?(in|up)|log\s?in|login|password)\b"#,
     { _ in "if they ask about a LARP.AI account or signing in, answer: \"LARP.AI doesn't use accounts. It runs right on your phone, no sign-in needed.\"" }),
]

var deviceRAMGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

/// Downloads models into Documents/Models (also visible in the Files app).
@MainActor
final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var downloaded: Set<String> = []
    @Published var progress: [String: Double] = [:]
    @Published var errors: [String: String] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    nonisolated static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Files use LARP.AI names (they show in the Files app); the internal ids stay the same.
    nonisolated static let fileNames = ["gemma3-1b": "scout-2.5", "qwen3-1.7b": "forge-3", "gemma3-4b": "oracle-3.5", "qwen3-4b": "forge-3.5"]
    nonisolated static func file(for id: String) -> URL { folder.appendingPathComponent("\(fileNames[id] ?? id).gguf") }

    override init() {
        super.init()
        // models from older versions that aren't offered any more would just take up storage
        for gone in ["llama32-1b", "llama32-3b"] { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(gone).gguf")) }
        // files from older versions were named after the original models (gemma3-1b.gguf …)
        for (id, name) in Self.fileNames {
            let old = Self.folder.appendingPathComponent("\(id).gguf"), new = Self.folder.appendingPathComponent("\(name).gguf")
            if FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path) {
                try? FileManager.default.moveItem(at: old, to: new)
            }
        }
        refresh()
    }

    func refresh() {
        downloaded = Set(MODEL_CATALOG.map(\.id).filter { FileManager.default.fileExists(atPath: Self.file(for: $0).path) })
    }

    func download(_ m: ModelInfo) {
        guard tasks[m.id] == nil else { return }
        errors[m.id] = nil
        progress[m.id] = 0
        let t = session.downloadTask(with: m.url)
        t.taskDescription = m.id
        tasks[m.id] = t
        t.resume()
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        progress[id] = nil
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.file(for: id))
        refresh()
    }

    // MARK: URLSessionDownloadDelegate (called off the main thread)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (MODEL_CATALOG.first { $0.id == id }?.bytes ?? 1)
        let p = Double(totalBytesWritten) / Double(max(total, 1))
        Task { @MainActor in self.progress[id] = p }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let dest = ModelManager.file(for: id)
        var err: String?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            err = "Download failed (HTTP \(http.statusCode))."
        } else {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
            } catch { err = error.localizedDescription }
        }
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            if let err { self.errors[id] = err }
            self.refresh()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let error else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor in
            self.tasks[id] = nil
            self.progress[id] = nil
            if !cancelled { self.errors[id] = "Download stopped: \(error.localizedDescription) Keep LARP.AI open while it downloads." }
        }
    }
}
