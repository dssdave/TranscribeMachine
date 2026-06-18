import Foundation
import SwiftUI

// The one model we've chosen. Users never see this name.
private let kModel = "llama3.2:3b"

// Default prompts — also used as fallback when user hasn't customised
extension OllamaService {
    static let defaultPromptRecap = """
    List every key point from this transcript. Use one short line per point, starting with a dash (-).

    Rules:
    - Only include things that were actually said. Do not add, infer, or interpret.
    - Include specific numbers, examples, and comparisons exactly as stated.
    - Do not write an intro sentence or conclusion — just the list.
    - If a point was repeated, list it once.
    """

    static let defaultPromptDecisions = """
    Read the transcript and list only decisions that were explicitly agreed on.

    A decision requires clear agreement language: "we decided", "we agreed", "we will", "let's go with".
    Opinions, suggestions, and statements of fact are NOT decisions.
    Do NOT invent or interpret — only include something if the exact words in the transcript make it clear.
    If nothing qualifies, output only: None
    """

    static let defaultPromptNextSteps = """
    Read the transcript and list only real personal commitments — tasks someone promised to do.

    Rules:
    - Only count "I will" or "I'll" when it is a genuine personal promise to complete a task.
    - Do NOT count: hypothetical scenarios, the speaker describing their presentation, general advice, or past actions.
    - Do NOT infer, extrapolate, or add deadlines not spoken.
    - If there are no genuine commitments, output only: None
    """

    static let defaultPromptEmail = """
    Write a professional follow-up email based on this transcript.
    The sender is "You" in the transcript. Use [Your Name] for the sign-off.

    Include: subject line, brief recap of what was discussed, key decisions if any were made.
    Only include action items if someone explicitly said they will do something.
    Do not add information that is not in the transcript.
    """
}

struct AIOptions {
    var includeActionItems: Bool = true
    var includeOwners: Bool = true
    var includeDeadlines: Bool = true
}

@MainActor
class OllamaService: ObservableObject {

    enum AIState: Equatable {
        case starting       // finding / launching the server
        case downloading    // downloading binary or model weights
        case ready
        case unavailable    // could not set up
    }

    @Published var state: AIState = .starting
    @Published var downloadProgress: String = ""   // e.g. "Downloading AI model… 34%"

    private let baseURL = "http://localhost:11434"

    init() {
        Task { await setup() }
    }

    // MARK: – Setup pipeline

    func setup() async {
        state = .starting

        // 1. If server already up, just ensure the model is present, then check for updates
        if await serverIsRunning() {
            await ensureModel()
            Task { await silentUpdateCheck() }
            return
        }

        // 2. Find or download the ollama binary
        let exec: String
        if let found = ollamaExec {
            exec = found
            Task { await silentUpdateCheck() }
        } else {
            // First time — download the binary
            guard let downloaded = await downloadOllamaBinary() else {
                state = .unavailable
                return
            }
            exec = downloaded
        }

        // 3. Start the server and ensure the model
        launchServer(exec)
        if await waitForServer() {
            await ensureModel()
        } else {
            state = .unavailable
        }
    }

    private func ensureModel() async {
        if await modelPresent() {
            state = .ready
        } else {
            await pullModel()
        }
    }

    // MARK: – Binary download & update

