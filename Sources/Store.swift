import Foundation
import SwiftUI
import UIKit

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String          // "user" or "assistant"
    var text: String
    var stats: String? = nil
}

struct Chat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var updated = Date()
}

/// Text the engine streams in from another thread.
final class TextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var parts = ""
    private var n = 0
    func append(_ s: String) { lock.lock(); parts += s; n += 1; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts }
    var pieces: Int { lock.lock(); defer { lock.unlock() }; return n }
}

let ACCENTS: [(String, Color)] = [
    ("Violet", Color(red: 0.49, green: 0.42, blue: 0.94)),
    ("Clay", Color(red: 0.79, green: 0.39, blue: 0.26)),
    ("Ocean", Color(red: 0.23, green: 0.51, blue: 0.96)),
    ("Teal", Color(red: 0.08, green: 0.64, blue: 0.55)),
    ("Rose", Color(red: 0.88, green: 0.33, blue: 0.54)),
    ("Sky", Color(red: 0.22, green: 0.74, blue: 0.97)),
    ("Mint", Color(red: 0.20, green: 0.80, blue: 0.47)),
    ("Lime", Color(red: 0.55, green: 0.80, blue: 0.16)),
    ("Gold", Color(red: 0.96, green: 0.70, blue: 0.13)),
    ("Red", Color(red: 0.93, green: 0.27, blue: 0.27)),
    ("Pink", Color(red: 0.93, green: 0.36, blue: 0.80)),
    ("Silver", Color(red: 0.70, green: 0.71, blue: 0.75)),
]
/// accent index for "my own color" (picked with the color wheel)
let CUSTOM_ACCENT = -1

/// Background styles; Tinted mixes the app color into the background.
let BACKGROUNDS = ["Charcoal", "Midnight", "Black", "Tinted"]

