# LARP.AI for iPhone

Fully local AI on your iPhone: llama.cpp running on the iPhone's GPU, no accounts, no cloud.

- SwiftUI app, iOS 16+, iPhone and iPad.
- One-tap downloads of phone-sized models (Gemma 3 1B/4B, Llama 3.2 1B/3B, Qwen3 1.7B/4B).
- Streaming replies, chat history, dictation (on-device speech recognition), read aloud.

## Build

GitHub Actions (`.github/workflows/build-ipa.yml`) builds an **unsigned** `LARP.AI-unsigned.ipa` on every push to `main`
and publishes it as the `ios-latest` release. Sign it yourself (Sideloadly, AltStore, eSign…).

Locally on a Mac: put `llama.xcframework` (llama.cpp b11874) in `Frameworks/`, run `xcodegen generate`, open `LARPAI.xcodeproj`.
