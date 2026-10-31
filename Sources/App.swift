import SwiftUI

@main
struct LarpApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.models)
                .preferredColorScheme(.dark)
                .tint(state.accentColor)
        }
    }
}

enum Theme {
    static let bg = Color(red: 0.122, green: 0.122, blue: 0.118)
    static let panel = Color(red: 0.165, green: 0.165, blue: 0.157)
    static let raise = Color(red: 0.19, green: 0.19, blue: 0.18)
    static let line = Color(red: 0.22, green: 0.22, blue: 0.21)
    static let mute = Color(red: 0.65, green: 0.64, blue: 0.61)
    static func grad(_ accent: Color) -> LinearGradient {
        LinearGradient(colors: [Color(red: 0.39, green: 0.40, blue: 0.95), accent, Color(red: 0.75, green: 0.33, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @State private var showChats = false
    @State private var showModels = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ChatView(showModels: $showModels)
                .background(Theme.bg.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showChats = true } label: { Image(systemName: "sidebar.left") }
                    }
                    ToolbarItem(placement: .principal) {
                        Button { showModels = true } label: {
                            VStack(spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(state.currentModel?.name ?? "Pick a model").font(.subheadline.weight(.semibold))
                                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                                }
                                Text(state.status).font(.caption2).foregroundStyle(Theme.mute)
                            }.foregroundStyle(.primary)
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { state.newChat() } label: { Image(systemName: "square.and.pencil") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.bg, for: .navigationBar)
        }
        .sheet(isPresented: $showChats) { ChatListView() }
        .sheet(isPresented: $showModels) { ModelsView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            if state.currentModel == nil { showModels = true } else { await state.ensureLoaded() }
        }
    }
}

// MARK: - Chat

struct ChatView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var dictation = Dictation()
    @Binding var showModels: Bool
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let chat = state.current {
                            ForEach(chat.messages) { m in
                                MessageView(message: m, isLast: m.id == chat.messages.last?.id)
                            }
                        } else if !state.streaming {
                            EmptyStateView { input = $0; focused = true }
                        }
                        if state.streaming { StreamingView(text: state.streamText) }
                        if let e = state.errorText {
                            Label(e, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.orange)
                                .padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: state.streamText) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.current?.messages.count) { _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            composer
        }
        .onChange(of: dictation.text) { t in if dictation.listening { input = t } }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let e = dictation.error { Text(e).font(.caption).foregroundStyle(.orange) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(dictation.listening ? "Listening…" : "Message \(state.assistantName)…", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 10).padding(.leading, 14)
                Button { dictation.toggle() } label: {
                    Image(systemName: dictation.listening ? "waveform.circle.fill" : "mic")
                        .font(.system(size: 20)).foregroundStyle(dictation.listening ? .red : Theme.mute)
                        .symbolEffectIfAvailable(dictation.listening)
                }.padding(.bottom, 9)
                Button {
                    if state.streaming { state.stop(); return }
                    dictation.stop()
                    let t = input; input = ""
                    Task { await state.send(t) }
                } label: {
                    Image(systemName: state.streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(state.streaming ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Theme.grad(state.accentColor)), in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!state.streaming && input.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(!state.streaming && input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                .padding(.trailing, 6).padding(.bottom, 6)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(focused ? state.accentColor.opacity(0.5) : Theme.line))
            Text("Runs 100% on this iPhone. Nothing leaves it.").font(.caption2).foregroundStyle(Theme.mute.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.bottom, 6).padding(.top, 4)
        .background(Theme.bg)
    }
}

extension View {
    @ViewBuilder func symbolEffectIfAvailable(_ on: Bool) -> some View {
        if #available(iOS 17.0, *) { self.symbolEffect(.pulse, isActive: on) } else { self }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    let pick: (String) -> Void
    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Up late?" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 80)
            Avatar(size: 52)
            Text(greeting).font(.system(size: 30, weight: .regular, design: .serif))
            Text("What's on your mind?").font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Theme.grad(state.accentColor))
            VStack(spacing: 8) {
                ForEach(["Explain black holes like I'm 12", "Write a short birthday message for my mom", "Give me a 3-day workout plan"], id: \.self) { p in
                    Button { pick(p) } label: {
                        Text(p).font(.subheadline).foregroundStyle(Theme.mute)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Avatar: View {
    @EnvironmentObject var state: AppState
    var size: CGFloat = 28
    var body: some View {
        Text(String(state.assistantName.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.grad(state.accentColor), in: Circle())
    }
}

struct MessageView: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    let isLast: Bool
    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 50)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.raise, in: RoundedRectangle(cornerRadius: 18))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar()
                VStack(alignment: .leading, spacing: 8) {
                    RichText(text: message.text)
                    HStack(spacing: 16) {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { state.speech.speaking ? state.speech.stop() : state.speech.speak(message.text) } label: { Label("Read", systemImage: "speaker.wave.2") }
                        if isLast { Button { Task { await state.retry() } } label: { Label("Retry", systemImage: "arrow.clockwise") } }
                        if let s = message.stats { Text(s).foregroundStyle(Theme.mute.opacity(0.7)) }
                    }
                    .font(.caption).foregroundStyle(Theme.mute).labelStyle(.titleAndIcon)
                }
            }
        }
    }
}

struct StreamingView: View {
    @EnvironmentObject var state: AppState
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar()
            let shown = AppState.cleanReply(text)
            if shown.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.loading ? state.status : (text.contains("<think>") ? "Thinking…" : "Writing…")).foregroundStyle(Theme.mute)
                }.padding(.top, 4)
            } else {
                RichText(text: shown)
            }
        }
    }
}

