import Foundation
import SwiftUI
import AVFoundation
import Speech

/// Talk mode: listen → (a short pause ends your turn) → answer out loud → listen again. All on the iPhone.
@MainActor
final class TalkController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, listening, thinking, speaking }
    @Published var phase: Phase = .idle
    @Published var heard = ""
    @Published var said = ""
    @Published var error: String?

    weak var state: AppState?
    private var active = false
    private let audio = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pause: Task<Void, Never>?
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func start(_ state: AppState) {
        self.state = state
        active = true
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "Allow speech recognition in Settings → LARP.AI."; return }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    Task { @MainActor in
                        if ok { self.listen() } else { self.error = "Allow the microphone in Settings → LARP.AI." }
                    }
                }
            }
        }
    }

    func end() {
        active = false
        stopListening()
        synth.stopSpeaking(at: .immediate)
        state?.stop()
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Tap the circle: stop talking and listen, or finish your turn now.
    func tap() {
        switch phase {
        case .speaking: synth.stopSpeaking(at: .immediate)
        case .listening: finishTurn()
        default: break
        }
    }

    private func listen() {
        guard active else { return }
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now."; return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
        } catch { self.error = "Couldn't use the microphone."; return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        heard = ""
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        audio.prepare()
        do { try audio.start() } catch { self.error = "Couldn't start the microphone."; return }
        phase = .listening

        task = recognizer.recognitionTask(with: req) { result, err in
            Task { @MainActor in
                guard self.phase == .listening else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    // about a second and a half of quiet ends your turn
                    self.pause?.cancel()
                    self.pause = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if !Task.isCancelled { self.finishTurn() }
                    }
                    if result.isFinal { self.finishTurn() }
                } else if err != nil {
                    self.finishTurn()
                }
            }
        }
    }

    private func stopListening() {
        pause?.cancel(); pause = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
    }

    private func finishTurn() {
        guard phase == .listening else { return }
        stopListening()
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let state else { listen(); return }
        phase = .thinking
        Task {
            let reply = await state.send(text, voice: true)
            guard self.active else { return }
            guard let reply, !reply.isEmpty else { self.listen(); return }
            self.speak(reply)
        }
    }

    private func speak(_ text: String) {
        said = text
        phase = .speaking
        let clean = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " (the code is in the chat) ", options: .regularExpression)
            .replacingOccurrences(of: "[*_#`>]", with: "", options: .regularExpression)
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.listen() } }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.listen() } }
    }
}

struct TalkView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @StateObject private var talk = TalkController()
    @State private var pulse = false

    private var caption: String {
        switch talk.phase {
        case .idle: return "Starting…"
        case .listening: return talk.heard.isEmpty ? "Listening…" : talk.heard
        case .thinking: return "Thinking…"
        case .speaking: return talk.said
        }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 28) {
                HStack {
                    Text("Talking with \(state.assistantName)").font(.headline)
                    Spacer()
                    Text(state.currentModel?.name ?? "").font(.caption).foregroundStyle(Theme.mute)
                }
                .padding(.horizontal, 22).padding(.top, 12)
                Spacer()
                Button { talk.tap() } label: {
                    ZStack {
                        Circle().fill(Theme.grad(state.accentColor)).opacity(0.25)
                            .frame(width: 230, height: 230).scaleEffect(pulse ? 1.12 : 0.92)
                        Circle().fill(Theme.grad(state.accentColor)).frame(width: 170, height: 170)
                            .scaleEffect(talk.phase == .speaking ? (pulse ? 1.06 : 0.97) : 1)
                        Image(systemName: talk.phase == .listening ? "waveform" : talk.phase == .speaking ? "speaker.wave.2.fill" : "ellipsis")
                            .font(.system(size: 44, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: talk.phase == .listening ? 0.9 : 0.5).repeatForever(autoreverses: true), value: pulse)
                Text(caption).font(.title3).multilineTextAlignment(.center).lineLimit(6)
                    .foregroundStyle(talk.phase == .speaking ? .primary : Theme.mute)
                    .padding(.horizontal, 28).frame(minHeight: 120, alignment: .top)
                if let e = talk.error { Text(e).font(.footnote).foregroundStyle(.orange).padding(.horizontal, 28) }
                Spacer()
                Text(talk.phase == .speaking ? "Tap the circle to interrupt" : talk.phase == .listening ? "Pause to send, or tap the circle" : " ")
                    .font(.caption).foregroundStyle(Theme.mute)
                Button { talk.end(); dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(Color.red.opacity(0.85), in: Circle())
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear { pulse = true; talk.start(state) }
        .onDisappear { talk.end() }
    }
}
