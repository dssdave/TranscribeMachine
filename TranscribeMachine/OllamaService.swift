import Foundation
import SwiftUI

// Options the user can toggle before running AI
struct AIOptions {
    var includeActionItems: Bool = true
    var includeOwners: Bool = true
    var includeDeadlines: Bool = true
    var includeSentiment: Bool = false  // optional: meeting tone
}

@MainActor
class OllamaService: ObservableObject {
    @Published var isAvailable = false

    private let baseURL = "http://localhost:11434"

    init() {
        Task { await checkAvailability() }
    }

    func checkAvailability() async {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            isAvailable = (response as? HTTPURLResponse)?.statusCode == 200
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
        case .recap:
            return await generateRecap(transcript: transcript, options: options, model: model)
        case .email:
            return await generateEmail(transcript: transcript, options: options, model: model)
        }
    }

    // MARK: – Recap

    private func generateRecap(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var sections: [String] = []

        sections.append("""
        You are a meeting analyst. Given the transcript below, write a clear meeting recap.

        Speaker key: [Local] = person in the room, [Remote] = caller on Zoom/video.

        Include:
        - A 2-3 sentence summary of what was discussed
        - Key decisions made
        - Topics covered (brief bullets)
        """)

        if options.includeActionItems {
            var actionSection = "- Action items"
            if options.includeOwners { actionSection += " (with who is responsible)" }
            if options.includeDeadlines { actionSection += " (and any deadlines mentioned)" }
            sections.append(actionSection)
        }

        if options.includeSentiment {
            sections.append("- Overall meeting tone/sentiment")
        }

        sections.append("""

        Format action items as a simple list like:
        ACTION: [task] — Owner: [Local/Remote/Unknown] — Due: [deadline or 'Not specified']

        Transcript:
        \(transcript)
        """)

        let prompt = sections.joined(separator: "\n")
        let raw = await generate(prompt: prompt, model: model)

        return AIResult(
            main: raw,
            actionItems: parseActionItems(from: raw)
        )
    }

    // MARK: – Email

    private func generateEmail(transcript: String, options: AIOptions, model: String) async -> AIResult {
        var prompt = """
        You are a professional email writer. Based on the meeting transcript below, write a follow-up email.

        Speaker key: [Local] = person in the room, [Remote] = caller on Zoom/video.

        The email should include:
        - Subject line
        - Brief thank you / intro
        - Summary of what was discussed
        - Key decisions
        """

        if options.includeActionItems {
            prompt += "\n        - Action items"
            if options.includeOwners { prompt += " with owner names (use Local/Remote if names unknown)" }
            if options.includeDeadlines { prompt += " and any deadlines" }
        }

        prompt += """

        - Professional closing

        Keep it concise. Use [Your Name] as a placeholder for the sender.

        Transcript:
        \(transcript)
        """

        let raw = await generate(prompt: prompt, model: model)

        return AIResult(
            main: raw,
            actionItems: options.includeActionItems ? parseActionItems(from: raw) : []
        )
    }

    // MARK: – Ollama generate

    private func generate(prompt: String, model: String) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return "Error: bad URL" }

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.6, "num_predict": 768]
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

    // MARK: – Parse action items from response text

    private func parseActionItems(from text: String) -> [ActionItem] {
        var items: [ActionItem] = []
        let lines = text.components(separatedBy: "\n")
        for line in lines {
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
                    due = String(after[dueRange.upperBound...]).trimmingCharacters(in: .whitespaces)
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
        guard
            let url = URL(string: "\(baseURL)/api/tags"),
            let (data, _) = try? await URLSession.shared.data(from: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return "llama3.2" }

        let names = models.compactMap { $0["name"] as? String }
        for preferred in ["llama3.2", "llama3", "mistral", "llama2"] {
            if let match = names.first(where: { $0.hasPrefix(preferred) }) { return match }
        }
        return names.first ?? "llama3.2"
    }
}

// MARK: – Models

enum AIAction: String, CaseIterable {
    case recap = "Recap"
    case email = "Email Draft"
}

struct AIResult {
    let main: String          // full text output
    let actionItems: [ActionItem]
}

struct ActionItem: Identifiable {
    let id = UUID()
    let task: String
    let owner: String
    let due: String
}
