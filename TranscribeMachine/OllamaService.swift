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

        Speaker key: [Local] = person in the room with the microphone, [Remote] = caller on Zoom or phone.

        Write in plain prose. Include:
        - A 2 to 3 sentence summary of what was discussed
        - Key topics covered
        - Key decisions made
        """

        if options.includeActionItems {
            prompt += "\n\nThen list every action item using exactly this format (one per line):\n"
            prompt += "ACTION: [task]"
            if options.includeOwners { prompt += " — Owner: [Local/Remote/name]" }
            if options.includeDeadlines { prompt += " — Due: [deadline or Not specified]" }
        }

        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Key Decisions

    private func generateDecisions(transcript: String, model: String) async -> AIResult {
        let prompt = """
        You are a meeting analyst. Read the transcript below and extract only the key decisions that were made or agreed upon.

        Speaker key: [Local] = person in the room with the microphone, [Remote] = caller on Zoom or phone.

        List each decision on its own line. Start each line with "DECISION:" followed by a clear, one-sentence statement of what was decided and who will act on it if relevant. Do not include discussion, only firm decisions.
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
        You are a meeting analyst. Read the transcript below and produce a focused next-steps list.

        Speaker key: [Local] = person in the room with the microphone, [Remote] = caller on Zoom or phone.

        List every follow-up task, commitment, or thing that needs to happen after this meeting.
        """

        if options.includeOwners {
            prompt += " For each item, note who is responsible (Local, Remote, or a name if mentioned)."
        }
        if options.includeDeadlines {
            prompt += " Include any deadline or timeframe mentioned."
        }

        prompt += "\n\nUse this format for each item (one per line):\n"
        prompt += "ACTION: [task]"
        if options.includeOwners { prompt += " — Owner: [name or Local/Remote]" }
        if options.includeDeadlines { prompt += " — Due: [deadline or Not specified]" }

        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: parseActionItems(from: clean))
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var prompt = """
        You are a professional email writer. Based on the meeting transcript below, write a follow-up email.

        Speaker key: [Local] = person in the room with the microphone, [Remote] = caller on Zoom or phone.

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

        prompt += "\n        - Professional closing\n\nUse [Your Name] as a placeholder for the sender."

        if options.includeActionItems {
            prompt += "\n\nAfter the email body, list action items using this format (one per line):\n"
            prompt += "ACTION: [task]"
            if options.includeOwners { prompt += " — Owner: [name or Local/Remote]" }
            if options.includeDeadlines { prompt += " — Due: [deadline or Not specified]" }
        }

        prompt += formatRule + "\n\nTranscript:\n\(transcript)"

        let raw = await generate(prompt: prompt, model: model)
        let clean = stripMarkdown(raw)
        return AIResult(main: clean, actionItems: options.includeActionItems ? parseActionItems(from: clean) : [])
    }

    // MARK: – Prompt helpers

    private let formatRule = """


    IMPORTANT: Plain text only. No markdown. No asterisks, no pound signs, no underscores for emphasis. \
    Use numbered lists or plain line breaks instead of bullet symbols.
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

    private func parseActionItems(from text: String) -> [ActionItem] {
        var items: [ActionItem] = []
        for line in text.components(separatedBy: "\n") {
            guard line.uppercased().hasPrefix("ACTION:") else { continue }
            let content = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)

            var task = content
            var owner = "Unknown"
            var due = "Not specified"

            if let ownerRange = content.range(of: "— Owner:", options: .caseInsensitive) {
                task = String(content[content.startIndex..<ownerRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let after = String(content[ownerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let dueRange = after.range(of: "— Due:", options: .caseInsensitive) {
                    owner = String(after[after.startIndex..<dueRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    due   = String(after[dueRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    owner = after
                }
            }

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
