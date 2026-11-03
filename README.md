# LARP.AI for iPhone

Made by Th3Monke.

Fully local AI on your iPhone: llama.cpp running on the iPhone's GPU, no accounts, no cloud.

- SwiftUI app, iOS 16.4+, iPhone and iPad.
- One-tap downloads of phone-sized LARP.AI models: Scout 2.5, Forge 3, Oracle 3.5 and Forge 3.5.
- Pick your own app color (presets or any color) and background in Settings → Look.
- Streaming replies, chat history, dictation (on-device speech recognition), read aloud.
- Talk mode: a hands-free voice conversation (listen, answer out loud, listen again).
- Add photos and files (PDF, text, code): text in photos is read and what they show is recognized, on the phone.
- Pictures: Canvas Mobile (Apple's Core ML Stable Diffusion, 6-bit) makes 512×512 pictures on the Neural Engine. iOS 17 and 6 GB of RAM.
- 👍/👎 on replies: it learns from them on the phone; optional, off-by-default sharing to improve LARP.AI.
- LARP.AI Pro: the same $5 key as on the PC (50 pictures/uploads a day instead of 20, bonus colors).

## Build

GitHub Actions (`.github/workflows/build-ipa.yml`) builds an **unsigned** `LARP.AI-unsigned.ipa` on every push to `main`
and publishes it as the `ios-latest` release. Sign it yourself (Sideloadly, AltStore, eSign…).

Locally on a Mac: put `llama.xcframework` (llama.cpp b11874) in `Frameworks/`, run `xcodegen generate`, open `LARPAI.xcodeproj`.
