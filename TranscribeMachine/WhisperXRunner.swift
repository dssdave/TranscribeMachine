import Foundation
import Security
import SwiftUI

// A diarized segment returned from WhisperX
struct DiarizedSegment: Codable, Identifiable {
    let id = UUID()
    let speaker: String   // "SPEAKER_00", "SPEAKER_01", …
    let source: String    // "local" | "remote"
    let start: Double
    let end: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case speaker, source, start, end, text
    }
}

@MainActor
class WhisperXRunner: ObservableObject {

    // MARK: – State

    enum SetupState: Equatable {
        case unknown
        case notInstalled
        case installing
        case ready
        case failed(String)
    }

    @Published var setupState: SetupState = .unknown
    @Published var installLog: String = ""
    @Published var isRunning = false
    @Published var progress: String = ""

    // MARK: – Keychain key
    private let tokenKey = "com.dssdave.TranscribeMachine.hfToken"

    // MARK: – Public API

    var hfToken: String? {
        get { keychainRead(tokenKey) }
        set {
            if let v = newValue { keychainWrite(tokenKey, value: v) }
            else { keychainDelete(tokenKey) }
        }
    }

    var isReady: Bool { setupState == .ready }

    func checkSetup() {
        Task {
            let installed = await whisperxInstalled()
            setupState = installed ? .ready : .notInstalled
        }
    }

    /// Called on app launch — installs silently if not already present.
    func installIfNeeded() {
        Task {
            let installed = await whisperxInstalled()
            if installed {
                setupState = .ready
            } else {
                await install()
            }
        }
    }

    // MARK: – Install (silent background)

    func install() async {
        setupState = .installing
        installLog = ""

        guard let script = bundledResource("setup_whisperx", ext: "sh") else {
            setupState = .failed("setup_whisperx.sh not found in bundle")
            return
        }

        let result = await runProcess("/bin/bash", args: [script.path], liveLog: true)
        setupState = result.exitCode == 0 ? .ready : .failed(result.stderr.isEmpty ? "Install failed" : result.stderr)
    }

    // MARK: – Diarize

    /// Process one audio file. Returns diarized segments sorted by start time.
    func diarize(audioURL: URL, source: String) async -> [DiarizedSegment] {
        guard let script = bundledResource("diarize", ext: "py") else { return [] }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarize_\(source)_\(UUID().uuidString).json")

        isRunning = true
        progress = "Diarizing \(source) audio…"

        let result = await runProcess("python3", args: [
            script.path,
            "--audio", audioURL.path,
            "--source", source,
            "--model", "base.en",
            "--out", outURL.path
        ], liveLog: false)

        isRunning = false
        progress = ""

        if result.exitCode != 0 {
            print("[WhisperXRunner] diarize error: \(result.stderr)")
            return []
        }

        return parseSegments(from: outURL)
    }

    /// Diarize both streams and merge, sorted by start time.
    func diarizeBoth(localAudio: URL?, remoteAudio: URL?) async -> [DiarizedSegment] {
        isRunning = true
        var all: [DiarizedSegment] = []

        // Run both in parallel
        async let localSegs: [DiarizedSegment] = {
            guard let url = localAudio else { return [] }
            await MainActor.run { self.progress = "Analyzing in-room speakers…" }
            return await self.diarize(audioURL: url, source: "local")
        }()

        async let remoteSegs: [DiarizedSegment] = {
            guard let url = remoteAudio else { return [] }
            await MainActor.run { self.progress = "Analyzing remote speakers…" }
            return await self.diarize(audioURL: url, source: "remote")
        }()

        let (local, remote) = await (localSegs, remoteSegs)
        all.append(contentsOf: local)
        all.append(contentsOf: remote)

        isRunning = false
        progress = ""

        return all.sorted { $0.start < $1.start }
    }

    // MARK: – Helpers

    private func whisperxInstalled() async -> Bool {
        let result = await runProcess("python3", args: ["-c", "import whisperx"], liveLog: false)
        return result.exitCode == 0
    }

    private func bundledResource(_ name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func parseSegments(from url: URL) -> [DiarizedSegment] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        // Check for error object
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String {
            print("[WhisperXRunner] Script error: \(err)")
            return []
        }

        return (try? JSONDecoder().decode([DiarizedSegment].self, from: data)) ?? []
    }

    // MARK: – Process runner

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(_ cmd: String, args: [String], liveLog: Bool) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [cmd] + args

                // PATH includes common Python locations
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                if liveLog {
                    outPipe.fileHandleForReading.readabilityHandler = { fh in
                        let line = String(data: fh.availableData, encoding: .utf8) ?? ""
                        if !line.isEmpty {
                            Task { @MainActor in self.installLog += line }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: ProcessResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                continuation.resume(returning: ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }

    // MARK: – Keychain

    private func keychainWrite(_ key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainRead(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