extension Color {
    /// "r,g,b" (0...1) so a picked color survives restarts
    var rgbString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.4f,%.4f,%.4f", r, g, b)
    }
    init?(rgbString s: String) {
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        self.init(red: p[0], green: p[1], blue: p[2])
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var currentID: UUID?
    @Published var streaming = false
    @Published var streamText = ""
    @Published var status = "No model loaded"
    @Published var loading = false
    @Published var errorText: String?

    @Published var modelID: String { didSet { save("modelID", modelID) } }
    @Published var assistantName: String { didSet { save("assistantName", assistantName) } }
    @Published var systemPrompt: String { didSet { save("systemPrompt", systemPrompt) } }
    @Published var temperature: Double { didSet { save("temperature", temperature) } }
    @Published var contextSize: Int { didSet { save("contextSize", contextSize) } }
    @Published var accent: Int { didSet { save("accent", accent); Theme.update(self) } }
    @Published var customAccent: String { didSet { save("customAccent", customAccent); Theme.update(self) } }
    @Published var background: Int { didSet { save("background", background); Theme.update(self) } }
    @Published var think: Bool { didSet { save("think", think) } }
    @Published var readAloud: Bool { didSet { save("readAloud", readAloud) } }

    let models = ModelManager()
    let speech = Speaker()
    private let engine = LlamaEngine.shared

    init() {
        let d = UserDefaults.standard
        modelID = d.string(forKey: "modelID") ?? ""
        assistantName = d.string(forKey: "assistantName") ?? "LARP.AI"
        systemPrompt = d.string(forKey: "systemPrompt") ?? ""
        temperature = d.object(forKey: "temperature") as? Double ?? 0.7
        contextSize = d.object(forKey: "contextSize") as? Int ?? 4096
        accent = d.object(forKey: "accent") as? Int ?? 0
        customAccent = d.string(forKey: "customAccent") ?? ACCENTS[0].1.rgbString
        background = d.object(forKey: "background") as? Int ?? 0
        think = d.object(forKey: "think") as? Bool ?? false
        readAloud = d.object(forKey: "readAloud") as? Bool ?? false
        Theme.update(self)
        loadChats()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.freeMemory() }
        }
    }

    var accentColor: Color {
        if accent == CUSTOM_ACCENT { return Color(rgbString: customAccent) ?? ACCENTS[0].1 }
        return ACCENTS[min(max(accent, 0), ACCENTS.count - 1)].1
    }
    /// the color wheel in Settings: shows the current color, picking one switches to "my own color"
    var customAccentBinding: Binding<Color> {
        Binding(get: { self.accentColor }, set: { self.customAccent = $0.rgbString; self.accent = CUSTOM_ACCENT })
    }
    var current: Chat? { chats.first { $0.id == currentID } }
    var currentModel: ModelInfo? { MODEL_CATALOG.first { $0.id == modelID && models.downloaded.contains($0.id) } }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: chats on disk
    private var chatsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("chats.json")
    }
    private func loadChats() {
        if let data = try? Data(contentsOf: chatsFile), let list = try? JSONDecoder().decode([Chat].self, from: data) { chats = list }
    }
    func saveChats() {
        let url = chatsFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(chats) { try? data.write(to: url, options: .atomic) }
    }

    func newChat() { currentID = nil; streamText = ""; errorText = nil }
    func deleteChat(_ id: UUID) {
        chats.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        saveChats()
    }

    // MARK: model
    func useModel(_ id: String) { modelID = id; Task { await ensureLoaded() } }

    @discardableResult
    func ensureLoaded() async -> Bool {
        guard let m = currentModel else { status = "Pick a model to start"; return false }
        let path = ModelManager.file(for: m.id).path
        if await engine.loadedPath == path { status = "\(m.name) ready"; return true }
        loading = true
        status = "Loading \(m.name)…"
        defer { loading = false }
        do {
            try await engine.load(path: path, contextSize: contextSize)
            status = "\(m.name) ready"
            return true
        } catch {
            status = "Couldn't load \(m.name)"
            errorText = error.localizedDescription
            return false
        }
    }

    func freeMemory() {
        guard !streaming else { return }
        Task { await engine.unload(); status = "Model unloaded to free memory" }
    }

    // MARK: chatting
    func stop() { engine.stop.value = true }

    func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        errorText = nil
        guard currentModel != nil else { errorText = "Download a model first (tap the model name at the top)."; return }
        if currentID == nil {
            let c = Chat(title: String(text.prefix(40)))
            chats.insert(c, at: 0)
            currentID = c.id
        }
        guard let idx = chats.firstIndex(where: { $0.id == currentID }) else { return }
        chats[idx].messages.append(ChatMessage(role: "user", text: text))
        chats[idx].updated = Date()
        saveChats()
        await reply(in: chats[idx].id)
    }

    func retry() async {
        guard !streaming, let idx = chats.firstIndex(where: { $0.id == currentID }) else { return }
        if chats[idx].messages.last?.role == "assistant" { chats[idx].messages.removeLast() }
        await reply(in: chats[idx].id)
    }

    private func reply(in chatID: UUID) async {
        streaming = true
        streamText = ""
        defer { streaming = false }
        guard await ensureLoaded(), let m = currentModel, let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }

        // newest messages that fit the chat memory (~3.5 chars per token)
        let budget = Int(Double(contextSize - 600) * 3.2)
        var history: [ChatMessage] = []
        var used = 0
        for msg in chats[idx].messages.reversed() {
            used += msg.text.count
            if used > budget && !history.isEmpty { break }
            history.insert(msg, at: 0)
        }
        while history.first?.role == "assistant" { history.removeFirst() }

        let name = assistantName.trimmingCharacters(in: .whitespaces).isEmpty ? "LARP.AI" : assistantName
        let sys = (systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are \(name), a helpful AI assistant running fully offline on the user's iPhone. Keep answers clear and reasonably short."
            : systemPrompt)
            + "\n\nAbout you: you are \(name), an AI assistant made by Th3Monke. You are the \(m.name) model. When someone asks who you are or who made you, say you are \(name), made by Th3Monke. When someone asks what model you are, say \(m.name), one of LARP.AI's models. Don't bring up the open model you are built on (\(m.base)) yourself; only if someone asks directly whether you are based on an existing or open-source model, answer truthfully."
        var msgs: [(String, String)] = [("system", sys)]
        // strict user/assistant alternation (some chat templates require it)
        for h in history {
            if let last = msgs.last, last.0 == h.role { msgs[msgs.count - 1].1 += "\n\n" + h.text }
            else { msgs.append((h.role, h.text)) }
        }
        if m.thinks && !think, let last = msgs.last, last.0 == "user" { msgs[msgs.count - 1].1 += " /no_think" }

        let start = Date()
        let buffer = TextBuffer()
        // the engine writes from its own thread; the screen reads the buffer every 50 ms
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                self.streamText = buffer.text
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        do {
            try await engine.generate(messages: msgs, temperature: Float(temperature), maxTokens: 1500) { piece in
                buffer.append(piece)
            }
        } catch {
            errorText = error.localizedDescription
        }
        poll.cancel()
        streamText = buffer.text
        let count = buffer.pieces
        let secs = Date().timeIntervalSince(start)
        let final = Self.cleanReply(streamText)
        guard let i = chats.firstIndex(where: { $0.id == chatID }) else { return }
        if !final.isEmpty {
            let tps = secs > 0 ? Double(count) / secs : 0
            chats[i].messages.append(ChatMessage(role: "assistant", text: final, stats: String(format: "%.1f tok/s · %.1fs", tps, secs)))
            chats[i].updated = Date()
            saveChats()
            if readAloud { speech.speak(final) }
        }
        streamText = ""
    }

    /// Hide <think>…</think> reasoning from the saved reply.
    static func cleanReply(_ s: String) -> String {
        var t = s
        while let a = t.range(of: "<think>") {
            if let b = t.range(of: "</think>", range: a.upperBound..<t.endIndex) { t.removeSubrange(a.lowerBound..<b.upperBound) }
            else { t.removeSubrange(a.lowerBound..<t.endIndex) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
