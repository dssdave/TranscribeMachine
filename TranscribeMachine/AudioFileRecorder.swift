import AVFoundation
import ScreenCaptureKit
import SwiftUI

/// Records mic and system audio to WAV files on disk simultaneously with live feeding.
/// After stopRecording(), localFileURL and remoteFileURL are ready for WhisperX.
@MainActor
class AudioFileRecorder: ObservableObject {

    @Published var micActive = false
    @Published var systemActive = false
    @Published var detectedAudioSource: String = ""
    @Published var micPermissionDenied = false
    @Published var screenRecordingPermissionDenied = false
    // Set when a source has stopped delivering audio and auto-recovery has given up
    // repeatedly — surface this in the UI so the user knows to restart manually.
    @Published var systemAudioUnstable = false
    @Published var micAudioUnstable = false

    var isRecording: Bool { micActive || systemActive }

    private(set) var localFileURL: URL?
    private(set) var remoteFileURL: URL?

    weak var transcriptionEngine: TranscriptionEngine?

    // Available mic devices
    @Published var availableMics: [AVCaptureDevice] = []
    @Published var selectedMicID: String = "" {
        didSet { UserDefaults.standard.set(selectedMicID, forKey: "selectedMicID") }
    }

    // AVCaptureSession-based mic (replaces AVAudioEngine which crashes on macOS 15+)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var captureDelegate: FileMicDelegate?
    private let captureQueue = DispatchQueue(label: "com.dssdave.filemic", qos: .userInitiated)

    private var localWriter: AVAudioFile?

    // Tracks whether the *user* wants mic recording, independent of whether the
    // session is currently up — lets us auto-restart after a runtime error without
    // that restart racing a user-initiated stop.
    private var userWantsMic = false
    private var micRestartAttempts = 0
    private var micRuntimeErrorObserver: NSObjectProtocol?

    // ScreenCaptureKit
    private var scStream: SCStream?
    private var scOutput: SCAudioOutput?
    private var remoteWriter: AVAudioFile?
    private var scDelegate: SCStreamHealthDelegate?

    private var userWantsSystemAudio = false
    private var systemRestartAttempts = 0
    private var lastSystemBufferTime: Date?
    private var systemWatchdogTimer: Timer?
    private static let maxRestartAttempts = 5
    private static let stallTimeout: TimeInterval = 20

    // MARK: – Device enumeration

