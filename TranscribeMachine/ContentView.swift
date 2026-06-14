import SwiftUI

// Speaker color palette — up to 8 distinct speakers
private let speakerPalette: [Color] = [
    Color(red: 0.40, green: 0.60, blue: 1.00),
    Color(red: 0.80, green: 0.45, blue: 1.00),
    Color(red: 0.30, green: 0.85, blue: 0.60),
    Color(red: 1.00, green: 0.65, blue: 0.25),
    Color(red: 1.00, green: 0.40, blue: 0.50),
    Color(red: 0.25, green: 0.85, blue: 0.95),
    Color(red: 0.95, green: 0.85, blue: 0.25),
    Color(red: 0.70, green: 0.50, blue: 0.35),
]

struct ContentView: View {

    @StateObject private var transcriber = TranscriptionEngine()
    @StateObject private var recorder    = AudioFileRecorder()
    @StateObject private var whisperX    = WhisperXRunner()
    @StateObject private var ollama      = OllamaService()

    @State private var aiResult: AIResult?
    @State private var isProcessingAI   = false
    @State private var selectedAction: AIAction = .recap
    @State private var options          = AIOptions()
    @State private var copiedTranscript = false
    @State private var copiedAI         = false
    @State private var showActionItems  = true

    @State private var showSettings      = false
    @State private var diarizedSegments: [DiarizedSegment] = []
    @State private var speakerNames: [String: String] = [:]
    @State private var renamingKey: String?
    @State private var renameText = ""