    // Where we store the downloaded binary (not the user's own installation)
    private var managedBinaryPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("TranscribeMachine/bin/ollama").path
    }

    private func downloadOllamaBinary() async -> String? {
        downloadProgress = "Setting up AI for the first time…"
        state = .downloading

        // Fetch latest release metadata from GitHub
        guard let releaseURL = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest"),
              let (releaseData, _) = try? await URLSession.shared.data(from: releaseURL),
              let release = try? JSONSerialization.jsonObject(with: releaseData) as? [String: Any],
              let tagName = release["tag_name"] as? String,
              let assets = release["assets"] as? [[String: Any]]
        else {
            downloadProgress = ""
            return nil
        }

        // Find the macOS CLI binary (ollama-darwin, not the .app zip)
        guard let asset = assets.first(where: {
                  let name = ($0["name"] as? String) ?? ""
                  return name == "ollama-darwin"
              }),
              let downloadURLString = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString)
        else {
            downloadProgress = ""
            return nil
        }

        // Download with progress
        let destPath = managedBinaryPath
        let destURL  = URL(fileURLWithPath: destPath)
        try? FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)

        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: downloadURL)
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tmpURL, to: destURL)
            // Make executable and clear macOS quarantine
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
            removeQuarantine(destPath)
            UserDefaults.standard.set(tagName, forKey: "ollamaBinaryVersion")
            downloadProgress = ""
            return destPath
        } catch {
            downloadProgress = ""
            return nil
        }
    }

    // Silent weekly update check — downloads newer binary to managed path if available
    private func silentUpdateCheck() async {
        let lastCheck = UserDefaults.standard.double(forKey: "ollamaUpdateCheck")
        let weekSeconds: Double = 7 * 24 * 3600
        guard Date().timeIntervalSince1970 - lastCheck > weekSeconds else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ollamaUpdateCheck")

        guard let releaseURL = URL(string: "https://api.github.com/repos/ollama/ollama/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: releaseURL),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latestTag = release["tag_name"] as? String
        else { return }

        let installedTag = UserDefaults.standard.string(forKey: "ollamaBinaryVersion") ?? ""
        guard latestTag != installedTag else { return }

        // Newer version available — download it in the background (used on next launch)
        guard let assets = release["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "ollama-darwin" }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else { return }

        let destURL = URL(fileURLWithPath: managedBinaryPath)
        guard let (tmpURL, _) = try? await URLSession.shared.download(from: url) else { return }
        try? FileManager.default.removeItem(at: destURL)
        guard (try? FileManager.default.moveItem(at: tmpURL, to: destURL)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedBinaryPath)
        removeQuarantine(managedBinaryPath)
        UserDefaults.standard.set(latestTag, forKey: "ollamaBinaryVersion")
    }

    private func removeQuarantine(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: – Public entry point

    func run(action: AIAction, transcript: String, options: AIOptions,
             customInstructions: String = "", audioSource: String = "") async -> AIResult {
        guard state == .ready else {
            return AIResult(main: "AI is not ready yet. Please wait a moment.", actionItems: [])
        }
        let ctx = contextBlock(audioSource)
        switch action {
        case .recap:     return await generateRecap(transcript: transcript, options: options, custom: customInstructions, context: ctx)
        case .decisions: return await generateDecisions(transcript: transcript, custom: customInstructions, context: ctx)
        case .nextSteps: return await generateNextSteps(transcript: transcript, options: options, custom: customInstructions, context: ctx)
        case .email:     return await generateEmail(transcript: transcript, options: options, custom: customInstructions, context: ctx)
        }
    }

    // MARK: – Recap

    private func generateRecap(transcript: String, options: AIOptions, custom: String, context: String) async -> AIResult {
        let instruction = UserDefaults.standard.string(forKey: "promptRecap") ?? Self.defaultPromptRecap
        let cleanedTranscript = stripSpeakerLabels(transcript)
        let prompt = """
        \(context)\(instruction)
        \(customBlock(custom))
        Transcript:
        \(cleanedTranscript)

        IMPORTANT: Plain text only. No asterisks, no pound signs. Each point on its own line starting with -.
        """
        let raw = await generate(prompt: prompt)
        return AIResult(main: stripMarkdown(raw), actionItems: [])
    }

    private func stripSpeakerLabels(_ transcript: String) -> String {
        transcript.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"^\[.*?\]:\s*"#, with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    // MARK: – Decisions

    private func generateDecisions(transcript: String, custom: String, context: String) async -> AIResult {
        let instruction = UserDefaults.standard.string(forKey: "promptDecisions") ?? Self.defaultPromptDecisions
        let prompt = """
        \(context)\(instruction)
        \(customBlock(custom))
        Transcript:
        \(transcript)
        \(formatRule)
        """
        let raw = await generate(prompt: prompt)
        return AIResult(main: stripMarkdown(raw), actionItems: [])
    }

    // MARK: – Next Steps

    private func generateNextSteps(transcript: String, options: AIOptions, custom: String, context: String) async -> AIResult {
        let instruction = UserDefaults.standard.string(forKey: "promptNextSteps") ?? Self.defaultPromptNextSteps
        var prompt = """
        \(context)\(instruction)
        \(customBlock(custom))
        Transcript:
        \(transcript)
        """
        prompt += "\n\n" + actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        prompt += formatRule
        let raw = await generate(prompt: prompt)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: parseActionItems(from: clean))
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, custom: String, context: String) async -> AIResult {
        let instruction = UserDefaults.standard.string(forKey: "promptEmail") ?? Self.defaultPromptEmail
        var prompt = """
        \(context)\(instruction)
        \(customBlock(custom))
        Transcript:
        \(transcript)
        """
        if options.includeActionItems {
            prompt += "\n\n" + actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines,
                                                     intro: "After the email, list any explicit commitments:")
        }
        prompt += formatRule
        let raw = await generate(prompt: prompt)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Prompt helpers

    private func actionItemInstruction(owners: Bool, deadlines: Bool, intro: String = "For each explicit commitment someone made, write one line:") -> String {
        var s = intro + "\n"
        s += "ACTION: the task"
        if owners  { s += " — Owner: who said it" }
        if deadlines { s += " — Due: deadline if stated, else omit" }
        s += "\nDo NOT output any ACTION lines if no one explicitly committed. \"We should\" is not a commitment."
        return s
    }

    private func contextBlock(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        switch source {
        case "Zoom call", "Microsoft Teams call", "FaceTime call", "Webex call":
            return "Context: This is a \(source) — may have two or more live participants.\n"
        case "meeting":
            return "Context: This is a meeting or conversation with two or more live participants.\n"
        case "browser audio", "Talk / Media":
            return "Context: This is a one-way presentation, talk, podcast, comedy show, or recorded media. One person is speaking to an audience — there are no live participants, no agreements, and no one assigning tasks. Do NOT output any action items. Output \"None\" for any decisions section. Only summarize what the speaker discussed.\n"
        case "Discord":
            return "Context: Audio from Discord.\n"
        case "Loom recording":
            return "Context: Loom recording — single presenter to camera, not a live meeting.\n"
        default:
            return ""
        }
    }

    private func customBlock(_ instructions: String) -> String {
        let s = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        return "\nAdditional instructions: \(s)\n"
    }

    private let formatRule = "\n\nIMPORTANT: Plain text only. No markdown, no asterisks, no pound signs, no underscores. Use plain line breaks."

    private func stripMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            if let r = l.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { l = String(l[r.upperBound...]) }
            return l
        }
        var result = lines.joined(separator: "\n")
        for token in ["**", "__", "*", "_"] { result = result.replacingOccurrences(of: token, with: "") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Ollama HTTP

    private func generate(prompt: String) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return "Error: bad URL" }
        let body: [String: Any] = [
            "model": kModel, "prompt": prompt, "stream": false,
            "options": ["temperature": 0.1, "num_predict": 1200]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "Error: encoding" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        do {
            let (resp, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
               let text = json["response"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "Error: could not parse response"
        } catch { return "Error: \(error.localizedDescription)" }
    }

    // MARK: – Server management

    private var ollamaExec: String? {
        let home = NSHomeDirectory()
        let candidates = [
            managedBinaryPath,                                   // our downloaded/updated copy (preferred)
            "/usr/local/bin/ollama",                             // user's own installation
            "/opt/homebrew/bin/ollama",
            "\(home)/.ollama/bin/ollama"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func serverIsRunning() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        return (try? await URLSession.shared.data(from: url)) != nil
    }

    private func waitForServer(attempts: Int = 20, delay: UInt64 = 500_000_000) async -> Bool {
        for _ in 0..<attempts {
            if await serverIsRunning() { return true }
            try? await Task.sleep(nanoseconds: delay)
        }
        return false
    }

    private func launchServer(_ exec: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
    }

    private func modelPresent() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String)?.hasPrefix("llama3.2:3b") == true }
    }

    private func pullModel() async {
        state = .downloading
        downloadProgress = "Downloading AI model for the first time… this takes a few minutes"

        guard let url = URL(string: "\(baseURL)/api/pull") else { state = .unavailable; return }
        let body = ["name": kModel, "stream": true] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { state = .unavailable; return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        do {
            let (stream, _) = try await URLSession.shared.bytes(for: req)
            for try await line in stream.lines {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                if let total = json["total"] as? Double,
                   let completed = json["completed"] as? Double,
                   total > 0 {
                    let pct = Int((completed / total) * 100)
                    downloadProgress = "Downloading AI model… \(pct)%"
                }
                if (json["status"] as? String) == "success" { break }
            }
            state = .ready
            downloadProgress = ""
        } catch {
            state = .unavailable
            downloadProgress = ""
        }
    }

    // MARK: – Parse action items

    private func parseActionItems(from text: String) -> [ActionItem] {
        let rawLines = text.components(separatedBy: "\n")
        var merged: [String] = []
        var i = 0
        while i < rawLines.count {
            var line = rawLines[i].trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                line = String(line[r.upperBound...])
            }
            if line.uppercased().hasPrefix("ACTION:") {
                var j = i + 1
                while j < rawLines.count {
                    let next = rawLines[j].trimmingCharacters(in: .whitespaces)
                    let lower = next.lowercased()
                    if lower.hasPrefix("- owner:") || lower.hasPrefix("owner:") ||
                       lower.hasPrefix("- due:")   || lower.hasPrefix("due:") {
                        line += " — " + next.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                        j += 1
                    } else { break }
                }
                i = j
                merged.append(line)
            } else { i += 1 }
        }

        var items: [ActionItem] = []
        for line in merged {
            let content = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            var task = content, owner = "Unknown", due = "Not specified"

            for ownerKey in ["— Owner:", "- Owner:", "| Owner:", "Owner:"] {
                if let range = content.range(of: ownerKey, options: .caseInsensitive) {
                    task = String(content[content.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let after = String(content[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    for dueKey in ["— Due:", "- Due:", "| Due:", "Due:"] {
                        if let dueRange = after.range(of: dueKey, options: .caseInsensitive) {
                            owner = String(after[after.startIndex..<dueRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                            let dueStr = String(after[dueRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                            due = ["none", "n/a", "not specified", "tbd", ""].contains(dueStr.lowercased()) ? "Not specified" : dueStr
                            break
                        }
                    }
                    if owner == "Unknown" { owner = after }
                    break
                }
            }

            for (bad, good) in [("[Local]","you"),("[Remote]","caller"),("[You]","you"),("[Caller]","caller")] {
                task  = task.replacingOccurrences(of: bad, with: good)
                owner = owner.replacingOccurrences(of: bad, with: good)
            }
            task  = task.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            owner = owner.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))

            guard !task.isEmpty, task.count < 400 else { continue }
            items.append(ActionItem(task: task, owner: owner, due: due))
        }
        return items
    }
}

// MARK: – Models

enum AIAction: String, CaseIterable {
    case recap     = "Recap"
    case decisions = "Decisions"
    case nextSteps = "Next Steps"
    case email     = "Email"
}

struct AIResult {
    let main: String
    let actionItems: [ActionItem]
}

struct ActionItem: Identifiable {
    let id = UUID()
    let task: String
    let owner: String
    let due: String
}