    func refreshMicList() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        availableMics = discovery.devices
        let saved = UserDefaults.standard.string(forKey: "selectedMicID") ?? ""
        if availableMics.contains(where: { $0.uniqueID == saved }) {
            selectedMicID = saved
        } else if !availableMics.contains(where: { $0.uniqueID == selectedMicID }) {
            selectedMicID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
        }
    }

    // MARK: – Mic

    func toggleMic() {
        if micActive {
            userWantsMic = false
            stopMic()
        } else {
            userWantsMic = true
            micRestartAttempts = 0
            micAudioUnstable = false
            startMic()
        }
    }

    private func startMic() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted { self.buildMicSession() }
                else { self.micPermissionDenied = true }
            }
        }
    }

    // Called after a runtime error tears the session down unexpectedly. Only
    // restarts if the user hadn't already asked us to stop, and backs off after
    // repeated failures instead of retrying forever.
    private func restartMicIfNeeded() {
        guard userWantsMic else { return }
        guard micRestartAttempts < Self.maxRestartAttempts else {
            micAudioUnstable = true
            return
        }
        micRestartAttempts += 1
        let delay = Double(micRestartAttempts) * 2.0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.userWantsMic else { return }
            self.buildMicSession()
        }
    }

    private func buildMicSession() {
        let session = AVCaptureSession()

        let device = availableMics.first(where: { $0.uniqueID == selectedMicID })
                  ?? AVCaptureDevice.default(for: .audio)
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("Could not set up mic input")
            return
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Request a known, simple format so asPCMBuffer() can use a fixed memcpy path.
        output.audioSettings = [
            AVFormatIDKey:                kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:       32,
            AVLinearPCMIsFloatKey:        true,
            AVLinearPCMIsBigEndianKey:    false,
            "AVLinearPCMIsNonInterleaved": true,
            AVSampleRateKey:              44100.0,
            AVNumberOfChannelsKey:        1
        ]
        let fileURL = tempWAV("local")
        localFileURL = fileURL

        let delegate = FileMicDelegate(fileURL: fileURL) { [weak self] buffer in
            let boxed = UncheckedSendableBox(buffer)
            Task { @MainActor in self?.transcriptionEngine?.feedMic(buffer: boxed.value) }
        }
        output.setSampleBufferDelegate(delegate, queue: captureQueue)

        guard session.canAddOutput(output) else {
            print("Could not add audio output")
            return
        }
        session.addOutput(output)

        // startRunning blocks — run it on background queue, then store refs on MainActor
        let boxedSession  = UncheckedSendableBox(session)
        let boxedOutput   = UncheckedSendableBox(output)
        let boxedDelegate = UncheckedSendableBox(delegate)
        captureQueue.async { [weak self] in
            boxedSession.value.startRunning()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureSession  = boxedSession.value
                self.audioOutput     = boxedOutput.value
                self.captureDelegate = boxedDelegate.value
                self.micActive       = true
                self.micRestartAttempts = 0
                self.micAudioUnstable = false
                self.observeMicRuntimeErrors(for: boxedSession.value)
            }
        }
    }

    // AVCaptureSession silently tears itself down on things like device
    // disconnects or media services resets. Without this we'd sit "active" but
    // dead until the user notices and restarts manually.
    private func observeMicRuntimeErrors(for session: AVCaptureSession) {
        if let existing = micRuntimeErrorObserver { NotificationCenter.default.removeObserver(existing) }
        micRuntimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: .main
        ) { [weak self] note in
            print("Mic session runtime error: \(note.userInfo ?? [:])")
            Task { @MainActor in
                guard let self else { return }
                self.stopMic()
                self.restartMicIfNeeded()
            }
        }
    }

    private func stopMic() {
        if let observer = micRuntimeErrorObserver {
            NotificationCenter.default.removeObserver(observer)
            micRuntimeErrorObserver = nil
        }
        let boxed = UncheckedSendableBox(captureSession)
        captureQueue.async { boxed.value?.stopRunning() }
        captureSession  = nil
        audioOutput     = nil
        captureDelegate = nil
        micActive       = false
    }

    // MARK: – System Audio

    func toggleSystemAudio() {
        if systemActive {
            userWantsSystemAudio = false
            Task { await stopSystemAudio() }
        } else {
            userWantsSystemAudio = true
            systemRestartAttempts = 0
            systemAudioUnstable = false
            Task { await startSystemAudio() }
        }
    }

    private func startSystemAudio() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }
            detectedAudioSource = detectSource(from: content.applications)

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
                Task { @MainActor in self?.lastSystemBufferTime = Date() }
                let boxed = UncheckedSendableBox(buffer)
                Task { @MainActor in self?.transcriptionEngine?.feedSystem(buffer: boxed.value) }
            }
            self.scOutput = output

            let delegate = SCStreamHealthDelegate { [weak self] error in
                print("System audio stream stopped: \(error)")
                Task { @MainActor in
                    guard let self else { return }
                    self.teardownSystemAudio()
                    self.restartSystemAudioIfNeeded()
                }
            }
            self.scDelegate = delegate

            let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()

            self.scStream = stream
            self.systemActive = true
            self.systemRestartAttempts = 0
            self.systemAudioUnstable = false
            self.startSystemWatchdog()
        } catch {
            let msg = error.localizedDescription.lowercased()
            if msg.contains("permission") || msg.contains("denied") || msg.contains("not authorized") {
                screenRecordingPermissionDenied = true
            } else {
                screenRecordingPermissionDenied = true  // safe default — most failures are permission-related
            }
            print("System audio start error: \(error)")
        }
    }

    private func stopSystemAudio() async {
        systemWatchdogTimer?.invalidate()
        systemWatchdogTimer = nil
        try? await scStream?.stopCapture()
        teardownSystemAudio()
    }

    // Tears down local state without touching userWantsSystemAudio — used both
    // for a user-initiated stop and for cleanup before an auto-restart.
    private func teardownSystemAudio() {
        scStream = nil
        scOutput = nil
        scDelegate = nil
        remoteWriter = nil
        systemActive = false
    }

    private func restartSystemAudioIfNeeded() {
        guard userWantsSystemAudio else { return }
        guard systemRestartAttempts < Self.maxRestartAttempts else {
            systemAudioUnstable = true
            return
        }
        systemRestartAttempts += 1
        let delay = Double(systemRestartAttempts) * 2.0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.userWantsSystemAudio else { return }
            await self.startSystemAudio()
        }
    }

    // SCStream doesn't always call the delegate when it silently stops delivering
    // buffers (observed during long-running captures) — so also watch for a gap
    // in incoming audio and force a restart if one goes quiet too long.
    private func startSystemWatchdog() {
        systemWatchdogTimer?.invalidate()
        lastSystemBufferTime = Date()
        systemWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSystemStall() }
        }
    }

    private func checkSystemStall() {
        guard systemActive, userWantsSystemAudio,
              let last = lastSystemBufferTime,
              Date().timeIntervalSince(last) > Self.stallTimeout
        else { return }
        print("System audio stalled — no buffers in \(Self.stallTimeout)s, restarting")
        systemWatchdogTimer?.invalidate()
        systemWatchdogTimer = nil
        Task {
            try? await scStream?.stopCapture()
            teardownSystemAudio()
            restartSystemAudioIfNeeded()
        }
    }

    private func detectSource(from apps: [SCRunningApplication]) -> String {
        let ids = Set(apps.compactMap { $0.bundleIdentifier })
        if ids.contains("us.zoom.xos")                  { return "Zoom call" }
        if ids.contains("com.microsoft.teams")  ||
           ids.contains("com.microsoft.teams2")         { return "Microsoft Teams call" }
        if ids.contains("com.apple.FaceTime")           { return "FaceTime call" }
        if ids.contains("com.cisco.webexmeetings")      { return "Webex call" }
        if ids.contains("com.hnc.Discord")              { return "Discord" }
        if ids.contains("com.loom.desktop")             { return "Loom recording" }
        let browsers: Set<String> = [
            "com.google.Chrome", "org.mozilla.firefox",
            "com.apple.Safari", "com.microsoft.edgemac"
        ]
        if !ids.isDisjoint(with: browsers)              { return "browser audio" }
        return "system audio"
    }

    // MARK: – Stop all

    func stopAll() {
        userWantsMic = false
        userWantsSystemAudio = false
        if micActive { stopMic() }
        if systemActive { Task { await stopSystemAudio() } }
    }

    // MARK: – Helpers

    private func tempWAV(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tm_\(label)_\(Int(Date().timeIntervalSince1970)).wav")
    }
}

