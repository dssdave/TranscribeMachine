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

    func run(action: AIAction, transcript: String, options: AIOptions, customInstructions: String = "") async -> AIResult {
        await checkAvailability()
        guard isAvailable else {
            return AIResult(
                main: "Ollama is not running.\n\nInstall at ollama.com, then:\n  ollama pull llama3.2",
                actionItems: []
            )
        }
        let model = await resolveModel()
        switch action {
        case .recap:     return await generateRecap(transcript: transcript, options: options, custom: customInstructions, model: model)
        case .decisions: return await generateDecisions(transcript: transcript, custom: customInstructions, model: model)
        case .nextSteps: return await generateNextSteps(transcript: transcript, options: options, custom: customInstructions, model: model)
        case .email:     return await generateEmail(transcript: transcript, options: options, custom: customInstructions, model: model)
        }
    }

    // MARK: – Recap

    private func generateRecap(transcript: String, options: AIOptions, custom: String, model: String) async -> AIResult {
        var prompt = """
        You are a meeting analyst. Read the transcript below and write a concise, accurate recap.

        Speakers are labeled "You", "Caller", or "Speaker 1", "Speaker 2", etc.

        Write in plain prose:
        - 2 to 3 sentences summarizing what was discussed
        - Key topics covered (only topics that were actually discussed)
        - Key decisions made — only if someone clearly said "we decided" or "we agreed". If no decisions were made, omit this section.

        Be accurate. Do not infer, assume, or embellish. Only write what is supported by the transcript.
        """

        if options.includeActionItems {
            prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        }

        prompt += customBlock(custom) + formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Key Decisions

    private func generateDecisions(transcript: String, custom: String, model: String) async -> AIResult {
        let prompt = """
        You are a meeting analyst. Extract only firm decisions from the transcript below.

        Speakers are labeled "You", "Caller", or "Speaker 1", "Speaker 2", etc.

        A firm decision means someone explicitly said they WILL do something, or both parties AGREED on something. Phrases like "we decided", "we agreed", "we will", "let's go with" count. Phrases like "we should", "maybe", "I think", "we could" do NOT count.

        List each firm decision on its own line. Keep each one brief.
        If no firm decisions were made, write: "No firm decisions were made in this meeting."
        \(customBlock(custom))\(formatRule)

        Transcript:
        \(transcript)
        """

        let raw = await generate(prompt: prompt, model: model)
        return AIResult(main: stripMarkdown(raw), actionItems: [])
    }

    // MARK: – Next Steps

    private func generateNextSteps(transcript: String, options: AIOptions, custom: String, model: String) async -> AIResult {
        var prompt = """
        You are a meeting analyst. List only the explicit follow-up commitments from the transcript below.

        Speakers are labeled "You", "Caller", or "Speaker 1", "Speaker 2", etc. Refer to "You" as "you" and others by name or "caller".

        A commitment means someone said they WILL do something specific. "I'll send that over", "I'll follow up by Friday" count. Vague intentions like "we should look into that" do NOT count.

        If no one explicitly committed to anything, write: "No action items were explicitly committed to in this meeting."
        Maximum 5 items. If you find more, keep only the clearest ones.
        """

        prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines)
        prompt += customBlock(custom) + formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: parseActionItems(from: clean))
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, custom: String, model: String) async -> AIResult {
        var prompt = """
        You are a professional email writer. Write a follow-up email based on the meeting transcript below.

        Speakers are labeled "You", "Caller", or "Speaker 1", "Speaker 2", etc. "You" is the email sender. The primary other speaker is the recipient.

        The email should include:
        - Subject line
        - Brief opening referencing the meeting
        - Summary of what was discussed (accurate — only what was actually talked about)
        - Key decisions, if any were made
        """

        if options.includeActionItems {
            prompt += "\n        - Action items (only explicit commitments — maximum 5)"
        }

        prompt += "\n        - Professional closing. Use [Your Name] for the sender."

        if options.includeActionItems {
            prompt += actionItemInstruction(owners: options.includeOwners, deadlines: options.includeDeadlines,
                                            intro: "\n\nAfter the email body, list each explicitly committed action item:")
        }

        prompt += customBlock(custom) + formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Prompt helpers

    private func actionItemInstruction(owners: Bool, deadlines: Bool, intro: String = "\n\nFor each explicit commitment, write one line:") -> String {
        var s = intro + "\n"
        s += "ACTION: what was committed to"
        if owners  { s += " — Owner: you / caller / name" }
        if deadlines { s += " — Due: deadline or none" }
        s += """


        Rules:
        - Only include tasks someone explicitly said they WILL do — no inferred or suggested tasks
        - If there are no explicit commitments, do not output any ACTION: lines at all
        - One ACTION: per line, no numbering
        - Owner: use "you" for the in-room person, "caller" for the remote person, or their actual name
        - Do not write [You], [Caller], [Local], or [Remote] in brackets anywhere
        """
        return s
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
            "options": ["temperature": 0.3, "num_predict": 700]
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
