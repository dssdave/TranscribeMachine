# Support — TranscribeMachine

**Contact:** dssdave@gmail.com

---

## Frequently asked questions

### The app says "Setting up…" for a long time on first launch

TranscribeMachine downloads the speech recognition model and AI engine the first time it runs. Depending on your internet speed, this can take several minutes. The header will show "Downloading… (first time only)" while this is happening. Once complete, the app works fully offline.

### Transcription quality isn't great

Try switching to a higher quality tier in Settings → Transcription Quality. "Balanced" uses a medium-sized model; "Quality" uses a larger one and will take a few minutes to download the first time. Speaking clearly and reducing background noise also significantly improves accuracy.

### No transcript is appearing while I record

1. Make sure you have granted Microphone permission in System Settings → Privacy & Security → Microphone
2. Check that the correct microphone is selected in Settings
3. The app applies a silence gate — very quiet audio below the noise floor is skipped. Speak at a normal volume.
4. Transcription appears in chunks (every 8–15 seconds depending on quality setting), not word by word.

### Computer Audio capture isn't working

System audio capture requires Screen Recording permission. Go to System Settings → Privacy & Security → Screen Recording and enable TranscribeMachine. You will need to restart the app after granting this permission.

### The AI features (Recap, Decisions, etc.) show "AI is not ready yet"

The app includes a local AI engine (Ollama) that it downloads and manages automatically. If it shows not ready, wait a moment after launch — it may still be starting up. If the problem persists, try quitting and relaunching the app.

### Changing the transcription quality model doesn't seem to do anything

When you switch quality in Settings, the app reloads the model immediately — you'll see "Loading…" or "Downloading…" in the header. The AI analysis buttons will be unavailable briefly while the model loads. If switching to "Quality" fails, it may be downloading a large model for the first time; allow a few minutes.

### I need the transcript to be more accurate for a specific use case

You can customise the AI prompts for each button (Recap, Decisions, Next Steps, Email) in Settings → AI Prompts. The underlying transcription accuracy is determined by the Whisper model you have selected; the AI prompts only affect the summary/analysis step.

### Does the app store my recordings?

No. Audio is processed in memory and discarded. Transcripts exist only in the app's memory until you export them. Nothing is uploaded to any server — all processing happens on your Mac. See the [Privacy Policy](PRIVACY.md) for full details.

### The app isn't available in my country's App Store

Contact dssdave@gmail.com and we'll look into regional availability.

---

## Known limitations

- Transcription accuracy is lower for strong accents, overlapping speakers, or noisy environments
- The AI summary quality is limited by the small on-device model (llama3.2:3b). For better results, customise the prompt in Settings
- Speaker diarization (identifying who said what) requires WhisperX and a HuggingFace account
- System audio capture is not available while the app is in the background

---

## Sending feedback

Email dssdave@gmail.com with:
- What you expected to happen
- What actually happened
- Your macOS version (Apple menu → About This Mac)
- TranscribeMachine version (visible in Settings)
