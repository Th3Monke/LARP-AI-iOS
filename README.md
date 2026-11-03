# LARP.AI for iPhone

Made by Th3Monke.

Fully local AI on your iPhone: llama.cpp running on the iPhone's GPU, no accounts, no cloud.

- SwiftUI app, iOS 16.4+, iPhone and iPad.
- One-tap downloads of phone-sized LARP.AI models: Scout 2.5, Forge 3, Oracle 3.5 and Forge 3.5.
- Pick your own app color (presets or any color) and background in Settings → Look.
- Streaming replies, chat history, dictation (on-device speech recognition), read aloud.

## Build

GitHub Actions (`.github/workflows/build-ipa.yml`) builds an **unsigned** `LARP.AI-unsigned.ipa` on every push to `main`
and publishes it as the `ios-latest` release. Sign it yourself (Sideloadly, AltStore, eSign…).

Locally on a Mac: put `llama.xcframework` (llama.cpp b11874) in `Frameworks/`, run `xcodegen generate`, open `LARPAI.xcodeproj`.
