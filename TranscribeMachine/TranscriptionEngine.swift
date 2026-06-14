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
        case local = "Local"
        case remote = "Remote"

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

    var labeledLine: String { "[\(speaker.rawValue)]: \(text)" }
}

// Actor isolates WhisperKit to avoid Swift 6 sendability errors
private actor WhisperActor {
    nonisolated(unsafe) var whisper: WhisperKit?

    func load() async throws {
        let config = WhisperKitConfig(
            model: "openai_whisper-small.en",
            verbose: false,
            logLevel: .none
        )
        whisper = try await WhisperKit(config)
    }

    func transcribe(audioArray: [Float]) async throws -> [TranscriptionResult]? {
        try await whisper?.transcribe(audioArray: audioArray)
    }
}

@MainActor
class TranscriptionEngine: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var modelReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var modelStatus: String = "Not downloaded"

    var fullTranscript: String {
        segments.map { $0.labeledLine }.joined(separator: "\n")
    }

    var plainTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    private let whisperActor = WhisperActor()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private let chunkSamples = Int(5.0 * 16000.0)
    private var isMicTranscribing = false
    private var isSystemTranscribing = false

    // MARK: – Model

    func prepareModel() {
        guard !isDownloading else { return }
        isDownloading = true
        modelStatus = "Downloading…"

        Task {
            do {
                try await whisperActor.load()
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

    // MARK: – Feed audio

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

    // RMS silence gate — skip chunks that are below this energy threshold
    private let silenceThreshold: Float = 0.02

    private func isSilent(_ chunk: [Float]) -> Bool {
        let rms = sqrt(chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count))
        return rms < silenceThreshold
    }

    private func transcribeChunk(_ chunk: [Float], speaker: TranscriptSegment.Speaker) {
        guard !isSilent(chunk) else { return }
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
                let results = try await whisperActor.transcribe(audioArray: chunk)
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
