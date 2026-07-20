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
        case remote = "Speaker"

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
    @Published var needsDownloadConfirmation = false
    @Published var pendingDownloadSizeMB: Int = 0
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

    // Chunks are transcribed independently, so a word spanning the cut between two
    // chunks gets clipped in both. Keep the tail of each chunk in the buffer instead
    // of discarding it, so the next chunk re-transcribes that audio with full context —
    // dedupOverlap() then strips the words we already committed.
    private let overlapSamples = 16000  // 1 second at 16kHz
    private var lastMicText: String = ""
    private var lastSystemText: String = ""

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
        // swift-transformers HubApi defaults to Documents/huggingface (same in MAS sandbox)
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = docs
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelName)
        return fm.fileExists(atPath: modelDir.path)
    }

    private static func modelSizeMB(for quality: String) -> Int {
        switch quality {
        case "quality":  return 465
        case "balanced": return 120
        default:         return 39
        }
    }

    func prepareModel() {
        guard !isDownloading else { return }
        let quality = UserDefaults.standard.string(forKey: "whisperModelQuality") ?? "balanced"
        let name = Self.modelName(for: quality)
        if !Self.isCached(name) {
            pendingDownloadSizeMB = Self.modelSizeMB(for: quality)
            needsDownloadConfirmation = true
            return
        }
        startLoad()
    }

    func confirmDownload() {
        needsDownloadConfirmation = false
        startLoad()
    }

    func cancelDownload() {
        needsDownloadConfirmation = false
        modelStatus = "Not downloaded"
    }

    private func startLoad() {
        guard !isDownloading else { return }
        isDownloading = true
        let quality = UserDefaults.standard.string(forKey: "whisperModelQuality") ?? "balanced"
        let name = Self.modelName(for: quality)
        modelStatus = Self.isCached(name) ? "Loading…" : "Downloading… (first time only)"
        Task {
            do {
                try await whisperActor.load()
                await MainActor.run {
                    self.modelReady = true
                    self.isDownloading = false
                    self.modelStatus = "Ready"
                    self.loadedModel = self.whisperActor.loadedModel
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.modelStatus = "Download failed"
                }
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
            micBuffer.removeFirst(max(chunkSamples - overlapSamples, 1))
            transcribeChunk(chunk, speaker: .local)
        }
    }

    func feedSystem(buffer: AVAudioPCMBuffer) {
        guard modelReady else { return }
        systemBuffer.append(contentsOf: toFloatArray(buffer))
        if systemBuffer.count >= chunkSamples && !isSystemTranscribing {
            let chunk = Array(systemBuffer.prefix(chunkSamples))
            systemBuffer.removeFirst(max(chunkSamples - overlapSamples, 1))
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
                    let previous = speaker == .local ? self.lastMicText : self.lastSystemText
                    let merged = self.dedupOverlap(previousText: previous, newText: text)
                    if speaker == .local { self.lastMicText = text } else { self.lastSystemText = text }
                    guard !merged.isEmpty else { return }
                    self.segments.append(
                        TranscriptSegment(speaker: speaker, text: merged, timestamp: Date())
                    )
                }
            } catch {
                print("Transcription error (\(speaker.rawValue)): \(error)")
            }
        }
    }

    // Chunk n's last `overlapSamples` of audio reappears as the start of chunk n+1
    // (see feedMic/feedSystem), so the words WhisperKit produces there get transcribed
    // twice. Find the longest word-level suffix/prefix match and drop it from newText.
    private func dedupOverlap(previousText: String, newText: String) -> String {
        guard !previousText.isEmpty else { return newText }
        let prevWords = previousText.split(separator: " ").map(String.init)
        let newWords = newText.split(separator: " ").map(String.init)
        guard !prevWords.isEmpty, !newWords.isEmpty else { return newText }

        let maxCheck = min(prevWords.count, newWords.count, 12)
        var bestOverlap = 0
        for len in stride(from: maxCheck, through: 1, by: -1) {
            let prevTail = prevWords.suffix(len).map { $0.lowercased() }
            let newHead = newWords.prefix(len).map { $0.lowercased() }
            if prevTail == newHead {
                bestOverlap = len
                break
            }
        }
        guard bestOverlap > 0 else { return newText }
        return newWords.dropFirst(bestOverlap).joined(separator: " ")
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
        lastMicText = ""
        lastSystemText = ""
    }
}