// MARK: – Sendable box

final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: – Mic delegate (writes to file + forwards buffer)

class FileMicDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onBuffer: (AVAudioPCMBuffer) -> Void
    private var writer: AVAudioFile?
    private var pendingURL: URL?

    init(fileURL: URL, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        self.pendingURL = fileURL
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = sampleBuffer.asPCMBuffer() else { return }
        if writer == nil, let url = pendingURL {
            writer = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
            pendingURL = nil
        }
        try? writer?.write(from: buffer)
        onBuffer(buffer)
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

// MARK: – SCStream health (detects the stream dying mid-capture)

class SCStreamHealthDelegate: NSObject, SCStreamDelegate {
    private let onStop: (Error) -> Void
    init(onStop: @escaping (Error) -> Void) { self.onStop = onStop }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}

// MARK: – CMSampleBuffer → AVAudioPCMBuffer (float32, mono, 16kHz)
// audioSettings forces float32 non-interleaved mono; sample rate is read from ASBD
// (not hardcoded) in case the hardware ignores AVSampleRateKey).

extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return nil }
        let sampleRate = asbd.pointee.mSampleRate

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(self)
        else { return nil }

        var dataLen = 0
        var rawPtr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &dataLen, dataPointerOut: &rawPtr) == noErr,
              let src = rawPtr
        else { return nil }

        // audioSettings guarantees float32 non-interleaved mono — floatChannelData is safe.
        let srcFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount),
              let floatDst  = srcBuffer.floatChannelData
        else { return nil }
        srcBuffer.frameLength = frameCount
        memcpy(floatDst[0], src, min(dataLen, Int(frameCount) * 4))

        // Resample to 16 kHz for WhisperKit.
        let dstFormat     = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let dstFrameCount = AVAudioFrameCount(Double(frameCount) * 16000.0 / sampleRate + 1)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrameCount),
              let converter  = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            consumed = true
            return srcBuffer
        }
        guard error == nil, dstBuffer.frameLength > 0 else { return nil }
        return dstBuffer
    }
}
