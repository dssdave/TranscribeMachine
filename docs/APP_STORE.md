# App Store Metadata — TranscribeMachine

Reference doc for App Store Connect submission. Copy-paste ready.

---

## App name

TranscribeMachine

## Subtitle (30 chars max)

Local AI Meeting Transcriber

## Category

Primary: **Productivity**
Secondary: **Business**

---

## Description (4000 chars max)

TranscribeMachine transcribes your meetings, calls, and videos — entirely on your Mac. No cloud. No subscription. No one else's servers.

**Everything runs locally.**
Your audio never leaves your device. WhisperKit (Apple's CoreML implementation of OpenAI Whisper) processes speech directly on your Mac's Neural Engine. The AI analysis runs via a local engine — no API key, no account, no data sent anywhere.

**What it does**

- Transcribe your microphone in real time
- Capture system audio from Zoom, Google Meet, Teams, FaceTime, browser video, or any app
- Transcribe both simultaneously and merge the result
- Generate an AI summary, key decisions, next steps, or a follow-up email from the transcript — all on-device
- Customise the AI prompt for each button to match your workflow
- Export transcripts as plain text

**Three quality tiers**
Choose Fast (base model, instant), Balanced (small model, great accuracy), or Quality (medium model, best accuracy). Models download once and are cached locally.

**Built for privacy**
TranscribeMachine was built specifically for situations where you cannot use cloud transcription services — confidential meetings, client calls, sensitive content. Nothing ever leaves your Mac.

**Auto-stop**
Set a silence timeout and the app stops recording automatically when no one is talking — useful for long recordings you walk away from.

**Customisable AI prompts**
Every AI button has an editable prompt in Settings. Tune the Recap, Decisions, Next Steps, and Email outputs for your exact use case. Reset to default any time.

---

## Keywords (100 chars max, comma separated)

transcribe,meeting,recorder,transcription,whisper,AI,local,offline,privacy,summary,notes,caption

---

## Support URL

https://1hsaved.com/transcribemachine/privacy

## Marketing URL (optional)

https://1hsaved.com/transcribemachine

## Privacy Policy URL

https://1hsaved.com/transcribemachine/privacy

---

## Age rating

**4+** — no objectionable content

---

## Privacy nutrition labels (App Store Connect → App Privacy)

### Data Not Collected

TranscribeMachine does not collect any data from users.

Select: **"We do not collect data from this app"**

### Permissions to declare

In the "App Privacy" section, you do NOT need to add any data types under "Data Used to Track You" or "Data Linked to You" or "Data Not Linked to You" — the app collects nothing.

However, you will need to justify the following permission strings in App Store review:

**Microphone (NSMicrophoneUsageDescription)**
> "TranscribeMachine uses your microphone to transcribe speech. Audio is processed locally on your device and never transmitted."

**Screen Recording** (declared via entitlement, used for system audio via ScreenCaptureKit)
> "TranscribeMachine uses Screen Recording access to capture system audio from other apps for transcription. No screen images or visual content are ever captured or used."

---

## What's New (version 1.0)

First release.

TranscribeMachine brings private, on-device transcription to your Mac. Record your microphone, system audio, or both — then let local AI turn the transcript into a summary, action items, or a follow-up email. Nothing leaves your device.

---

## Review notes (for App Store reviewer)

This app requires:
- Microphone permission — to transcribe voice audio
- Screen Recording permission — used exclusively to capture system audio output via Apple's ScreenCaptureKit API. No screen content (pixels, windows, images) is captured. This is a documented Apple API for audio-only capture.

On first launch the app downloads AI model files (~300MB total) from HuggingFace and GitHub. These are one-time downloads for the local AI engine. No user data is transmitted.

The app functions fully offline after initial model download.