/// Paragraphs with **bold**/`code` and fenced code blocks.
struct RichText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { i, part in
                if i % 2 == 1 {
                    let lines = part.components(separatedBy: "\n")
                    let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code.isEmpty ? part : code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12)
                    }
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(markdown(part.trimmingCharacters(in: .whitespacesAndNewlines))).textSelection(.enabled).lineSpacing(3)
                }
            }
        }
    }
    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Chats list

struct ChatListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Button { state.newChat(); dismiss() } label: { Label("New chat", systemImage: "plus.circle.fill") }
                ForEach(state.chats.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { c in
                    Button { state.currentID = c.id; dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).lineLimit(1).foregroundStyle(.primary)
                            Text(c.updated, style: .relative).font(.caption).foregroundStyle(Theme.mute)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { state.deleteChat(c.id) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your iPhone has about \(Int(deviceRAMGB.rounded())) GB of memory. Models run 100% on the phone; download once over Wi-Fi and keep LARP.AI open until it finishes.")
                        .font(.footnote).foregroundStyle(Theme.mute)
                }
                ForEach(MODEL_CATALOG) { m in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(m.name).font(.headline)
                            Text(m.size).font(.caption).foregroundStyle(Theme.mute)
                            if deviceRAMGB + 0.5 < m.minRAMGB { Text("TOO BIG?").font(.caption2.bold()).foregroundStyle(.orange) }
                            Spacer()
                            if state.modelID == m.id && models.downloaded.contains(m.id) { Text("IN USE").font(.caption2.bold()).foregroundStyle(state.accentColor) }
                        }
                        Text(m.note).font(.footnote).foregroundStyle(Theme.mute)
                        if let p = models.progress[m.id] {
                            ProgressView(value: p).tint(state.accentColor)
                            HStack { Text("\(Int(p * 100))%").font(.caption).foregroundStyle(Theme.mute); Spacer(); Button("Cancel", role: .cancel) { models.cancel(m.id) }.font(.caption) }
                        } else if models.downloaded.contains(m.id) {
                            HStack {
                                Button("Use") { state.useModel(m.id); dismiss() }.buttonStyle(.borderedProminent)
                                Button("Delete", role: .destructive) { models.delete(m.id) }.buttonStyle(.bordered)
                            }
                        } else {
                            Button("Download") { models.download(m) }.buttonStyle(.borderedProminent)
                        }
                        if let e = models.errors[m.id] { Text(e).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("Models")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Assistant") {
                    TextField("Name", text: $state.assistantName)
                    Picker("Accent color", selection: $state.accent) {
                        ForEach(ACCENTS.indices, id: \.self) { i in Text(ACCENTS[i].0).tag(i) }
                    }
                    Toggle("Read replies out loud", isOn: $state.readAloud)
                    Toggle("Let Qwen3 think first (slower, smarter)", isOn: $state.think)
                }
                Section("Instructions") {
                    TextField("Custom instructions (optional)", text: $state.systemPrompt, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("Creativity: \(state.temperature, specifier: "%.1f")")
                        Slider(value: $state.temperature, in: 0...1.5, step: 0.1)
                    }
                    Picker("Chat memory", selection: $state.contextSize) {
                        Text("2K (lightest)").tag(2048); Text("4K").tag(4096); Text("8K (needs more RAM)").tag(8192)
                    }
                } header: { Text("Performance") } footer: { Text("Bigger chat memory remembers more of long chats but uses more of the iPhone's memory. Changes apply the next time a model loads.") }
                Section {
                    Text("LARP.AI for iPhone 1.0 · runs llama.cpp on the iPhone's GPU. No accounts, no cloud, no tracking.").font(.footnote).foregroundStyle(Theme.mute)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
