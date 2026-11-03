import Foundation
import SwiftUI
import UIKit
import Combine

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String          // "user" or "assistant"
    var text: String
    var stats: String? = nil
    var fb: String? = nil             // 👍 "up" / 👎 "down"
    var files: [Attachment]? = nil    // photos and files the user added
    var image: String? = nil          // picture the AI made (file in Media)
    var imagePrompt: String? = nil    // what it was asked to draw
}

/// Picture progress written from the picture engine's thread.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
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
    @Published var pending: [Attachment] = []          // added to the next message
    @Published var picProgress: [UUID: Double] = [:]    // pictures being made, by message

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
    let learning = Learning()
    let pro = Pro()
    let pictures = PictureModel()
    private let engine = LlamaEngine.shared
    private var subs = Set<AnyCancellable>()

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
        // Pro unlocks colors: redraw the app when it changes
        pro.$active.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                Theme.update(self)
                self.objectWillChange.send()
            }
        }.store(in: &subs)
    }

    /// Bonus colors and "any color" are Pro; without Pro the app shows Violet (the choice is kept).
    func colorLocked(_ i: Int) -> Bool { !pro.active && (i == CUSTOM_ACCENT || i >= FREE_ACCENTS) }
    var accentColor: Color {
        if colorLocked(accent) { return ACCENTS[0].1 }
        if accent == CUSTOM_ACCENT { return Color(rgbString: customAccent) ?? ACCENTS[0].1 }
        return ACCENTS[min(max(accent, 0), ACCENTS.count - 1)].1
    }
    /// the color wheel in Settings: shows the current color, picking one switches to "my own color"
    var customAccentBinding: Binding<Color> {
        Binding(get: { self.accentColor }, set: {
            guard !self.colorLocked(CUSTOM_ACCENT) else { self.pro.lock = .perk; return }
            self.customAccent = $0.rgbString; self.accent = CUSTOM_ACCENT
        })
    }
    func pickAccent(_ i: Int) {
        if colorLocked(i) { pro.lock = .perk } else { accent = i }
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

    /// Sends a message (with anything in `pending`). Returns the reply text, e.g. for Talk mode to say out loud.
    @discardableResult
    func send(_ text: String, voice: Bool = false) async -> String? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = voice ? [] : pending
        guard !text.isEmpty || !files.isEmpty, !streaming else { return nil }
        errorText = nil
        guard currentModel != nil else { errorText = "Download a model first (tap the model name at the top)."; return nil }
        if text.isEmpty { text = files.count == 1 ? "Take a look at this." : "Take a look at these." }
        if !voice { pending = [] }
        if currentID == nil {
            let c = Chat(title: String((files.isEmpty ? text : files[0].name).prefix(40)))
            chats.insert(c, at: 0)
            currentID = c.id
        }
        guard let idx = chats.firstIndex(where: { $0.id == currentID }) else { return nil }
        chats[idx].messages.append(ChatMessage(role: "user", text: text, files: files.isEmpty ? nil : files))
        chats[idx].updated = Date()
        saveChats()
        return await reply(in: chats[idx].id, voice: voice)
    }

    func retry() async {
        guard !streaming, let idx = chats.firstIndex(where: { $0.id == currentID }) else { return }
        if chats[idx].messages.last?.role == "assistant" { chats[idx].messages.removeLast() }
        await reply(in: chats[idx].id, voice: false)
    }

    /// Adds a photo or file to the next message (counts toward today's uploads).
    func attach(_ load: @escaping () async throws -> Attachment) {
        guard pro.use(.up) else { return }
        Task {
            do { pending.append(try await load()) } catch { errorText = error.localizedDescription }
        }
    }

    /// What the model reads for a message: the text, plus the newest uploads in full (older ones by name).
    private func content(_ msg: ChatMessage, full: Bool) -> String {
        guard let files = msg.files, !files.isEmpty else { return msg.text }
        if !full { return msg.text + "\n\n[Earlier the user attached: " + files.map(\.name).joined(separator: ", ") + "]" }
        let cap = max(1200, Int(Double(contextSize) * 1.6) / files.count)
        let parts = files.map { f in f.text.count > cap ? String(f.text.prefix(cap)) + "\n[…the rest didn't fit the chat memory]" : f.text }
        return msg.text + "\n\n" + parts.joined(separator: "\n\n")
    }

    @discardableResult
    private func reply(in chatID: UUID, voice: Bool) async -> String? {
        streaming = true
        streamText = ""
        defer { streaming = false }
        guard await ensureLoaded(), let m = currentModel, let idx = chats.firstIndex(where: { $0.id == chatID }) else { return nil }

        // newest messages that fit the chat memory (~3.5 chars per token)
        let all = chats[idx].messages
        let newestFiles = all.lastIndex { !($0.files ?? []).isEmpty }
        let budget = Int(Double(contextSize - 600) * 3.2)
        var history: [(String, String)] = []
        var used = 0
        for (i, msg) in all.enumerated().reversed() {
            let c = content(msg, full: i == newestFiles)
            used += c.count
            if used > budget && !history.isEmpty { break }
            history.insert((msg.role, c), at: 0)
        }
        while history.first?.0 == "assistant" { history.removeFirst() }

        let name = assistantName.trimmingCharacters(in: .whitespaces).isEmpty ? "LARP.AI" : assistantName
        var sys = (systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are \(name), a helpful AI assistant running fully offline on the user's iPhone. Keep answers clear and reasonably short."
            : systemPrompt)
            + "\n\nAbout you: you are \(name), an AI assistant made by Th3Monke. You are the \(m.name) model. When someone asks who you are or who made you, say you are \(name), made by Th3Monke. When someone asks what model you are, say \(m.name), one of LARP.AI's models. Don't bring up the open model you are built on (\(m.base)) yourself; only if someone asks directly whether you are based on an existing or open-source model, answer truthfully."
        if voice {
            sys += "\n\nThe user is talking to you out loud and your reply will be spoken by a voice. Keep it short and natural, usually one to three sentences. No markdown, lists, emojis or code unless they ask."
        } else if picturesSupported {
            sys += "\n\nYou can create pictures. When the user asks you to draw, generate, make or show an image, photo or picture, answer with one short friendly sentence, then a line exactly like: [[image: a detailed English description of the picture]]\nNever use this tag otherwise."
        }
        sys += "\n\nWhen the user adds photos or files, their contents are included in the message. For photos you get the text in them and a short list of what they show, not the picture itself, so say so if they ask about details you can't know."
        sys += learning.styleBlock
        var msgs: [(String, String)] = [("system", sys)]
        // strict user/assistant alternation (some chat templates require it)
        for h in history {
            if let last = msgs.last, last.0 == h.0 { msgs[msgs.count - 1].1 += "\n\n" + h.1 }
            else { msgs.append(h) }
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
        var final = Self.cleanReply(streamText)
        // [[image: …]] means the AI wants to make a picture
        var drawing: String?
        if !voice, let r = final.range(of: #"\[\[\s*image\s*:[^\]]*\]\]"#, options: [.regularExpression, .caseInsensitive]) {
            drawing = final[r].replacingOccurrences(of: #"^\[\[\s*image\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            final.removeSubrange(r)
            final = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if final.isEmpty { final = "Here you go!" }
            if drawing?.isEmpty == true { drawing = nil }
        }
        streamText = ""
        guard let i = chats.firstIndex(where: { $0.id == chatID }), !final.isEmpty else { return nil }
        let tps = secs > 0 ? Double(count) / secs : 0
        let msg = ChatMessage(role: "assistant", text: final, stats: String(format: "%.1f tok/s · %.1fs", tps, secs), imagePrompt: drawing)
        chats[i].messages.append(msg)
        chats[i].updated = Date()
        saveChats()
        if readAloud && !voice { speech.speak(final) }
        if drawing != nil { Task { await makePicture(chat: chatID, message: msg.id) } }
        return final
    }

    // MARK: pictures
    func makePicture(chat chatID: UUID, message msgID: UUID) async {
        guard #available(iOS 17.0, *) else { return }
        guard picturesSupported, pictures.ready, picProgress[msgID] == nil,
              let ci = chats.firstIndex(where: { $0.id == chatID }),
              let mi = chats[ci].messages.firstIndex(where: { $0.id == msgID }),
              let prompt = chats[ci].messages[mi].imagePrompt else { return }
        guard pro.use(.img) else { return }
        picProgress[msgID] = 0
        // phones with less memory can't hold the chat model and the picture model at once
        let tight = deviceRAMGB < 7.5
        if tight { await engine.unload() }
        let box = ProgressBox()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                self.picProgress[msgID] = box.value
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        var file: String?
        do {
            let cg = try await PictureEngine.shared.make(prompt: prompt, steps: 20) { step, of in
                box.value = Double(step + 1) / Double(max(of, 1)); return true
            }
            if let cg, let png = UIImage(cgImage: cg).pngData() { file = Media.save(png, ext: "png") }
            if file == nil { errorText = "Couldn't make that picture. Try asking again." }
        } catch {
            errorText = "Couldn't make the picture: \(error.localizedDescription)"
        }
        poll.cancel()
        picProgress[msgID] = nil
        if tight { await PictureEngine.shared.unload() }
        if let ci = chats.firstIndex(where: { $0.id == chatID }), let mi = chats[ci].messages.firstIndex(where: { $0.id == msgID }) {
            chats[ci].messages[mi].image = file
            saveChats()
        }
        if tight { await ensureLoaded() }
    }

    // MARK: ratings
    /// 👍 (tap again to undo) or 👎 with what was wrong. Learns on the iPhone; shares only if the user turned that on.
    func rate(_ msgID: UUID, up: Bool, reasons: [String] = [], comment: String = "") {
        guard let ci = chats.firstIndex(where: { $0.messages.contains { $0.id == msgID } }),
              let mi = chats[ci].messages.firstIndex(where: { $0.id == msgID }) else { return }
        let m = chats[ci].messages[mi]
        if up && m.fb == "up" { chats[ci].messages[mi].fb = nil; saveChats(); return }
        chats[ci].messages[mi].fb = up ? "up" : "down"
        saveChats()
        if !up && learning.on { learning.learn(reasons: reasons, comment: comment) }
        let question = chats[ci].messages[..<mi].last(where: { $0.role == "user" })?.text ?? ""
        learning.send(rating: up ? "up" : "down", reasons: reasons, comment: comment,
                      model: currentModel?.name ?? "", question: question, answer: m.text)
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
