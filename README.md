# TranscribeMachine

Local AI meeting transcriber for macOS. Everything runs on your machine — no cloud, no subscriptions.

**Stack:** SwiftUI · WhisperKit (Whisper base.en) · Ollama (llama3.2) · ScreenCaptureKit

---

## Features

- One-click microphone transcription
- System audio capture (Zoom, Meet, Teams, any app)
- Both simultaneously
- Auto-downloads Whisper model on first launch (~150MB)
- AI summarize or email draft via local Ollama
- Copy to clipboard

---

## Requirements

- macOS 14+ (Sonoma)
- Xcode 15+
- [Ollama](https://ollama.com) for AI features (optional)

---

## Setup

### 1. Clone and open

```bash
gh repo clone dssdave/TranscribeMachine
cd TranscribeMachine
open Package.swift  # opens in Xcode
```

### 2. Xcode config

- Set your Team in Signing & Capabilities
- Make sure entitlements file is linked
- Build target: My Mac

### 3. Install Ollama (for AI features)

```bash
# Install from https://ollama.com, then:
ollama pull llama3.2
```

### 4. Run

Hit ⌘R in Xcode. On first launch, WhisperKit downloads the Whisper model automatically.

**Grant permissions when prompted:**
- Microphone
- Screen Recording (for system audio)

---

## Architecture

```
TranscribeMachine/
├── Package.swift               # WhisperKit dependency
├── TranscribeMachine/
│   ├── TranscribeMachineApp.swift   # App entry
│   ├── ContentView.swift            # UI
│   ├── AudioRecorder.swift          # Mic + ScreenCaptureKit
│   ├── TranscriptionEngine.swift    # WhisperKit pipeline
│   ├── OllamaService.swift          # Local AI (summarize/email)
│   ├── Info.plist
│   └── TranscribeMachine.entitlements
```

---

## Create GitHub Repo

```bash
cd TranscribeMachine
git init
git add .
git commit -m "Initial commit: TranscribeMachine v1.0"
gh repo create dssdave/TranscribeMachine --public --source=. --push
```

---

## Notes

- WhisperKit uses Apple's CoreML — fast on M1/M2/M3, works on Intel
- System audio capture requires Screen Recording permission in System Settings → Privacy
- Ollama runs at `localhost:11434` — app auto-detects and shows setup instructions if missing
- The app gracefully degrades: transcription works without Ollama, AI features prompt install
