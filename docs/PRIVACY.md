# Privacy Policy — TranscribeMachine

**Effective date:** June 18, 2026
**Developer:** David S. (dssdave@gmail.com)

---

## The short version

TranscribeMachine is designed from the ground up to keep everything on your device. Your audio, your transcripts, and your AI analysis never leave your Mac.

---

## What the app does with your data

### Audio (microphone and system audio)

TranscribeMachine captures audio from your microphone and/or your Mac's system audio output. This audio is:

- Processed entirely on your device using [WhisperKit](https://github.com/argmaxinc/WhisperKit), a local implementation of OpenAI's Whisper model running via Apple CoreML
- Never uploaded to any server
- Never stored to disk in a form you did not explicitly initiate (see Export below)
- Discarded from memory when you clear the transcript or close the app

Temporary audio files may be written to your Mac's temp directory (`/tmp`) during a session to support diarization features. These files are deleted automatically after processing.

### Transcripts

Transcripts exist only in memory while the app is open. The app does not automatically save transcripts to disk. If you use the Export feature, the file is saved to a location you choose. That file is yours — the app does not retain a copy.

### AI analysis (Recap, Decisions, Next Steps, Email)

AI features run using [Ollama](https://ollama.com), a local AI runtime that runs entirely on your Mac. Transcripts sent to the AI never leave your device. No cloud AI service is used.

### App settings

Settings (microphone preference, transcription quality, auto-stop duration, custom prompts) are stored locally in your Mac's standard user preferences (`UserDefaults`). They do not leave your device.

### HuggingFace token

If you use the speaker diarization feature, you may optionally enter a HuggingFace access token. This token is stored in your Mac's Keychain — the system's secure credential store — and is only used to authenticate model downloads from HuggingFace. The token is never transmitted to any server controlled by this app.

---

## One-time downloads

On first launch, the app downloads the following to your Mac:

| What | From | Why |
|------|------|-----|
| Whisper speech model | HuggingFace (argmaxinc/whisperkit-coreml) | Local transcription |
| Ollama binary | GitHub (ollama/ollama releases) | Local AI runtime |
| llama3.2:3b model | Ollama model registry | Local AI analysis |

These are downloads **to** your device. No audio, transcript, or personal data is sent as part of these requests. After the initial download, the app functions fully offline.

---

## What we do not collect

- No analytics or usage tracking
- No crash reporting sent to third parties
- No advertising identifiers
- No personal information of any kind
- No audio recordings
- No transcripts

---

## Third-party components

TranscribeMachine uses open-source components. Their respective privacy policies govern any interactions with their infrastructure during the one-time download phase only:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Apache 2.0
- [Ollama](https://ollama.com/privacy) — MIT
- [OpenAI Whisper](https://openai.com/policies/privacy-policy) (model weights only, processed locally)
- [Meta Llama 3.2](https://www.llama.com/llama3_2/license/) (model weights only, processed locally)

---

## macOS permissions

The app requests the following system permissions:

- **Microphone** — to capture your voice for transcription
- **Screen Recording** — required by macOS to capture system audio from other apps (e.g. Zoom, browser, video calls). No screen images or visual content are ever captured or used.

You can revoke these permissions at any time in System Settings → Privacy & Security.

---

## Children

This app is not directed at children under 13 and does not knowingly collect any information from children.

---

## Changes to this policy

If this policy changes materially, the effective date above will be updated. The latest version is always at this URL.

---

## Contact

Questions about privacy? Email: dssdave@gmail.com