    private var showingDiarized: Bool { !diarizedSegments.isEmpty }
    private var hasContent: Bool { !transcriber.segments.isEmpty || !diarizedSegments.isEmpty }
    private var isReady: Bool { transcriber.modelReady }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.06))
                ScrollView {
                    VStack(spacing: 24) {
                        recordButtons
                        if hasContent || recorder.isRecording { transcriptSection }
                        if hasContent { aiSection }
                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                }
            }

            if renamingKey != nil { renameOverlay }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            recorder.transcriptionEngine = transcriber
            recorder.refreshMicList()
            // Everything downloads silently on launch
            transcriber.prepareModel()
            whisperX.installIfNeeded()
        }
    }

    // MARK: – Header

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TranscribeMachine")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text("Local · Private · Offline")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.3))
            }
            Spacer()
            // Single subtle status indicator
            statusIndicator
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundColor(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .sheet(isPresented: $showSettings) {
                SettingsView(recorder: recorder)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    @ViewBuilder var statusIndicator: some View {
        if transcriber.isDownloading || whisperX.setupState == .installing || whisperX.isRunning {
            HStack(spacing: 7) {
                ProgressView().scaleEffect(0.6)
                Text(currentStatusLabel)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        } else if isReady {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(red: 0.2, green: 0.9, blue: 0.5))
                    .frame(width: 6, height: 6)
                Text("Ready")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
    }

    private var currentStatusLabel: String {
        if transcriber.isDownloading {
            return "Downloading… \(Int(transcriber.downloadProgress * 100))%"
        }
        if whisperX.setupState == .installing { return "Setting up…" }
        if whisperX.isRunning { return whisperX.progress.isEmpty ? "Analyzing…" : whisperX.progress }
        return ""
    }

    // MARK: – Record Buttons

    var recordButtons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                RecordButton(
                    title: "Microphone",
                    subtitle: "In-room",
                    icon: "mic.fill",
                    accentColor: speakerPalette[0],
                    isActive: recorder.micActive,
                    isDisabled: !isReady
                ) { recorder.toggleMic() }

                RecordButton(
                    title: "Computer Audio",
                    subtitle: "Zoom / Meet / Remote",
                    icon: "speaker.wave.2.fill",
                    accentColor: speakerPalette[1],
                    isActive: recorder.systemActive,
                    isDisabled: !isReady
                ) { recorder.toggleSystemAudio() }
            }

            if recorder.isRecording {
                Button { stopRecording() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.circle.fill")
                        Text("Stop")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(StopButtonStyle())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
    }

    // MARK: – Transcript

    var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Transcript", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .textCase(.uppercase)
                    .kerning(0.6)

                if showingDiarized {
                    speakerCountBadge
                }
                Spacer()
                if recorder.isRecording { RecordingPulse() }

                tinyButton(icon: copiedTranscript ? "checkmark" : "doc.on.doc",
                           label: copiedTranscript ? "Copied" : "Copy") {
                    copy(showingDiarized ? diarizedTranscriptText : transcriber.fullTranscript)
                    copiedTranscript = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTranscript = false }
                }
                tinyButton(icon: "trash", label: "Clear") {
                    transcriber.clear(); diarizedSegments = []; aiResult = nil
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if showingDiarized {
                            ForEach(diarizedSegments) { seg in
                                DiarizedRow(seg: seg,
                                            name: displayName(seg),
                                            color: color(for: seg)) {
                                    startRename(seg)
                                }
                                .id(seg.id)
                            }
                        } else if transcriber.segments.isEmpty {
                            Text(recorder.isRecording ? "Listening…" : "")
                                .font(.system(size: 14))
                                .foregroundColor(Color.white.opacity(0.2))
                                .padding(16)
                        } else {
                            ForEach(transcriber.segments) { seg in
                                LiveRow(seg: seg).id(seg.id)
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(minHeight: 140, maxHeight: 280)
                .onChange(of: transcriber.segments.count) { _ in
                    if !showingDiarized, let last = transcriber.segments.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: diarizedSegments.count) { _ in
                    if let last = diarizedSegments.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))

            if showingDiarized {
                Text("Tap a speaker name to rename")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.25))
            }
        }
    }

    var speakerCountBadge: some View {
        let n = Set(diarizedSegments.map { speakerKey($0) }).count
        return Text("\(n) speaker\(n == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.6))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color(red: 0.3, green: 0.85, blue: 0.6).opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: – AI Section

    var aiSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("AI", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .textCase(.uppercase)
                    .kerning(0.6)
                Spacer()
                Picker("", selection: $selectedAction) {
                    ForEach(AIAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button { runAI() } label: {
                    Group {
                        if isProcessingAI {
                            ProgressView().scaleEffect(0.7).frame(width: 50)
                        } else {
                            Text("Run").frame(width: 50)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(color: speakerPalette[1]))
                .disabled(isProcessingAI)
            }

            // Toggles
            HStack(spacing: 10) {
                Toggle("Action Items", isOn: $options.includeActionItems)
                if options.includeActionItems {
                    Toggle("Owners",    isOn: $options.includeOwners)
                    Toggle("Deadlines", isOn: $options.includeDeadlines)
                }
                Spacer()
            }
            .toggleStyle(ChipToggleStyle())

            if !ollama.isAvailable {
                OllamaNotice()
            }

            if let result = aiResult {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(result.main)
                            .font(.system(size: 14))
                            .foregroundColor(Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 300)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(speakerPalette[1].opacity(0.2), lineWidth: 1))

                    if !result.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Action Items", systemImage: "checkmark.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Color.white.opacity(0.4))
                                Spacer()
                                Button(showActionItems ? "Hide" : "Show") {
                                    withAnimation { showActionItems.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundColor(Color.white.opacity(0.35))
                            }
                            if showActionItems {
                                ForEach(result.actionItems) { ActionItemRow(item: $0) }
                            }
                        }
                        .padding(14)
                        .background(Color(red: 0.08, green: 0.14, blue: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.green.opacity(0.12), lineWidth: 1))
                    }

                    HStack {
                        Spacer()
                        Button {
                            let full = result.actionItems.isEmpty ? result.main :
                                result.main + "\n\nACTION ITEMS:\n" +
                                result.actionItems.map { "• \($0.task) — \($0.owner) — \($0.due)" }.joined(separator: "\n")
                            copy(full)
                            copiedAI = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAI = false }
                        } label: {
                            Label(copiedAI ? "Copied!" : "Copy",
                                  systemImage: copiedAI ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                        .buttonStyle(PillButtonStyle(color: speakerPalette[1]))
                    }
                }
            }
        }
    }

    // MARK: – Rename overlay

    var renameOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { renamingKey = nil }
            VStack(spacing: 16) {
                Text("Name this speaker")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                TextField("e.g. David, Sarah…", text: $renameText)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                HStack(spacing: 10) {
                    Button("Cancel") { renamingKey = nil }
                        .buttonStyle(PillButtonStyle(color: Color.white.opacity(0.12)))
                    Button("Save") {
                        if let k = renamingKey { speakerNames[k] = renameText.isEmpty ? nil : renameText }
                        renamingKey = nil
                    }
                    .buttonStyle(PillButtonStyle(color: speakerPalette[0]))
                }
            }
            .padding(28)
            .background(Color(red: 0.11, green: 0.11, blue: 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 40)
        }
    }

    // MARK: – Logic

    private func stopRecording() {
        recorder.stopAll()
        // Auto-diarize if whisperX is ready — silent, no user action needed
        guard whisperX.isReady,
              recorder.localFileURL != nil || recorder.remoteFileURL != nil else { return }
        Task {
            let segs = await whisperX.diarizeBoth(
                localAudio:  recorder.localFileURL,
                remoteAudio: recorder.remoteFileURL
            )
            await MainActor.run { diarizedSegments = segs }
        }
    }

    private func runAI() {
        isProcessingAI = true; aiResult = nil
        let transcript = showingDiarized ? diarizedTranscriptText : transcriber.fullTranscript
        Task {
            let r = await ollama.run(action: selectedAction, transcript: transcript, options: options)
            await MainActor.run { aiResult = r; isProcessingAI = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: – Speaker helpers

    private func speakerKey(_ seg: DiarizedSegment) -> String { "\(seg.source)|\(seg.speaker)" }

    private func displayName(_ seg: DiarizedSegment) -> String {
        let key = speakerKey(seg)
        if let name = speakerNames[key] { return name }
        let prefix = seg.source == "local" ? "Room" : "Remote"
        let num = (Int(seg.speaker.replacingOccurrences(of: "SPEAKER_", with: "")) ?? 0) + 1
        return "\(prefix) \(num)"
    }

    private func color(for seg: DiarizedSegment) -> Color {
        let keys = Array(Set(diarizedSegments.map { speakerKey($0) })).sorted()
        let idx = keys.firstIndex(of: speakerKey(seg)) ?? 0
        return speakerPalette[idx % speakerPalette.count]
    }

    private func startRename(_ seg: DiarizedSegment) {
        let k = speakerKey(seg)
        renameText = speakerNames[k] ?? ""
        renamingKey = k
    }

    private var diarizedTranscriptText: String {
        diarizedSegments.map { "[\(displayName($0))]: \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: – Row Views

struct DiarizedRow: View {
    let seg: DiarizedSegment
    let name: String
    let color: Color
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onRename) {
                HStack(spacing: 4) {
                    Image(systemName: seg.source == "local" ? "mic.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8))
                    Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                .foregroundColor(color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(seg.text)
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(formatTime(seg.start))
                    .font(.system(size: 9))
                    .foregroundColor(Color.white.opacity(0.2))
            }
        }
        .padding(.vertical, 2)
    }

    private func formatTime(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct LiveRow: View {
    let seg: TranscriptSegment
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: seg.speaker.icon).font(.system(size: 8))
                Text(seg.speaker.rawValue).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(seg.speaker.color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(seg.speaker.color.opacity(0.12))
            .clipShape(Capsule())
            .frame(width: 80, alignment: .leading)

            Text(seg.text)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: – Shared UI Components

struct ActionItemRow: View {
    let item: ActionItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundColor(.green.opacity(0.7))
                .font(.system(size: 13)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.task).font(.system(size: 13)).foregroundColor(Color.white.opacity(0.85))
                HStack(spacing: 10) {
                    Label(item.owner, systemImage: "person.fill")
                    if item.due != "Not specified" { Label(item.due, systemImage: "calendar") }
                }
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
            }
        }
    }
}

struct RecordButton: View {
    let title: String; let subtitle: String; let icon: String
    let accentColor: Color; let isActive: Bool; let isDisabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    if isActive {
                        Circle().fill(accentColor.opacity(0.18)).frame(width: 82, height: 82)
                            .scaleEffect(hovering ? 1.08 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isActive)
                    }
                    Circle().fill(isActive ? accentColor : accentColor.opacity(0.12)).frame(width: 64, height: 64)
                    Image(systemName: icon).font(.system(size: 24, weight: .medium))
                        .foregroundColor(isActive ? .white : accentColor.opacity(0.7))
                }
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isDisabled ? Color.white.opacity(0.2) : Color.white.opacity(isActive ? 1 : 0.8))
                    Text(isActive ? "Recording…" : subtitle).font(.system(size: 11))
                        .foregroundColor(isActive ? accentColor : Color.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isActive ? accentColor.opacity(0.1) : Color.white.opacity(hovering ? 0.05 : 0.03))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .stroke(isActive ? accentColor.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1))
            )
        }
        .buttonStyle(.plain).disabled(isDisabled)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

struct RecordingPulse: View {
    @State private var pulsing = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
                .scaleEffect(pulsing ? 1.3 : 1.0).opacity(pulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulsing)
            Text("REC").font(.system(size: 10, weight: .bold)).foregroundColor(Color.red.opacity(0.8)).kerning(1.2)
        }
        .onAppear { pulsing = true }
    }
}

