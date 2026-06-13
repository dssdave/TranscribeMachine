import AVFoundation
import WhisperKit
import SwiftUI

// A single transcribed segment with speaker label and source
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let timestamp: Date

    enum Speaker: String {
        case local = "Local"       // microphone — person in room
        case remote = "Remote"     // system audio — Zoom/Meet caller

        var color: Color {
            switch self {
            case .local:  return Color(red: 0.4, green: 0.6, blue: 1.0)
            case .remote: return Color(red: 0.8, green: 0.45, blue: 1.0)
            }
        }

        var icon: String {
            switch self {
            case .local:  return "mic.fill"
            case .remote: return "speaker.wave.2.fill"
            }
        }
    }

    // Plain text for AI consumption
    var labeledLine: String { "[\(speaker.rawValue)]: \(text)" }
}

@MainActor
class TranscriptionEngine: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var modelReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var modelStatus: String = "Not downloaded"

    // Flat labeled text for AI
    var fullTranscript: String {
        segments.map { $0.labeledLine }.joined(separator: "\n")
    }

    // Plain text (no labels) for display fallback
    var plainTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    private var whisper: WhisperKit?

    // Separate rolling buffers per source
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private let chunkSamples = Int(5.0 * 16000.0)  // 5s @ 16kHz

    private var isMicTranscribing = false
    private var isSystemTranscribing = false

    // MARK: – Model

    func prepareModel() {
        guard !isDownloading else { return }
        isDownloading = true
        modelStatus = "Downloading…"

        Task {
            do {
                let config = WhisperKitConfig(
                    model: "openai_whisper-base.en",
                    verbose: false,
                    logLevel: .none
                )
                whisper = try await WhisperKit(config)
                modelReady = true
                isDownloading = false
                modelStatus = "Ready"
            } catch {
                isDownloading = false
                modelStatus = "Download failed"
                print("WhisperKit error: \(error)")
            }
        }
    }

    // MARK: – Feed audio by source

    func feedMic(buffer: AVAudioPCMBuffer) {
        guard modelReady else { return }
        micBuffer.append(contentsOf: toFloatArray(buffer))
        if micBuffer.count >= chunkSamples && !isMicTranscribing {
            let chunk = Array(micBuffer.prefix(chunkSamples))
            micBuffer.removeFirst(chunkSamples)
            transcribeChunk(chunk, speaker: .local)
        }
    }

    func feedSystem(buffer: AVAudioPCMBuffer) {
        guard modelReady else { return }
        systemBuffer.append(contentsOf: toFloatArray(buffer))
        if systemBuffer.count >= chunkSamples && !isSystemTranscribing {
            let chunk = Array(systemBuffer.prefix(chunkSamples))
            systemBuffer.removeFirst(chunkSamples)
            transcribeChunk(chunk, speaker: .remote)
        }
    }

    // MARK: – Transcribe

    private func transcribeChunk(_ chunk: [Float], speaker: TranscriptSegment.Speaker) {
        if speaker == .local { isMicTranscribing = true }
        else { isSystemTranscribing = true }

        Task {
            defer {
                Task { @MainActor in
                    if speaker == .local { self.isMicTranscribing = false }
                    else { self.isSystemTranscribing = false }
                }
            }
            do {
                let results = try await whisper?.transcribe(audioArray: chunk)
                let text = results?
                    .map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard !text.isEmpty, text != "[BLANK_AUDIO]" else { return }

                await MainActor.run {
                    self.segments.append(
                        TranscriptSegment(speaker: speaker, text: text, timestamp: Date())
                    )
                }
            } catch {
                print("Transcription error (\(speaker.rawValue)): \(error)")
            }
        }
    }

    // MARK: – Helpers

    private func toFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        var samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let peak = samples.map(abs).max() ?? 1.0
        if peak > 0 { samples = samples.map { $0 / peak * 0.95 } }
        return samples
    }

    func clear() {
        segments = []
        micBuffer = []
        systemBuffer = []
    }
}
