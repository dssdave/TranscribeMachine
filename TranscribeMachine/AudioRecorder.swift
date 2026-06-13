import AVFoundation
import ScreenCaptureKit
import SwiftUI

@MainActor
class AudioRecorder: ObservableObject {
    @Published var micActive = false
    @Published var systemActive = false

    var isRecording: Bool { micActive || systemActive }

    // Injected so recorder can route directly to engine
    weak var engine: TranscriptionEngine?

    private var audioEngine = AVAudioEngine()
    private var scStream: SCStream?
    private var scOutput: SystemAudioOutput?

    // MARK: – Mic

    func toggleMic() {
        micActive ? stopMic() : startMic()
    }

    private func startMic() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            Task { @MainActor in
                self?.engine?.feedMic(buffer: buffer)
            }
        }

        do {
            try audioEngine.start()
            micActive = true
        } catch {
            print("Mic start error: \(error)")
        }
    }

    private func stopMic() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        micActive = false
    }

    // MARK: – System Audio

    func toggleSystemAudio() {
        if systemActive {
            Task { await stopSystemAudio() }
        } else {
            Task { await startSystemAudio() }
        }
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

            let output = SystemAudioOutput { [weak self] buffer in
                Task { @MainActor in
                    self?.engine?.feedSystem(buffer: buffer)
                }
            }
            self.scOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()

            self.scStream = stream
            self.systemActive = true
        } catch {
            print("System audio error: \(error)")
        }
    }

    private func stopSystemAudio() async {
        try? await scStream?.stopCapture()
        scStream = nil
        scOutput = nil
        systemActive = false
    }
}

// MARK: – SCStreamOutput

class SystemAudioOutput: NSObject, SCStreamOutput {
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = sampleBuffer.asPCMBuffer() else { return }
        onBuffer(buffer)
    }
}

// MARK: – CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard
            let desc = CMSampleBufferGetFormatDescription(self),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }

        let format = AVAudioFormat(standardFormatWithSampleRate: asbd.pointee.mSampleRate,
                                   channels: asbd.pointee.mChannelsPerFrame)
                  ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(self),
            let floatData = buffer.floatChannelData
        else { return nil }

        var dataPointer: UnsafeMutablePointer<CChar>?
        var length = 0
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)

        if let raw = dataPointer {
            raw.withMemoryRebound(to: Float.self, capacity: Int(frameCount)) { src in
                floatData[0].initialize(from: src, count: Int(frameCount))
            }
        }

        return buffer
    }
}