struct OllamaNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("AI features need Ollama").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.white.opacity(0.8))
                Text("ollama.com  →  ollama pull llama3.2").font(.system(size: 11, design: .monospaced)).foregroundColor(Color.white.opacity(0.4))
            }
            Spacer()
            Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com")!) }
                .buttonStyle(PillButtonStyle(color: .orange))
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.18), lineWidth: 1))
    }
}

struct PillButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(color.opacity(configuration.isPressed ? 0.6 : 0.85))
            .clipShape(Capsule())
    }
}

struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color.red.opacity(configuration.isPressed ? 0.5 : 0.7))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                configuration.label.font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(configuration.isOn ? .white : Color.white.opacity(0.4))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(configuration.isOn ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(configuration.isOn ? 0.2 : 0.07), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Settings Sheet

struct SettingsView: View {
    @ObservedObject var recorder: AudioFileRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

            Divider().background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Microphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.5))
                Picker("", selection: $recorder.selectedMicID) {
                    ForEach(recorder.availableMics, id: \.uniqueID) { dev in
                        Text(dev.localizedName).tag(dev.uniqueID)
                    }
                }
                .labelsHidden()
                .disabled(recorder.micActive)
                if recorder.micActive {
                    Text("Stop recording to change mic")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.3))
                }
            }

            Spacer()
        }
        .padding(28)
        .frame(width: 360, height: 240)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .preferredColorScheme(.dark)
        .onAppear { recorder.refreshMicList() }
    }
}

private func tinyButton(icon: String, label: String, action: @escaping @MainActor () -> Void) -> some View {
    Button { action() } label: {
        Label(label, systemImage: icon).font(.system(size: 11))
    }
    .buttonStyle(.plain)
    .foregroundColor(Color.white.opacity(0.35))
}
