import Foundation
import AVFoundation
import Speech

/// Reads replies out loud with the iPhone's built-in voices.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let clean = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " (the code is in the chat) ", options: .regularExpression)
            .replacingOccurrences(of: "[*_#`>]", with: "", options: .regularExpression)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
        speaking = true
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

/// Talk instead of type: on-device speech recognition (when the iPhone supports it).
@MainActor
final class Dictation: ObservableObject {
    @Published var listening = false
    @Published var text = ""
    @Published var error: String?

    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    func toggle() { listening ? stop() : start() }

    func start() {
        error = nil
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { self.error = "Allow speech recognition in Settings → LARP.AI."; return }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    Task { @MainActor in
                        if ok { self.begin() } else { self.error = "Allow the microphone in Settings → LARP.AI." }
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognition isn't available right now."; return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { self.error = "Couldn't use the microphone."; return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        text = ""

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        audio.prepare()
        do { try audio.start() } catch { self.error = "Couldn't start the microphone."; return }
        listening = true

        task = recognizer.recognitionTask(with: req) { result, err in
            Task { @MainActor in
                if let result { self.text = result.bestTranscription.formattedString }
                if err != nil || (result?.isFinal ?? false) { self.stop() }
            }
        }
    }

    func stop() {
        guard listening else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
