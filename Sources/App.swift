import SwiftUI
import PhotosUI

@main
struct LarpApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.models)
                .environmentObject(state.learning)
                .environmentObject(state.pro)
                .environmentObject(state.pictures)
                .preferredColorScheme(.dark)
                .tint(state.accentColor)
        }
    }
}

/// The app's colors. They follow Settings → Look (app color + background); views that read them
/// observe AppState, so they redraw when it changes.
enum Theme {
    private(set) static var bg = Color(red: 0.122, green: 0.122, blue: 0.118)
    private(set) static var panel = Color(red: 0.165, green: 0.165, blue: 0.157)
    private(set) static var raise = Color(red: 0.19, green: 0.19, blue: 0.18)
    private(set) static var line = Color(red: 0.22, green: 0.22, blue: 0.21)
    static let mute = Color(red: 0.65, green: 0.64, blue: 0.61)

    @MainActor static func update(_ state: AppState) {
        let shades: [(Double, Double, Double)]
        switch state.background {
        case 1: shades = [(0.055, 0.066, 0.115), (0.10, 0.11, 0.18), (0.13, 0.14, 0.22), (0.18, 0.19, 0.28)]   // Midnight
        case 2: shades = [(0, 0, 0), (0.085, 0.085, 0.085), (0.13, 0.13, 0.13), (0.18, 0.18, 0.18)]           // Black
        case 3:                                                                                                // Tinted
            let a = rgb(state.accentColor), base: Double = 0.07
            shades = [0.10, 0.16, 0.21, 0.30].map { (k: Double) -> (Double, Double, Double) in
                (base + (a.0 - base) * k, base + (a.1 - base) * k, base + (a.2 - base) * k)
            }
        default: shades = [(0.122, 0.122, 0.118), (0.165, 0.165, 0.157), (0.19, 0.19, 0.18), (0.22, 0.22, 0.21)] // Charcoal
        }
        let c = shades.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
        bg = c[0]; panel = c[1]; raise = c[2]; line = c[3]
    }

