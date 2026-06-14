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

    func run(action: AIAction, transcript: String, options: AIOptions) async -> AIResult {
        await checkAvailability()
        guard isAvailable else {
            return AIResult(
                main: "Ollama is not running.\n\nInstall at ollama.com, then:\n  ollama pull llama3.2",
                actionItems: []
            )
        }
        let model = await resolveModel()
        switch action {
        case .recap:     return await generateRecap(transcript: transcript, options: options, model: model)
        case .decisions: return await generateDecisions(transcript: transcript, model: model)
        case .nextSteps: return await generateNextSteps(transcript: transcript, options: options, model: model)
        case .email:     return await generateEmail(transcript: transcript, options: options, model: model)
        }
    }

    // MARK: – Recap

    private func generateRecap(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var prompt = """
        You are a meeting analyst. Read the transcript below and write a clear meeting recap.

        The transcript labels speakers as "You", "Caller", or "Speaker 1", "Speaker 2", etc.

        Write in plain prose. Include:
        - A 2 to 3 sentence summary of what was discussed
        - Key topics covered
        - Key decisions made
        """

        if options.includeActionItems {
            prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        }

        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Key Decisions

    private func generateDecisions(transcript: String, model: String) async -> AIResult {
        let prompt = """
        You are a meeting analyst. Read the transcript below and extract only the firm decisions made or agreed upon.

        The transcript labels speakers as "You", "Caller", or "Speaker 1", "Speaker 2", etc.

        List each decision clearly and concisely. Do not include discussion or speculation, only decisions that were actually agreed on.
        \(formatRule)

        Transcript:
        \(transcript)
        """

        let raw = await generate(prompt: prompt, model: model)
        return AIResult(main: stripMarkdown(raw), actionItems: [])
    }

    // MARK: – Next Steps

    private func generateNextSteps(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var prompt = """
        You are a meeting analyst. Read the transcript below and list every follow-up task, commitment, or thing that needs to happen after this meeting.

        The transcript labels speakers as "You", "Caller", or "Speaker 1", "Speaker 2", etc. When referring to "You", use "you". When referring to others, use "Caller" or their name if mentioned.
        """

        prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: parseActionItems(from: clean))
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var prompt = """
        You are a professional email writer. Based on the meeting transcript below, write a follow-up email.

        The transcript labels speakers as "You", "Caller", or "Speaker 1", "Speaker 2", etc. "You" is the email sender. The primary other speaker is the email recipient.

        The email should include:
        - Subject line
        - Brief opening
        - Summary of what was discussed
        - Key decisions
        """

        if options.includeActionItems {
            prompt += "\n        - Action items"
            if options.includeOwners { prompt += " with who is responsible" }
            if options.includeDeadlines { prompt += " and any deadlines" }
        }

        prompt += "\n        - Professional closing\n\nUse [Your Name] for the sender."

        if options.includeActionItems {
            prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines,
                                            intro: "\n\nAfter the email body, list each action item:")
        }

        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Prompt helpers

    private func actionItemInstruction(owners: Bool, deadlines: Bool, intro: String = "\n\nList each action item:") -> String {
        var s = intro + "\n"
        s += "ACTION: what needs to be done"
        if owners  { s += " — Owner: you / caller / their name" }
        if deadlines { s += " — Due: specific deadline or none" }
        s += """


        Rules for action items:
        - One action item per line, starting with "ACTION:"
        - Do not number them
        - For Owner: write "you" if it is the in-room person's task, "caller" if it is the remote person's task, or the person's actual name if mentioned
        - Do not write [Local] or [Remote] anywhere in the output
        """
        return s
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
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "_", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Ollama generate

    private func generate(prompt: String, model: String) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return "Error: bad URL" }

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.4, "num_predict": 900]
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
    // Handles: numbered prefixes, owner on continuation line, multiple separator styles

    private func parseActionItems(from text: String) -> [ActionItem] {
        // Pre-process: merge ACTION: lines with orphan "- Owner:" / "- Due:" continuation lines
        let rawLines = text.components(separatedBy: "\n")
        var merged: [String] = []
        var i = 0
        while i < rawLines.count {
            var line = rawLines[i].trimmingCharacters(in: .whitespaces)
            // Strip leading "1." or "1)" numbering
            if let r = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                line = String(line[r.upperBound...])
            }
            if line.uppercased().hasPrefix("ACTION:") {
                // Absorb continuation lines that are orphaned owner/due fields
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

            // Sanitize any residual bracket notation the model still outputs
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
