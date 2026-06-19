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
        case local = "You"
        case remote = "Caller"

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
    nonisolated(unsafe) var loadedModel: String = ""

    func load() async throws {
        let quality = UserDefaults.standard.string(forKey: "whisperModelQuality") ?? "balanced"
        let model: String
        switch quality {
        case "quality":  model = "openai_whisper-medium.en"
        case "balanced": model = "openai_whisper-small.en"
        default:         model = "openai_whisper-base.en"
        }
        let config = WhisperKitConfig(model: model, verbose: false, logLevel: .none)
        whisper = try await WhisperKit(config)
        loadedModel = model
    }

    func transcribe(audioArray: [Float]) async throws -> [TranscriptionResult]? {
        let langCode = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        let suppressRepetition = UserDefaults.standard.bool(forKey: "suppressRepetition")

        let strictConfidence = UserDefaults.standard.bool(forKey: "strictConfidence")

        var options = DecodingOptions()
        options.language = langCode == "auto" ? nil : langCode
        options.skipSpecialTokens = true
        options.compressionRatioThreshold = suppressRepetition ? 1.8 : 2.4
        options.logProbThreshold = strictConfidence ? -0.5 : -1.0

        return try await whisper?.transcribe(audioArray: audioArray, decodeOptions: options)
    }
}

@MainActor
class TranscriptionEngine: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var modelReady = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var modelStatus: String = "Not downloaded"
    @Published var lastActivityDate: Date?
    @Published var loadedModel: String = ""

    func resetActivity()  { lastActivityDate = nil }
    func extendActivity() { lastActivityDate = Date() }

    var fullTranscript: String {
        segments.map { $0.labeledLine }.joined(separator: "\n")
    }

    var plainTranscript: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    private let whisperActor = WhisperActor()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private var chunkSamples: Int {
        let override = UserDefaults.standard.integer(forKey: "chunkLengthSeconds")
        let seconds: Double
        if override > 0 {
            seconds = Double(override)
        } else {
            switch UserDefaults.standard.string(forKey: "whisperModelQuality") ?? "balanced" {
            case "quality":  seconds = 15
            case "balanced": seconds = 10
            default:         seconds = 8
            }
        }
        return Int(seconds * 16000.0)
    }

    private var silenceThreshold: Float {
        switch UserDefaults.standard.string(forKey: "noiseGate") ?? "normal" {
        case "strict":    return 0.02   // only loud, clear speech
        case "sensitive": return 0.001  // picks up quiet speech
        default:          return 0.005  // normal
        }
    }
    private var isMicTranscribing = false
    private var isSystemTranscribing = false

    // MARK: – Model

    func reloadModel() {
        modelReady = false
        loadedModel = ""
        isDownloading = false
        prepareModel()
    }

    private static func modelName(for quality: String) -> String {
        switch quality {
        case "quality":  return "openai_whisper-medium.en"
        case "balanced": return "openai_whisper-small.en"
        default:         return "openai_whisper-base.en"
        }
    }

    private static func isCached(_ modelName: String) -> Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    func prepareModel() {
        guard !isDownloading else { return }
        isDownloading = true
        let quality = UserDefaults.standard.string(forKey: "whisperModelQuality") ?? "balanced"
        let name = Self.modelName(for: quality)
        modelStatus = Self.isCached(name) ? "Loading…" : "Downloading… (first time only)"

        Task {
            do {
                try await whisperActor.load()
                modelReady = true
                isDownloading = false
                modelStatus = "Ready"
                loadedModel = whisperActor.loadedModel
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

    private func isSilent(_ chunk: [Float]) -> Bool {
        let rms = sqrt(chunk.map { $0 * $0 }.reduce(0, +) / Float(chunk.count))
        return rms < silenceThreshold
    }

    private func transcribeChunk(_ chunk: [Float], speaker: TranscriptSegment.Speaker) {
        guard !isSilent(chunk) else { return }
        lastActivityDate = Date()
        if speaker == .local { isMicTranscribing = true }
        else { isSystemTranscribing = true }

        Task(priority: .userInitiated) {
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
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    func clear() {
        segments = []
        micBuffer = []
        systemBuffer = []
    }
}