    /// accent with its hue nudged both ways, like the PC app's gradient
    static func grad(_ accent: Color) -> LinearGradient {
        LinearGradient(colors: [shift(accent, hue: -0.075, light: 0.04), accent, shift(accent, hue: 0.11, light: 0.03)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private static func shift(_ c: Color, hue dh: CGFloat, light dl: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return Color(hue: h, saturation: s, brightness: min(1, b + dl * 3)) } // greys: just lighter
        return Color(hue: (h + dh + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: min(1, b + dl))
    }
    private static func rgb(_ c: Color) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var pro: Pro
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
        .sheet(item: $pro.lock) { LockSheet(reason: $0) }
        .task {
            state.learning.flush()
            Task { await pro.recheck() }
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
    @State private var rating: ChatMessage?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var talking = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let chat = state.current {
                            ForEach(chat.messages) { m in
                                MessageView(message: m, isLast: m.id == chat.messages.last?.id, rateDown: { rating = m }, openModels: { showModels = true })
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
        .sheet(item: $rating) { FeedbackSheet(message: $0) }
        .fullScreenCover(isPresented: $talking) { TalkView() }
        .onChange(of: photo) { item in
            guard let item else { return }
            photo = nil
            state.attach {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ReadError(message: "Couldn't open that photo.") }
                return try await Extract.photo(data, name: "Photo")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Extract.fileTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls { state.attach { try await Extract.file(u) } }
        }
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespaces).isEmpty || !state.pending.isEmpty }

    private var addMenu: some View {
        Menu {
            PhotosPicker(selection: $photo, matching: .images) { Label("Photo", systemImage: "photo") }
            Button { importing = true } label: { Label("File (PDF, text, code…)", systemImage: "doc") }
            Button {
                if !picturesSupported { state.errorText = "Making pictures needs iOS 17 and an iPhone with at least 6 GB of memory (iPhone 13 Pro or newer)." }
                else if !state.pictures.ready { showModels = true }
                else { input = "Make a picture of "; focused = true }
            } label: { Label("Make a picture", systemImage: "paintbrush") }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.mute)
                .frame(width: 32, height: 32)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let e = dictation.error { Text(e).font(.caption).foregroundStyle(.orange) }
            if !state.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.pending) { a in AttachmentChip(a: a) { state.pending.removeAll { $0.id == a.id } } }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                addMenu.padding(.leading, 4).padding(.bottom, 5)
                TextField(dictation.listening ? "Listening…" : "Message \(state.assistantName)…", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 10)
                Button { dictation.stop(); talking = true } label: {
                    Image(systemName: "waveform").font(.system(size: 19)).foregroundStyle(Theme.mute)
                }.padding(.bottom, 9).accessibilityLabel("Talk")
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
                .disabled(!state.streaming && !canSend)
                .opacity(!state.streaming && !canSend ? 0.4 : 1)
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
    /// lists and sheets use the chosen background instead of the system grey
    func themedList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .presentationBackground(Theme.bg)
    }
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
    @EnvironmentObject var pictures: PictureModel
    let message: ChatMessage
    let isLast: Bool
    var rateDown: () -> Void = {}
    var openModels: () -> Void = {}
    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 6) {
                if let files = message.files, !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(files) { AttachmentChip(a: $0) } }
                    }
                    .frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer(minLength: 50)
                    Text(message.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.raise, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar()
                VStack(alignment: .leading, spacing: 8) {
                    RichText(text: message.text)
                    picture
                    HStack(spacing: 18) {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { state.speech.speaking ? state.speech.stop() : state.speech.speak(message.text) } label: { Label("Read", systemImage: "speaker.wave.2") }
                        if isLast { Button { Task { await state.retry() } } label: { Label("Retry", systemImage: "arrow.clockwise") } }
                        Button { state.rate(message.id, up: true) } label: {
                            Label("Good reply", systemImage: message.fb == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        }.foregroundStyle(message.fb == "up" ? state.accentColor : Theme.mute)
                        Button(action: rateDown) {
                            Label("Bad reply", systemImage: message.fb == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        }.foregroundStyle(message.fb == "down" ? state.accentColor : Theme.mute)
                        if let s = message.stats { Text(s).lineLimit(1).foregroundStyle(Theme.mute.opacity(0.7)) }
                    }
                    .font(.caption).foregroundStyle(Theme.mute).labelStyle(.iconOnly)
                }
            }
        }
    }

    /// the picture this reply made, its progress, or how to get it made
    @ViewBuilder private var picture: some View {
        if let f = message.image, let img = Media.image(f) {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 320).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                ShareLink(item: Image(uiImage: img), preview: SharePreview("Picture from LARP.AI", image: Image(uiImage: img))) {
                    Label("Save or share", systemImage: "square.and.arrow.up").font(.caption)
                }
            }
        } else if let p = state.picProgress[message.id] {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p).tint(state.accentColor).frame(maxWidth: 260)
                Text(p < 0.02 ? "Getting the picture model ready…" : "Making a picture… \(Int(p * 100))%").font(.caption).foregroundStyle(Theme.mute)
            }
        } else if message.imagePrompt != nil {
            if !picturesSupported {
                Text("Making pictures needs iOS 17 and an iPhone with at least 6 GB of memory.").font(.caption).foregroundStyle(Theme.mute)
            } else if !pictures.ready {
                Button(action: openModels) { Label("Download \(PIC_NAME) (1.1 GB) to make pictures", systemImage: "arrow.down.circle") }
                    .font(.caption).buttonStyle(.bordered)
            } else {
                Button { if let c = state.currentID { Task { await state.makePicture(chat: c, message: message.id) } } } label: {
                    Label("Make the picture", systemImage: "paintbrush")
                }.font(.caption).buttonStyle(.bordered)
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
            // hide a [[image: …]] tag while it streams in
            let shown = AppState.cleanReply(text).replacingOccurrences(of: #"\[\[[^\]]*(\]\])?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
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
    @EnvironmentObject var state: AppState // redraws code blocks when the look changes
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
            .themedList()
            .navigationTitle("Chats")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var models: ModelManager
    @EnvironmentObject var pictures: PictureModel
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
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(PIC_NAME).font(.headline)
                            Text("1.1 GB").font(.caption).foregroundStyle(Theme.mute)
                            Spacer()
                            if pictures.ready { Text("READY").font(.caption2.bold()).foregroundStyle(state.accentColor) }
                        }
                        Text("Makes pictures on your iPhone's Neural Engine when you ask (\"make a picture of…\"). About 20–40 seconds a picture. Free: \(FREE_DAILY) a day, Pro: \(PRO_DAILY).")
                            .font(.footnote).foregroundStyle(Theme.mute)
                        if !picturesSupported {
                            Text("Needs iOS 17 and an iPhone with at least 6 GB of memory (iPhone 13 Pro or newer).").font(.caption).foregroundStyle(.orange)
                        } else if let p = pictures.progress {
                            ProgressView(value: p).tint(state.accentColor)
                            HStack { Text("\(Int(p * 100))%").font(.caption).foregroundStyle(Theme.mute); Spacer(); Button("Cancel", role: .cancel) { pictures.cancel() }.font(.caption) }
                        } else if pictures.ready {
                            Button("Delete", role: .destructive) { pictures.delete() }.buttonStyle(.bordered)
                        } else {
                            Button("Download") { pictures.download() }.buttonStyle(.borderedProminent)
                        }
                        if let e = pictures.error { Text(e).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 4)
                } header: { Text("Pictures") }
            }
            .themedList()
            .navigationTitle("Models")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var learning: Learning
    @EnvironmentObject var pro: Pro
    @Environment(\.dismiss) var dismiss
    @State private var perk: LockReason?
    var body: some View {
        NavigationStack {
            Form {
                ProSection()
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(ACCENTS.indices, id: \.self) { i in
                            Button {
                                if state.colorLocked(i) { perk = .perk } else { withAnimation(.easeOut(duration: 0.2)) { state.accent = i } }
                            } label: {
                                Circle().fill(Theme.grad(ACCENTS[i].1)).frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Color.white, lineWidth: state.accent == i && !state.colorLocked(i) ? 2.5 : 0).padding(-4))
                                    .overlay(Image(systemName: state.colorLocked(i) ? "lock.fill" : "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        .opacity(state.colorLocked(i) ? 0.85 : (state.accent == i ? 1 : 0)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(ACCENTS[i].0)
                        }
                    }
                    .padding(.vertical, 6)
                    if pro.active {
                        ColorPicker(selection: state.customAccentBinding, supportsOpacity: false) {
                            HStack {
                                Text("Pick any color")
                                if state.accent == CUSTOM_ACCENT { Text("· yours").foregroundStyle(Theme.mute) }
                            }
                        }
                    } else {
                        Button { perk = .perk } label: {
                            HStack { Text("Pick any color").foregroundStyle(.primary); Spacer(); Label("Pro", systemImage: "lock.fill").font(.caption) }
                        }
                    }
                    Picker("Background", selection: $state.background) {
                        ForEach(BACKGROUNDS.indices, id: \.self) { i in Text(BACKGROUNDS[i]).tag(i) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Look") } footer: { Text("Your color is used for buttons, the send button, \(state.assistantName)'s avatar and highlights. Tinted mixes it into the background too." + (pro.active ? "" : " The first five colors are free; the rest and your own color come with Pro.")) }
                Section("Assistant") {
                    TextField("Name", text: $state.assistantName)
                    Toggle("Read replies out loud", isOn: $state.readAloud)
                    Toggle("Let Forge think first (slower, smarter)", isOn: $state.think)
                }
                Section("Instructions") {
                    TextField("Custom instructions (optional)", text: $state.systemPrompt, axis: .vertical).lineLimit(3...8)
                }
                Section {
                    Toggle("Learn from my 👍 / 👎", isOn: $learning.on)
                    ForEach(learning.notes) { n in
                        Text(n.text).font(.footnote)
                    }
                    .onDelete { idx in idx.map { learning.notes[$0].id }.forEach { learning.forget($0) } }
                    if !learning.notes.isEmpty {
                        Button("Forget everything it learned", role: .destructive) { learning.notes = [] }
                    }
                } header: { Text("Learning") } footer: {
                    Text(learning.notes.isEmpty ? "Tap 👎 on a reply and say what was wrong. \(state.assistantName) learns it on this iPhone and does better next time. Swipe a lesson to delete it."
                         : "What \(state.assistantName) learned from you. It follows these in every chat. Swipe one to delete it.")
                }
                Section {
                    Toggle("Help make LARP.AI smarter", isOn: $learning.share)
                } footer: {
                    Text("Completely optional, and off unless you turn it on. When it's on and you're online, each reply you rate (the question, the reply and your note) is sent to Th3Monke, who reads them before every update to improve LARP.AI for everyone. Nothing else is ever sent, and your own learning above works without it.")
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
                    Text("LARP.AI for iPhone \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · made by Th3Monke. Runs 100% on your iPhone's GPU. No accounts, no cloud, no tracking.").font(.footnote).foregroundStyle(Theme.mute)
                }
            }
            .themedList()
            .sheet(item: $perk) { LockSheet(reason: $0) }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
