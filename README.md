# TranscribeMachine

Local AI transcription for macOS. Everything runs on your device — no cloud, no subscription, no data sent anywhere.

---

## What it does

- Real-time microphone transcription
- System audio capture (Zoom, Meet, Teams, browser, any app)
- Both simultaneously
- AI-powered Recap, Decisions, Next Steps, and Email from your transcript
- Customisable AI prompts per action
- Export to plain text

All speech recognition runs via [WhisperKit](https://github.com/argmaxinc/WhisperKit) on Apple's CoreML/Neural Engine. All AI analysis runs via [Ollama](https://ollama.com) locally. Nothing leaves your Mac.

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+ (to build from source)
- ~1GB free disk space (for model downloads on first launch)

---

## Build & run

```bash
gh repo clone dssdave/TranscribeMachine
cd TranscribeMachine
open TranscribeMachine.xcodeproj
```

In Xcode:
1. Set your Team in Signing & Capabilities
2. Select **My Mac** as the run destination
3. Hit ⌘R

On first launch the app downloads the Whisper model and Ollama binary automatically. Grant Microphone and Screen Recording permissions when prompted.

---

## Transcription quality tiers

| Tier | Model | Size | Notes |
|------|-------|------|-------|
| Fast | whisper-base.en | ~74 MB | Quickest, lowest accuracy |
| Balanced (default) | whisper-small.en | ~244 MB | Good accuracy, reasonable speed |
| Quality | whisper-medium.en | ~769 MB | Best accuracy, slower |

Models are downloaded once and cached. Switch tiers in Settings — the model reloads immediately.

---

## Architecture

```
TranscribeMachine/
├── TranscribeMachineApp.swift      # App entry, window sizing
├── ContentView.swift               # Full UI
├── AudioFileRecorder.swift         # Mic (AVCaptureSession) + system audio (ScreenCaptureKit)
├── TranscriptionEngine.swift       # WhisperKit pipeline, silence gate, chunk processing
├── OllamaService.swift             # Local AI: setup, model pull, prompt execution
├── WhisperXRunner.swift            # Optional speaker diarization via WhisperX (Python)
└── Info.plist                      # Permissions, version
```

**Audio pipeline:**
`AVCaptureAudioDataOutput` → `CMSampleBuffer` → `AVAudioPCMBuffer` (float32, 16kHz) → WhisperKit → transcript segments

**AI pipeline:**
Transcript → Ollama HTTP API (localhost:11434) → llama3.2:3b → formatted output

---

## Settings

| Setting | Options | Default |
|---------|---------|---------|
| Microphone | Available input devices | System default |
| Transcription Quality | Fast / Balanced / Quality | Balanced |
| Auto-Stop | Off / 5 / 10 / 15 / 30 min | Off |
| AI Prompts | Editable per action | Built-in defaults |

---

## Docs

- [Privacy Policy](docs/PRIVACY.md)
- [Terms of Use](docs/TERMS.md)
- [Support](docs/SUPPORT.md)
- [App Store Metadata](docs/APP_STORE.md)

---

## License

Source available for personal use. See [Terms of Use](docs/TERMS.md).

Third-party components retain their own licenses: WhisperKit (Apache 2.0), Ollama (MIT), Llama 3.2 (Meta Llama 3.2 Community License).
