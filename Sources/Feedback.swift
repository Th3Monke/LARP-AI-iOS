import Foundation
import SwiftUI

/// Same reasons as the PC app: (id, button label, what the AI learns from it).
let FB_REASONS: [(id: String, label: String, rule: String)] = [
    ("long", "Too long", "Keep answers shorter and to the point."),
    ("short", "Too short", "Give fuller answers with more detail."),
    ("wrong", "Wrong or made up", "Double-check facts, and say when you're not sure instead of guessing."),
    ("tone", "Wrong tone", "Keep the tone natural and friendly, not stiff or over the top."),
    ("ignored", "Didn't do what I asked", "Do exactly what the user asks. Re-read the request before answering."),
    ("code", "Bad code", "Write complete, working code with short comments, and no placeholders."),
]
private let FB_OPPOSITE = ["long": "short", "short": "long"]

struct LearnNote: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var count: Int
    var at: Date
}

/// One rating as the website's /api/feedback expects it (same shape the PC app sends).
struct FeedbackItem: Codable {
    var v = 1
    var app: String
    var model: String
    var mode = "chat"
    var rating: String
    var reasons: [String]
    var comment: String
    var question: String
    var answer: String
    var at: String
}

let APP_VERSION = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

/// 👍/👎 learning on this iPhone, plus the completely optional sharing to Th3Monke.
@MainActor
final class Learning: ObservableObject {
    @Published var notes: [LearnNote] { didSet { saveNotes() } }
    @Published var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "learnOn") } }
    /// Opt-in only. Off drops anything not sent yet.
    @Published var share: Bool {
        didSet {
            UserDefaults.standard.set(share, forKey: "shareFeedback")
            if share { flush() } else { queue = [] }
        }
    }
    private var flushing = false

    init() {
        let d = UserDefaults.standard
        notes = d.data(forKey: "learnNotes").flatMap { try? JSONDecoder().decode([LearnNote].self, from: $0) } ?? []
        on = d.object(forKey: "learnOn") as? Bool ?? true
        share = d.object(forKey: "shareFeedback") as? Bool ?? false
    }

    private func saveNotes() { UserDefaults.standard.set(try? JSONEncoder().encode(notes), forKey: "learnNotes") }

    /// Turns a 👎 into short rules the AI follows from now on. Returns what was learned.
    @discardableResult
    func learn(reasons: [String], comment: String) -> [String] {
        var list = notes, added: [String] = []
        for r in reasons {
            guard let def = FB_REASONS.first(where: { $0.id == r }) else { continue }
            if let i = list.firstIndex(where: { $0.id == "r:" + r }) {
                list[i].count += 1; list[i].at = Date(); added.append(list[i].text)
            } else {
                list.append(LearnNote(id: "r:" + r, text: def.rule, count: 1, at: Date())); added.append(def.rule)
            }
            // the newest direction wins (too long vs too short)
            if let opp = FB_OPPOSITE[r], let mine = list.first(where: { $0.id == "r:" + r }),
               let o = list.firstIndex(where: { $0.id == "r:" + opp }), list[o].count <= mine.count { list.remove(at: o) }
        }
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let note = String(c.prefix(200))
        if !note.isEmpty && !list.contains(where: { $0.text.localizedCaseInsensitiveContains(note) }) {
            list.append(LearnNote(id: "c:\(Date().timeIntervalSince1970)", text: "The user said: \"\(note)\"", count: 1, at: Date()))
            added.append(note)
            let comments = list.filter { $0.id.hasPrefix("c:") }
            if comments.count > 10, let oldest = comments.first { list.removeAll { $0.id == oldest.id } }
        }
        notes = list
        return added
    }

    func forget(_ id: String) { notes.removeAll { $0.id == id } }

    /// Added to the system prompt so every model follows what the user taught it.
    var styleBlock: String {
        guard on, !notes.isEmpty else { return "" }
        return "\n\n## How this user likes answers\nLearned from their thumbs up / down on your replies. Follow these:\n"
            + notes.map { "- " + $0.text }.joined(separator: "\n")
    }

    // MARK: sharing (only when the user turned it on)

    private var queue: [FeedbackItem] {
        get { UserDefaults.standard.data(forKey: "feedbackQueue").flatMap { try? JSONDecoder().decode([FeedbackItem].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.suffix(200))), forKey: "feedbackQueue") }
    }

    func send(rating: String, reasons: [String], comment: String, model: String, question: String, answer: String) {
        guard share else { return }
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        queue.append(FeedbackItem(app: "iPhone " + APP_VERSION, model: String(model.prefix(60)), rating: rating,
                                  reasons: Array(reasons.prefix(6)), comment: String(comment.prefix(600)),
                                  question: String(question.prefix(4000)), answer: String(answer.prefix(8000)), at: String(day)))
        flush()
    }

    /// Sends what's waiting; offline or a busy server just keeps it for later.
    func flush() {
        guard share, !flushing, !queue.isEmpty else { return }
        flushing = true
        Task {
            while share, let item = queue.first {
                var req = URLRequest(url: URL(string: "https://mylarpai.com/api/feedback")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("iPhone " + APP_VERSION, forHTTPHeaderField: "X-LARP-App")
                req.httpBody = try? JSONEncoder().encode(item)
                let result = try? await URLSession.shared.data(for: req)
                guard let http = result?.1 as? HTTPURLResponse else { break }
                if http.statusCode >= 500 || http.statusCode == 429 { break }
                var q = queue
                if !q.isEmpty { q.removeFirst() }
                queue = q
            }
            flushing = false
        }
    }
}

/// "What was wrong?" after a 👎
struct FeedbackSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var learning: Learning
    @Environment(\.dismiss) var dismiss
    let message: ChatMessage
    @State private var picked: Set<String> = []
    @State private var comment = ""
    @State private var nudge = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(FB_REASONS, id: \.id) { r in
                        Button {
                            if picked.contains(r.id) { picked.remove(r.id) } else { picked.insert(r.id) }
                        } label: {
                            HStack {
                                Text(r.label).foregroundStyle(.primary)
                                Spacer()
                                if picked.contains(r.id) { Image(systemName: "checkmark").foregroundStyle(state.accentColor) }
                            }
                        }
                    }
                } header: { Text(nudge ? "Pick what was wrong, or type a note" : "What was wrong?") }
                Section {
                    TextField("Tell it what to do better (optional)", text: $comment, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text((learning.on ? "\(state.assistantName) learns from this on your iPhone." : "Learning is off in Settings, so this is only saved as a rating.")
                         + (learning.share ? " It also goes to Th3Monke to improve LARP.AI (you turned this on)." : ""))
                }
            }
            .themedList()
            .navigationTitle("Bad reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        let reasons = FB_REASONS.map(\.id).filter { picked.contains($0) }
                        if reasons.isEmpty && comment.trimmingCharacters(in: .whitespaces).isEmpty { nudge = true; return }
                        state.rate(message.id, up: false, reasons: reasons, comment: comment)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
