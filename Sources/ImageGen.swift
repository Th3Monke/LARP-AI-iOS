import Foundation
import SwiftUI
import CoreML
import StableDiffusion

/// Canvas Mobile: makes pictures on the iPhone's Neural Engine (Apple's Core ML Stable Diffusion,
/// 6-bit, 512×512). Needs iOS 17 and 6 GB of memory.
let PIC_NAME = "Canvas Mobile"
let PIC_BASE = URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/split_einsum_v2/compiled/")!
let PIC_FILES: [(path: String, bytes: Int64)] = {
    var list: [(path: String, bytes: Int64)] = []
    let parts: [(String, Int64, Int64, Int64, Int64)] = [   // model, coremldata, metadata, model.mil, weights
        ("TextEncoder", 839, 2_792, 391_100, 318_860_352),
        ("Unet", 1_221, 3_728, 3_101_782, 649_959_936),
        ("VAEDecoder", 769, 2_493, 181_387, 98_993_280),
        ("VAEEncoder", 775, 2_481, 139_736, 68_338_112),
    ]
    for (m, cd, meta, mil, w) in parts {
        list += [("\(m).mlmodelc/analytics/coremldata.bin", 207), ("\(m).mlmodelc/coremldata.bin", cd),
                 ("\(m).mlmodelc/metadata.json", meta), ("\(m).mlmodelc/model.mil", mil), ("\(m).mlmodelc/weights/weight.bin", w)]
    }
    return list + [("merges.txt", 524_657), ("vocab.json", 862_328)]
}()
let PIC_TOTAL = PIC_FILES.reduce(Int64(0)) { $0 + $1.bytes }

var picturesSupported: Bool {
    if #available(iOS 17.0, *) { return deviceRAMGB >= 5.5 }
    return false
}

/// Downloads the picture model file by file into Application Support/Canvas.
@MainActor
final class PictureModel: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published private(set) var ready = false
    @Published private(set) var progress: Double?
    @Published var error: String?

    private var index = 0
    private var doneBytes: Int64 = 0
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Canvas", isDirectory: true)
    }
    nonisolated static var marker: URL { folder.appendingPathComponent(".complete") }

    override init() {
        super.init()
        ready = FileManager.default.fileExists(atPath: Self.marker.path)
    }

    func download() {
        guard task == nil, !ready else { return }
        error = nil
        index = 0; doneBytes = 0
        progress = 0
        next()
    }

    func cancel() { task?.cancel(); task = nil; progress = nil }

    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: Self.folder)
        ready = false
    }

    private func next() {
        // skip files already there from an earlier, interrupted download
        while index < PIC_FILES.count {
            let f = PIC_FILES[index]
            let dest = Self.folder.appendingPathComponent(f.path)
            let have = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value
            if have != f.bytes { break }
            doneBytes += f.bytes; index += 1
        }
        if index >= PIC_FILES.count {
            FileManager.default.createFile(atPath: Self.marker.path, contents: Data())
            task = nil; progress = nil; ready = true
            return
        }
        let t = session.downloadTask(with: PIC_BASE.appendingPathComponent(PIC_FILES[index].path))
        task = t
        t.resume()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard downloadTask === self.task else { return }
            self.progress = Double(self.doneBytes + totalBytesWritten) / Double(PIC_TOTAL)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // the temp file disappears when this returns, so move it right away
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moved = status == 200 && (try? FileManager.default.moveItem(at: location, to: staged)) != nil
        Task { @MainActor in
            guard downloadTask === self.task else { try? FileManager.default.removeItem(at: staged); return }
            guard moved else { self.fail("Download failed (HTTP \(status))."); return }
            let f = PIC_FILES[self.index]
            let dest = Self.folder.appendingPathComponent(f.path)
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: staged, to: dest)
            } catch { self.fail(error.localizedDescription); return }
            self.doneBytes += f.bytes
            self.index += 1
            self.next()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            guard task === self.task else { return }
            self.fail("Download stopped: \(error.localizedDescription) Keep LARP.AI open while it downloads; it picks up where it stopped.")
        }
    }

    private func fail(_ msg: String) { task = nil; progress = nil; error = msg }
}

/// Holds the loaded picture model between pictures.
@available(iOS 17.0, *)
actor PictureEngine {
    static let shared = PictureEngine()
    private var pipeline: StableDiffusionPipeline?

    /// `progress(step, of)` is called after every step; return false to stop.
    func make(prompt: String, steps: Int, progress: @escaping @Sendable (Int, Int) -> Bool) throws -> CGImage? {
        if pipeline == nil {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let p = try StableDiffusionPipeline(resourcesAt: PictureModel.folder, controlNet: [], configuration: config,
                                                disableSafety: true, reduceMemory: true)
            try p.loadResources()
            pipeline = p
        }
        guard let p = pipeline else { return nil }
        var c = StableDiffusionPipeline.Configuration(prompt: prompt)
        c.negativePrompt = "blurry, low quality, deformed, ugly, bad anatomy, watermark, text, signature"
        c.stepCount = steps
        c.seed = UInt32.random(in: 0...UInt32.max)
        c.guidanceScale = 7.5
        c.schedulerType = .dpmSolverMultistepScheduler
        c.disableSafety = true
        let images = try p.generateImages(configuration: c) { s in progress(s.step, s.stepCount) }
        return images.first ?? nil
    }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }
}
