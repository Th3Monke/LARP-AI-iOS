import Foundation

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let bytes: Int64
    let minRAMGB: Double
    let note: String
    let url: URL
    let qwen3: Bool
}

/// Phone-sized models (all run fully offline once downloaded).
let MODEL_CATALOG: [ModelInfo] = [
    ModelInfo(id: "gemma3-1b", name: "Gemma 3 1B", size: "0.8 GB", bytes: 806_058_272, minRAMGB: 3,
              note: "Fast and light. Works on almost any recent iPhone.", url: URL(string: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf")!, qwen3: false),
    ModelInfo(id: "llama32-1b", name: "Llama 3.2 1B", size: "0.8 GB", bytes: 807_694_464, minRAMGB: 3,
              note: "Meta's tiny all-rounder. Quick answers.", url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!, qwen3: false),
    ModelInfo(id: "qwen3-1.7b", name: "Qwen3 1.7B", size: "1.8 GB", bytes: 1_834_426_016, minRAMGB: 6,
              note: "Small but smart, good at reasoning and code.", url: URL(string: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf")!, qwen3: true),
    ModelInfo(id: "llama32-3b", name: "Llama 3.2 3B", size: "2 GB", bytes: 2_019_377_696, minRAMGB: 6,
              note: "Noticeably smarter. Best on iPhone 15 Pro and newer.", url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!, qwen3: false),
    ModelInfo(id: "gemma3-4b", name: "Gemma 3 4B", size: "2.5 GB", bytes: 2_489_757_856, minRAMGB: 8,
              note: "The smartest that fits a phone. Needs 8 GB RAM (iPhone 15 Pro or newer).", url: URL(string: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf")!, qwen3: false),
    ModelInfo(id: "qwen3-4b", name: "Qwen3 4B", size: "2.5 GB", bytes: 2_497_280_256, minRAMGB: 8,
              note: "Great at reasoning and code. Needs 8 GB RAM (iPhone 15 Pro or newer).", url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!, qwen3: true),
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
    nonisolated static func file(for id: String) -> URL { folder.appendingPathComponent("\(id).gguf") }

    override init() {
        super.init()
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
