import Foundation
import SwiftUI

struct AIOptions {
    var includeActionItems: Bool = true
    var includeOwners: Bool = true
    var includeDeadlines: Bool = true
}

@MainActor
class OllamaService: ObservableObject {
    @Published var isAvailable = false
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = ""

    private let baseURL = "http://localhost:11434"

    init() {
        Task { await checkAvailability() }
    }

    func checkAvailability() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            isAvailable = (response as? HTTPURLResponse)?.statusCode == 200
            if isAvailable,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                availableModels = models.compactMap { $0["name"] as? String }
                let saved = UserDefaults.standard.string(forKey: "ollamaModel") ?? ""
                if !saved.isEmpty && availableModels.contains(saved) {
                    selectedModel = saved
                } else if selectedModel.isEmpty || !availableModels.contains(selectedModel) {
                    selectedModel = autoSelectModel()
                }
            }
        } catch {
            isAvailable = false
        }
    }

    // MARK: – Public entry point

    func run(action: AIAction, transcript: String, options: AIOptions, customInstructions: String = "", audioSource: String = "") async -> AIResult {
        await checkAvailability()
        guard isAvailable else {
            return AIResult(
                main: "Ollama is not running.\n\nInstall at ollama.com, then:\n  ollama pull llama3.2",
                actionItems: []
            )
        }
        let model = await resolveModel()
        let ctx = contextBlock(audioSource)
        switch action {
        case .recap:     return await generateRecap(transcript: transcript, options: options, custom: customInstructions, context: ctx, model: model)
        case .decisions: return await generateDecisions(transcript: transcript, custom: customInstructions, context: ctx, model: model)
        case .nextSteps: return await generateNextSteps(transcript: transcript, options: options, custom: customInstructions, context: ctx, model: model)
        case .email:     return await generateEmail(transcript: transcript, options: options, custom: customInstructions, context: ctx, model: model)
        }
    }

    // MARK: – Recap

    private func generateRecap(transcript: String, options: AIOptions, custom: String, context: String, model: String) async -> AIResult {
        var prompt = """
        \(context)Summarize this transcript in 3 to 5 sentences. Only include what was actually said — do not add, infer, or guess.
        \(customBlock(custom))
        Transcript:
        \(transcript)
        """

        if options.includeActionItems {
            prompt += "\n\n" + actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        }

        prompt += formatRule

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Key Decisions

    private func generateDecisions(transcript: String, custom: String, context: String, model: String) async -> AIResult {
        let prompt = """
        \(context)Read the transcript and list only decisions that were explicitly agreed on.

        A decision requires clear agreement language: "we decided", "we agreed", "we will", "let's go with".
        Opinions, suggestions, and statements of fact are NOT decisions.
        Do NOT invent or interpret — only include something if the exact words in the transcript make it clear.
        If nothing qualifies, output only: None
        \(customBlock(custom))\(formatRule)

        Transcript:
        \(transcript)
        """

        let raw = await generate(prompt: prompt, model: model)
        return AIResult(main: stripMarkdown(raw), actionItems: [])
    }

    // MARK: – Next Steps

    private func generateNextSteps(transcript: String, options: AIOptions, custom: String, context: String, model: String) async -> AIResult {
        var prompt = """
        \(context)Read the transcript and list only tasks someone explicitly said they will do.

        Strict rules:
        - The transcript must contain words like "I will", "I'll", "I'm going to" followed by a specific task
        - Do NOT infer tasks from the topic. Do NOT add deadlines that were not spoken.
        - If no one said they will do something specific, output only: None
        \(customBlock(custom))
        Transcript:
        \(transcript)
        """

        prompt += "\n\n" + actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        prompt += formatRule

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: parseActionItems(from: clean))
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, custom: String, context: String, model: String) async -> AIResult {
        var prompt = """
        \(context)Write a professional follow-up email based on this transcript.
        The sender is "You" in the transcript. Use [Your Name] for the sign-off.

        Include: subject line, brief recap of what was discussed, key decisions if any were made.
        Only include action items if someone explicitly said they will do something.
        Do not add information that is not in the transcript.
        \(customBlock(custom))
        Transcript:
        \(transcript)
        """

        if options.includeActionItems {
            prompt += "\n\n" + actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines,
                                                     intro: "After the email, list any explicit commitments:")
        }

        prompt += formatRule

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Prompt helpers

    private func actionItemInstruction(owners: Bool, deadlines: Bool, intro: String = "For each explicit commitment someone made, write one line:") -> String {
        var s = intro + "\n"
        s += "ACTION: the task"
        if owners  { s += " — Owner: who said it" }
        if deadlines { s += " — Due: deadline if stated, else omit" }
        s += """

        Do NOT output any ACTION lines if no one explicitly committed. "We should" is not a commitment.
        """
        return s
    }

    private func contextBlock(_ source: String) -> String {
        guard !source.isEmpty else { return "" }
        switch source {
        case "Zoom call", "Microsoft Teams call", "FaceTime call", "Webex call":
            return "Context: This is a transcript of a \(source). It may have two or more participants.\n"
        case "browser audio":
            return "Context: This audio is from a browser (YouTube, podcast, or online video). It is a one-way presentation — one person speaking, not a live meeting. The speaker may be labeled \"Caller\" in the transcript but they are a video/podcast presenter, not a live caller. Do not generate action items or decisions unless the presenter explicitly stated them as commitments.\n"
        case "Discord":
            return "Context: This audio was captured from Discord.\n"
        case "Loom recording":
            return "Context: This is a Loom recording — a single presenter speaking to camera, not a live meeting.\n"
        default:
            return "Context: System audio source: \(source).\n"
        }
    }

    private func customBlock(_ instructions: String) -> String {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\n\nAdditional instructions from the user: \(instructions.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private let formatRule = """


    IMPORTANT: Plain text only. No markdown. No asterisks, no pound signs, no underscores for emphasis. \
    Use plain line breaks instead of bullet symbols.
    """

    private func stripMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            if let range = l.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                l = String(l[range.upperBound...])
            }
            return l
        }
        var result = lines.joined(separator: "\n")
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "*",  with: "")
        result = result.replacingOccurrences(of: "_",  with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Ollama generate

    private func generate(prompt: String, model: String) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return "Error: bad URL" }

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 600]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "Error: encoding" }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180

        do {
            let (respData, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let text = json["response"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return "Error: could not parse response"
        } catch {
            return "Error: \(error.localizedDescription)"
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
                        let stripped = next.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                        line += " — " + stripped
                        j += 1
                    } else { break }
                }
                i = j
                merged.append(line)
            } else {
                i += 1
            }
        }

        var items: [ActionItem] = []
        for line in merged {
            let content = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            var task = content
            var owner = "Unknown"
            var due = "Not specified"

            for ownerKey in ["— Owner:", "- Owner:", "| Owner:", "Owner:"] {
                if let range = content.range(of: ownerKey, options: .caseInsensitive) {
                    task = String(content[content.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let after = String(content[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    for dueKey in ["— Due:", "- Due:", "| Due:", "Due:"] {
                        if let dueRange = after.range(of: dueKey, options: .caseInsensitive) {
                            owner = String(after[after.startIndex..<dueRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                            let dueStr = String(after[dueRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                            due = ["none", "n/a", "not specified", "tbd", ""].contains(dueStr.lowercased())
                                ? "Not specified" : dueStr
                            break
                        }
                    }
                    if owner == "Unknown" { owner = after }
                    break
                }
            }

            task  = task.replacingOccurrences(of: "[Local]",  with: "you")
                        .replacingOccurrences(of: "[Remote]", with: "caller")
                        .replacingOccurrences(of: "[You]",    with: "you")
                        .replacingOccurrences(of: "[Caller]", with: "caller")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            owner = owner.replacingOccurrences(of: "[Local]",  with: "you")
                         .replacingOccurrences(of: "[Remote]", with: "caller")
                         .replacingOccurrences(of: "[You]",    with: "you")
                         .replacingOccurrences(of: "[Caller]", with: "caller")
                         .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))

            guard !task.isEmpty, task.count < 400 else { continue }
            items.append(ActionItem(task: task, owner: owner, due: due))
        }
        return items
    }

    // MARK: – Model resolution

    private func resolveModel() async -> String {
        if !selectedModel.isEmpty { return selectedModel }
        await checkAvailability()
        return selectedModel.isEmpty ? "llama3.2" : selectedModel
    }

    private func autoSelectModel() -> String {
        for preferred in ["llama3.2", "llama3", "mistral", "llama2"] {
            if let match = availableModels.first(where: { $0.hasPrefix(preferred) }) { return match }
        }
        return availableModels.first ?? "llama3.2"
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
