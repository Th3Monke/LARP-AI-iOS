import Foundation
import SwiftUI
import UIKit
import Vision
import PDFKit
import UniformTypeIdentifiers

/// A photo or file added to a message. The AI gets `text`; `thumb` is a picture shown in the chat.
struct Attachment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: String          // "photo", "pdf" or "file"
    var text: String
    var thumb: String? = nil
}

/// Pictures the app keeps (uploaded photos and pictures it made), in Application Support/Media.
enum Media {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func save(_ data: Data, ext: String) -> String? {
        let name = UUID().uuidString + "." + ext
        do { try data.write(to: url(name), options: .atomic); return name } catch { return nil }
    }
    static func image(_ name: String) -> UIImage? { UIImage(contentsOfFile: url(name).path) }
}

struct ReadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension UIImage {
    /// upright and at most `side` pixels on the long edge
    func fitted(_ side: CGFloat) -> UIImage {
        let scale = min(1, side / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: target, format: f).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// Reads uploads on the iPhone: text from PDFs and files, and for photos the text in them plus what they show.
enum Extract {
    static func photo(_ data: Data, name: String) async throws -> Attachment {
        guard let img = UIImage(data: data) else { throw ReadError(message: "Couldn't open that picture.") }
        let upright = img.fitted(1600)
        guard let cg = upright.cgImage else { throw ReadError(message: "Couldn't open that picture.") }
        let (labels, text) = await Task.detached(priority: .userInitiated) { see(cg) }.value
        let thumb = upright.fitted(640).jpegData(compressionQuality: 0.8).flatMap { Media.save($0, ext: "jpg") }
        var t = "Photo \"\(name)\""
        t += labels.isEmpty ? "." : ": it looks like it shows \(labels.joined(separator: ", "))."
        t += text.isEmpty ? " There's no readable text in it." : "\nText in the photo:\n\(text)"
        return Attachment(name: name, kind: "photo", text: t, thumb: thumb)
    }

    /// on-device Vision: printed/handwritten text and the main things in the picture
    static func see(_ cg: CGImage) -> ([String], String) {
        let read = VNRecognizeTextRequest()
        read.recognitionLevel = .accurate
        read.usesLanguageCorrection = true
        let look = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([read, look])
        let text = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let labels = (look.results ?? []).filter { $0.confidence > 0.3 }.prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return (Array(labels), text)
    }

    static func file(_ url: URL) async throws -> Attachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: url) else { throw ReadError(message: "Couldn't open \(name).") }
            return try await photo(data, name: name)
        }
        if type?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { throw ReadError(message: "Couldn't open \(name).") }
            var t = ""
            for i in 0..<min(doc.pageCount, 80) { t += (doc.page(at: i)?.string ?? "") + "\n" }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { throw ReadError(message: "\(name) has no text to read (it may be scanned pages; add them as photos instead).") }
            return Attachment(name: name, kind: "pdf", text: "File \"\(name)\" (\(doc.pageCount) pages):\n\(t)")
        }
        guard let data = try? Data(contentsOf: url) else { throw ReadError(message: "Couldn't open \(name).") }
        if data.count > 8_000_000 { throw ReadError(message: "\(name) is too big to read on the phone.") }
        if data.prefix(4096).contains(0) { throw ReadError(message: "LARP.AI can read text, code, PDFs and photos, but not \(name).") }
        let t = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return Attachment(name: name, kind: "file", text: "File \"\(name)\":\n\(t)")
    }

    static let fileTypes: [UTType] = [.pdf, .plainText, .text, .utf8PlainText, .commaSeparatedText, .json, .xml, .html,
                                      .sourceCode, .swiftSource, .pythonScript, .javaScript, .shellScript, .yaml, .image]
}

/// Small preview of an attachment (in the composer and on sent messages).
struct AttachmentChip: View {
    let a: Attachment
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let t = a.thumb, let img = Media.image(t) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: a.kind == "pdf" ? "doc.richtext" : "doc.text").font(.system(size: 16)).frame(width: 34, height: 34)
                    .background(Theme.raise, in: RoundedRectangle(cornerRadius: 7))
            }
            Text(a.name).font(.caption).lineLimit(1).frame(maxWidth: 140, alignment: .leading)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mute) }.buttonStyle(.plain)
            }
        }
        .padding(4).padding(.trailing, 4)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}
