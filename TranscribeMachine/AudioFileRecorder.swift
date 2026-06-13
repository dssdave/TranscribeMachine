import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Records mic and system audio to WAV files on disk simultaneously with live feeding.
/// After stopRecording(), localFileURL and remoteFileURL are ready for WhisperX.
@MainActor
class AudioFileRecorder: ObservableObject {

    @Published var micActive = false
    @Published var systemActive = false

    var isRecording: Bool { micActive || systemActive }

    // File URLs set after recording stops
    private(set) var localFileURL: URL?
    private(set) var remoteFileURL: URL?

    // Injected — feeds real-time WhisperKit
    weak var transcriptionEngine: TranscriptionEngine?

    // Audio engine for mic
    private var audioEngine = AVAudioEngine()

    // File writers
    private var localWriter: AVAudioFile?
    private var remoteWriter: AVAudioFile?

    // ScreenCaptureKit
    private var scStream: SCStream?
    private var scOutput: SCAudioOutput?

    // MARK: – Mic

    func toggleMic() {
        micActive ? stopMic() : startMic()
    }

    private func startMic() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let fileURL = tempWAV("local")

        do {
            localWriter = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            localFileURL = fileURL

            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                // Write to disk
                try? self?.localWriter?.write(from: buffer)
                // Feed live transcription
                Task { @MainActor in
                    self?.transcriptionEngine?.feedMic(buffer: buffer)
                }
            }

            try audioEngine.start()
            micActive = true
        } catch {
            print("Mic start error: \(error)")
        }
    }

    private func stopMic() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        localWriter = nil  // flushes and closes
        micActive = false
    }

    // MARK: – System Audio

    func toggleSystemAudio() {
        if systemActive { Task { await stopSystemAudio() } }
        else { Task { await startSystemAudio() } }
    }

    private func startSystemAudio() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1

            let fileURL = tempWAV("remote")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            remoteWriter = try AVAudioFile(forWriting: fileURL, settings: format.settings)
            remoteFileURL = fileURL

            let output = SCAudioOutput { [weak self] buffer in
                try? self?.remoteWriter?.write(from: buffer)
                Task { @MainActor in
                    self?.transcriptionEngine?.feedSystem(buffer: buffer)
                }
            }
            self.scOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()

            self.scStream = stream
            self.systemActive = true
        } catch {
            print("System audio start error: \(error)")
        }
    }

    private func stopSystemAudio() async {
        try? await scStream?.stopCapture()
        scStream = nil
        scOutput = nil
        remoteWriter = nil  // flushes and closes
        systemActive = false
    }

    // MARK: – Stop all

    func stopAll() {
        if micActive { stopMic() }
        if systemActive { Task { await stopSystemAudio() } }
    }

    // MARK: – Helpers

    private func tempWAV(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tm_\(label)_\(Int(Date().timeIntervalSince1970)).wav")
    }
}

// MARK: – SCStreamOutput

class SCAudioOutput: NSObject, SCStreamOutput {
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = sampleBuffer.asPCMBuffer() else { return }
        onBuffer(buffer)
    }
}

// CMSampleBuffer → AVAudioPCMBuffer (shared extension)
extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard
            let desc = CMSampleBufferGetFormatDescription(self),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: asbd.pointee.mSampleRate,
                                channels: asbd.pointee.mChannelsPerFrame)
               ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let count = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count),
              let floats = buf.floatChannelData,
              let block = CMSampleBufferGetDataBuffer(self) else { return nil }

        buf.frameLength = count
        var ptr: UnsafeMutablePointer<CChar>?
        var len = 0
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        if let raw = ptr {
            raw.withMemoryRebound(to: Float.self, capacity: Int(count)) {
                floats[0].initialize(from: $0, count: Int(count))
            }
        }
        return buf
    }
}
