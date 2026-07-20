import SwiftUI
import UniformTypeIdentifiers

// MARK: – Paper Theme

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

struct PaperTheme {
    let paper: Color
    let titlebar: Color
    let card: Color
    let line: Color
    let line2: Color
    let hair: Color
    let ink: Color
    let ink2: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let accentInk: Color
    let accentTint: Color
    let slate: Color
    let slateTint: Color
    let green: Color
    let toggle: Color
    let knob: Color
    let ghost: Color

    static func tokens(for scheme: ColorScheme) -> PaperTheme {
        scheme == .dark ? .dark : .light
    }

    static let light = PaperTheme(
        paper: Color(hex: 0xFAF8F3),
        titlebar: Color(hex: 0xF1EDE4),
        card: Color(hex: 0xFFFFFF),
        line: Color(hex: 0xE7E1D4),
        line2: Color(hex: 0xEDE8DC),
        hair: Color(hex: 0xD8CFBB),
        ink: Color(hex: 0x232019),
        ink2: Color(hex: 0x33302A),
        muted: Color(hex: 0x6B665C),
        faint: Color(hex: 0x9A9384),
        accent: Color(hex: 0xB0623F),
        accentInk: Color(hex: 0xFFFFFF),
        accentTint: Color(hex: 0xF3ECE6),
        slate: Color(hex: 0x3F6785),
        slateTint: Color(hex: 0xEAF0F4),
        green: Color(hex: 0x4A9D63),
        toggle: Color(hex: 0xE4DED0),
        knob: Color(hex: 0xFFFFFF),
        ghost: Color(hex: 0xFFFFFF)
    )

    static let dark = PaperTheme(
        paper: Color(hex: 0x1A1712),
        titlebar: Color(hex: 0x221E17),
        card: Color(hex: 0x211D16),
        line: Color(hex: 0xD8CFBB, alpha: 0.13),
        line2: Color(hex: 0xD8CFBB, alpha: 0.10),
        hair: Color(hex: 0xD8CFBB, alpha: 0.35),
        ink: Color(hex: 0xEEE7D8),
        ink2: Color(hex: 0xE4DDCE),
        muted: Color(hex: 0xA69C88),
        faint: Color(hex: 0x8F8674),
        accent: Color(hex: 0xE0946B),
        accentInk: Color(hex: 0x211A12),
        accentTint: Color(hex: 0xE0946B, alpha: 0.16),
        slate: Color(hex: 0x9DB8D0),
        slateTint: Color(hex: 0x7FA0BE, alpha: 0.16),
        green: Color(hex: 0x5FB87A),
        toggle: Color(hex: 0xD8CFBB, alpha: 0.14),
        knob: Color(hex: 0xD8CFBB),
        ghost: Color.white.opacity(0.04)
    )

    static let recDot = Color(hex: 0xE0523F)
    static let stopButton = Color(hex: 0xC24A34)
}

extension Font {
    static func newsreader(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func newsreaderItalic(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
}

private func speakerColor(_ idx: Int, theme: PaperTheme) -> Color {
    let palette = [theme.slate, theme.accent, theme.green,
                   Color(hex: 0x8B5FBF), Color(hex: 0xC9A227),
                   Color(hex: 0x4A9DB0), Color(hex: 0xB05F8B)]
    return palette[idx % palette.count]
}

struct ContentView: View {

    @StateObject private var transcriber = TranscriptionEngine()
    @StateObject private var recorder    = AudioFileRecorder()
    @StateObject private var whisperX    = WhisperXRunner()
    @StateObject private var ollama      = OllamaService()

    @State private var aiResult: AIResult?
    @State private var isProcessingAI = false
    @State private var selectedAction: AIAction = .recap
    @State private var options = AIOptions()
    @State private var copiedTranscript = false
    @State private var copiedAI = false
    @State private var customInstructions = ""

    @AppStorage("silenceTimeoutMinutes")   private var silenceTimeoutMinutes: Int = 0
    @AppStorage("whisperModelQuality")     private var whisperModelQuality: String = "balanced"
    @AppStorage("transcriptionLanguage")   private var transcriptionLanguage: String = "en"
    @AppStorage("suppressRepetition")      private var suppressRepetition: Bool = true
    @AppStorage("noiseGate")              private var noiseGate: String = "normal"
    @AppStorage("chunkLengthSeconds")     private var chunkLengthSeconds: Int = 0
    @AppStorage("strictConfidence")       private var strictConfidence: Bool = false
    @AppStorage("appearanceMode")         private var appearanceMode: String = "system"
    @AppStorage("promptRecap")      private var promptRecap:      String = OllamaService.defaultPromptRecap
    @AppStorage("promptDecisions")  private var promptDecisions:  String = OllamaService.defaultPromptDecisions
    @AppStorage("promptNextSteps")  private var promptNextSteps:  String = OllamaService.defaultPromptNextSteps
    @AppStorage("promptEmail")      private var promptEmail:      String = OllamaService.defaultPromptEmail

    @State private var showSettings = false
    @State private var selectedPromptTab: Int = 0
    @State private var diarizedSegments: [DiarizedSegment] = []
    @State private var speakerNames: [String: String] = [:]
    @State private var renamingKey: String?
    @State private var renameText = ""
    @State private var recordingStartDate: Date?
    @State private var elapsedSeconds = 0
    @State private var silenceWarningActive = false
    @State private var silenceTick = 0

    @Environment(\.colorScheme) private var systemColorScheme

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var showingDiarized: Bool { !diarizedSegments.isEmpty }
    private var hasContent: Bool { !transcriber.segments.isEmpty || !diarizedSegments.isEmpty }
    private var isReady: Bool { transcriber.modelReady }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    private var effectiveScheme: ColorScheme {
        preferredScheme ?? systemColorScheme
    }

    private var theme: PaperTheme { PaperTheme.tokens(for: effectiveScheme) }

    var body: some View {
        ZStack {
            theme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(theme.line)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        sourcesCard

                        if recorder.micPermissionDenied {
                            PermissionBanner(
                                theme: theme,
                                message: "Microphone access denied. Open System Settings → Privacy & Security → Microphone and enable TranscribeMachine.",
                                buttonLabel: "Open Settings",
                                action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                            )
                        }
                        if recorder.screenRecordingPermissionDenied {
                            PermissionBanner(
                                theme: theme,
                                message: "Screen Recording access required for Computer Audio. Open System Settings → Privacy & Security → Screen Recording and enable TranscribeMachine.",
                                buttonLabel: "Open Settings",
                                action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                            )
                        }
                        if transcriber.modelStatus == "Download failed" { setupBanner }

                        if recorder.isRecording { recordingBar }

                        if silenceWarningActive { silenceWarningBanner }

                        if hasContent || recorder.isRecording {
                            transcriptSection
                        } else {
                            emptyStatePanel
                        }

                        if hasContent && !recorder.isRecording { aiSection }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
            }

            if renamingKey != nil { renameOverlay }
            if showSettings {
                settingsOverlay
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            recorder.transcriptionEngine = transcriber
            recorder.refreshMicList()
            transcriber.prepareModel()
            whisperX.installIfNeeded()
        }
        .onChange(of: whisperModelQuality) { _ in
            transcriber.reloadModel()
        }
        .onChange(of: recorder.isRecording) { isRecording in
            if isRecording {
                recordingStartDate = Date()
                transcriber.resetActivity()
                elapsedSeconds = 0
                silenceWarningActive = false
            } else {
                recordingStartDate = nil
                silenceWarningActive = false
            }
        }
        .onReceive(ticker) { _ in
            if recorder.isRecording { elapsedSeconds += 1 }
            silenceTick += 1
            if silenceTick >= 10 { silenceTick = 0; checkSilenceTimeout() }
        }
        .sheet(isPresented: $transcriber.needsDownloadConfirmation) {
            DownloadConfirmSheet(
                sizeMB: transcriber.pendingDownloadSizeMB,
                onConfirm: { transcriber.confirmDownload() },
                onCancel:  { transcriber.cancelDownload() }
            )
        }
    }

    // MARK: – Header

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("TranscribeMachine")
                    .font(.newsreader(22))
                    .tracking(-0.2)
                    .foregroundColor(theme.ink)
                Text("Local · Private · Offline")
                    .font(.system(size: 11))
                    .tracking(0.4)
                    .foregroundColor(theme.faint)
            }
            Spacer()
            statusIndicator
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings = true }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundColor(theme.faint)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    @ViewBuilder var statusIndicator: some View {
        if transcriber.isDownloading || whisperX.setupState == .installing || whisperX.isRunning
            || ollama.state == .starting || ollama.state == .downloading {
            HStack(spacing: 7) {
                ProgressView().scaleEffect(0.6)
                Text(currentStatusLabel)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.muted)
            }
        } else if isReady && ollama.state == .ready {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.green)
                    .frame(width: 7, height: 7)
                Text("Ready · \(qualityLabel)")
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.muted)
            }
        }
    }

    private var currentStatusLabel: String {
        if transcriber.isDownloading    { return transcriber.modelStatus }
        if whisperX.setupState == .installing { return "Setting up…" }
        if whisperX.isRunning           { return "Processing…" }
        if ollama.state == .downloading { return "Setting up…" }
        if ollama.state == .starting    { return "Starting…" }
        return ""
    }

    private var qualityLabel: String {
        switch whisperModelQuality {
        case "quality":  return "Quality"
        case "balanced": return "Balanced"
        default:         return "Fast"
        }
    }

    var setupBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text("Setup failed. Check your connection and relaunch.")
                .font(.system(size: 12)).foregroundColor(theme.muted)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.ghost)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    var silenceWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundColor(.orange).font(.system(size: 13))
            Text("No audio detected — recording will stop soon")
                .font(.system(size: 12)).foregroundColor(.orange.opacity(0.9))
            Spacer()
            Button("Keep Going") {
                transcriber.extendActivity()
                silenceWarningActive = false
            }
            .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: – Sources Card

    var sourcesCard: some View {
        VStack(spacing: 0) {
            SourceRow(
                theme: theme, title: "Microphone", subtitle: "In-room", icon: "mic.fill",
                tileColor: theme.slate, tileTint: theme.slateTint,
                isActive: recorder.micActive, isDisabled: !isReady
            ) { recorder.toggleMic() }

            Divider().background(theme.line2)

            SourceRow(
                theme: theme, title: "Computer Audio", subtitle: "Zoom / Meet / Remote", icon: "speaker.wave.2.fill",
                tileColor: theme.accent, tileTint: theme.accentTint,
                isActive: recorder.systemActive, isDisabled: !isReady
            ) { recorder.toggleSystemAudio() }
        }
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.line, lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
    }

    var recordingBar: some View {
        HStack(spacing: 10) {
            BlinkingDot(color: PaperTheme.recDot)
            Text("Recording")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(theme.accent)
            Text(formatElapsed(elapsedSeconds))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(theme.muted)
            Spacer()
            Button(action: stopRecording) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(PaperTheme.stopButton)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(theme.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: – Empty State

    var emptyStatePanel: some View {
        VStack(spacing: 8) {
            Text("Ready when you are")
                .font(.newsreaderItalic(20))
                .foregroundColor(theme.ink2)
            Text("Choose a source above to start. Your transcript appears here — nothing ever leaves your Mac.")
                .font(.system(size: 12))
                .foregroundColor(theme.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(theme.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }

    // MARK: – Transcript

    var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Transcript")
                    .font(.newsreaderItalic(17))
                    .foregroundColor(theme.ink2)
                if showingDiarized { speakerCountBadge }
                Spacer()
                if recorder.isRecording {
                    RecordingPulse(color: theme.accent)
                }
                transcriptAction(label: copiedTranscript ? "Copied" : "Copy") {
                    copy(showingDiarized ? diarizedTranscriptText : transcriber.fullTranscript)
                    copiedTranscript = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTranscript = false }
                }
                transcriptAction(label: "Export") { exportTranscript() }
                transcriptAction(label: "Clear") {
                    transcriber.clear(); diarizedSegments = []; aiResult = nil
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if showingDiarized {
                            ForEach(Array(diarizedSegments.enumerated()), id: \.element.id) { _, seg in
                                SpeakerBlock(
                                    theme: theme,
                                    label: displayName(seg),
                                    color: color(for: seg),
                                    text: seg.text,
                                    onTapLabel: { startRename(seg) }
                                )
                                .id(seg.id)
                            }
                        } else if transcriber.segments.isEmpty {
                            Text(recorder.isRecording ? "Listening…" : "")
                                .font(.system(size: 14))
                                .foregroundColor(theme.faint)
                                .padding(16)
                        } else {
                            ForEach(transcriber.segments) { seg in
                                SpeakerBlock(
                                    theme: theme,
                                    label: seg.speaker.rawValue,
                                    color: seg.speaker.color,
                                    text: seg.text,
                                    onTapLabel: nil
                                )
                                .id(seg.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(minHeight: 70, maxHeight: 180)
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
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))

            if showingDiarized {
                Text("Tap a speaker name to rename")
                    .font(.system(size: 11))
                    .foregroundColor(theme.faint)
            }
        }
    }

    private func transcriptAction(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12)).foregroundColor(theme.faint)
        }
        .buttonStyle(.plain)
    }

    var speakerCountBadge: some View {
        let n = Set(diarizedSegments.map { speakerKey($0) }).count
        return Text("\(n) speaker\(n == 1 ? "" : "s")")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.green)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(theme.green.opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: – AI Section

    var aiSection: some View {
        VStack(alignment: .leading, spacing: 18) {

            HStack(spacing: 8) {
                ForEach(AIAction.allCases, id: \.self) { action in
                    Button {
                        selectedAction = action
                        runAI()
                    } label: {
                        HStack(spacing: 5) {
                            if isProcessingAI && selectedAction == action {
                                ProgressView().scaleEffect(0.55).frame(width: 10, height: 10)
                            }
                            Text(action.rawValue)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(PaperActionPillStyle(
                        theme: theme,
                        isSelected: selectedAction == action && aiResult != nil && !isProcessingAI
                    ))
                    .disabled(isProcessingAI || ollama.state != .ready)
                }
            }

            VStack(spacing: 0) {
                TextField("Optional — keep it brief · formal tone · focus on the decision",
                          text: $customInstructions)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.ink2)
                    .padding(.vertical, 8)
                Rectangle().fill(theme.hair).frame(height: 1)
            }

            if ollama.state == .unavailable { AIUnavailableNotice(theme: theme) }

            if let result = aiResult {
                outputSection(result)
            }
        }
    }

    @ViewBuilder
    private func outputSection(_ result: AIResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(outputHeading)
                    .font(.newsreader(19))
                    .foregroundColor(theme.ink)
                Spacer()
                Button(action: copyOutput) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedAI ? "checkmark" : "doc.on.doc")
                        Text(copiedAI ? "Copied!" : "Copy")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }

            if selectedAction == .email {
                emailCard(result)
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(Array(outputLines(result.main).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(bulletGlyph)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.accent)
                            Text(line)
                                .font(.system(size: 14.5))
                                .lineSpacing(5)
                                .foregroundColor(theme.ink2)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !result.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Follow-ups")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.faint)
                        .textCase(.uppercase)
                        .kerning(0.8)
                    ForEach(result.actionItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Text("→")
                                .font(.system(size: 13))
                                .foregroundColor(theme.accent)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.task)
                                    .font(.system(size: 14.5))
                                    .foregroundColor(theme.ink2)
                                    .textSelection(.enabled)
                                let meta = [
                                    item.owner != "Unknown" ? item.owner : "Unassigned",
                                    item.due   != "Not specified" ? item.due : nil
                                ].compactMap { $0 }.joined(separator: " · ")
                                if !meta.isEmpty {
                                    Text(meta)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(theme.faint)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line, lineWidth: 1))
            }
        }
    }

    private func emailCard(_ result: AIResult) -> some View {
        let (to, subject, body) = parseEmail(result.main)
        return VStack(alignment: .leading, spacing: 0) {
            emailRow(label: "To", value: to)
            Rectangle().fill(theme.line2).frame(height: 1)
            emailRow(label: "Subject", value: subject, valueBold: true)
            Rectangle().fill(theme.line2).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(outputLines(body).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 14))
                        .lineSpacing(6)
                        .foregroundColor(theme.ink2)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.line, lineWidth: 1))
    }

    private func emailRow(label: String, value: String, valueBold: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.faint)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: valueBold ? .semibold : .regular))
                .foregroundColor(theme.ink2)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func parseEmail(_ text: String) -> (to: String, subject: String, body: String) {
        var to = ""
        var subject = ""
        var bodyLines: [String] = []
        var pastHeaders = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !pastHeaders, line.lowercased().hasPrefix("to:") {
                to = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !pastHeaders, line.lowercased().hasPrefix("subject:") {
                subject = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !pastHeaders, line.isEmpty { pastHeaders = true; continue }
            pastHeaders = true
            bodyLines.append(rawLine)
        }
        if to.isEmpty { to = "Recipient" }
        if subject.isEmpty { subject = "Draft Email" }
        return (to, subject, bodyLines.joined(separator: "\n"))
    }

    private func outputLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var outputHeading: String {
        switch selectedAction {
        case .recap:     return "Recap"
        case .decisions: return "Decisions"
        case .nextSteps: return "Next Steps"
        case .email:     return "Draft Email"
        }
    }

    private var bulletGlyph: String {
        switch selectedAction {
        case .recap:     return "—"
        case .decisions: return "✓"
        case .nextSteps: return "→"
        case .email:     return "—"
        }
    }

    private func copyOutput() {
        guard let result = aiResult else { return }
        var lines = [result.main]
        if !result.actionItems.isEmpty {
            lines.append("\nFOLLOW-UPS:")
            lines.append(contentsOf: result.actionItems.map { item in
                var s = "→ \(item.task)"
                if item.owner != "Unknown"       { s += "  (\(item.owner))" }
                if item.due   != "Not specified" { s += "  — \(item.due)" }
                return s
            })
        }
        copy(lines.joined(separator: "\n"))
        copiedAI = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAI = false }
    }

    // MARK: – Rename overlay

    var renameOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { renamingKey = nil }
            VStack(spacing: 16) {
                Text("Name this speaker")
                    .font(.newsreader(16)).foregroundColor(theme.ink)
                TextField("e.g. David, Sarah…", text: $renameText)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
                HStack(spacing: 10) {
                    Button("Cancel") { renamingKey = nil }
                        .buttonStyle(PillButtonStyle(color: theme.muted))
                    Button("Save") {
                        if let k = renamingKey { speakerNames[k] = renameText.isEmpty ? nil : renameText }
                        renamingKey = nil
                    }
                    .buttonStyle(PillButtonStyle(color: theme.accent))
                }
            }
            .padding(28)
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 40)
        }
    }

    // MARK: – Settings (full-window replacement)

    var settingsOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.newsreader(17))
                    .foregroundColor(theme.ink)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 16)

            Divider().background(theme.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    settingsRow("Appearance") {
                        Picker("", selection: $appearanceMode) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    settingsDivider

                    settingsRow("Microphone") {
                        Picker("", selection: $recorder.selectedMicID) {
                            ForEach(recorder.availableMics, id: \.uniqueID) { dev in
                                Text(dev.localizedName).tag(dev.uniqueID)
                            }
                        }
                        .labelsHidden()
                        .disabled(recorder.micActive)
                        if recorder.micActive {
                            Text("Stop recording to change mic")
                                .font(.system(size: 11)).foregroundColor(theme.faint)
                        }
                    }

                    settingsDivider

                    settingsRow("Transcription Quality") {
                        Picker("", selection: $whisperModelQuality) {
                            Text("Fast").tag("fast")
                            Text("Balanced").tag("balanced")
                            Text("Quality").tag("quality")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Fast: smallest, quickest. Balanced: small model. Quality: medium model, most accurate.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Language") {
                        Picker("", selection: $transcriptionLanguage) {
                            Text("Auto-detect").tag("auto")
                            Text("English").tag("en")
                            Text("French").tag("fr")
                            Text("Spanish").tag("es")
                            Text("Portuguese").tag("pt")
                            Text("German").tag("de")
                            Text("Italian").tag("it")
                            Text("Japanese").tag("ja")
                            Text("Chinese").tag("zh")
                        }
                        .labelsHidden()
                        Text("Forcing a language improves accuracy. Auto-detect can misfire on short clips.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Reduce Repetition") {
                        Toggle("", isOn: $suppressRepetition)
                            .labelsHidden()
                            .toggleStyle(.switch)
                        Text("Filters repetitive or looping output. Recommended for noisy environments.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Noise Gate") {
                        Picker("", selection: $noiseGate) {
                            Text("Strict").tag("strict")
                            Text("Normal").tag("normal")
                            Text("Sensitive").tag("sensitive")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Strict: only loud speech. Normal: balanced. Sensitive: quiet rooms, picks up more.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Update Frequency") {
                        Picker("", selection: $chunkLengthSeconds) {
                            Text("Auto").tag(0)
                            Text("8s").tag(8)
                            Text("10s").tag(10)
                            Text("15s").tag(15)
                            Text("20s").tag(20)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("How often a new transcript line appears. Auto follows the quality setting.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Strict Confidence") {
                        Toggle("", isOn: $strictConfidence)
                            .labelsHidden()
                            .toggleStyle(.switch)
                        Text("Only output text Whisper is confident about. Reduces errors but may miss some words.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("Auto-Stop") {
                        Picker("", selection: $silenceTimeoutMinutes) {
                            Text("Off").tag(0)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Stops the recording automatically after this much silence.")
                            .font(.system(size: 11)).foregroundColor(theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsDivider

                    settingsRow("AI Prompts") {
                        Picker("", selection: $selectedPromptTab) {
                            Text("Recap").tag(0)
                            Text("Decisions").tag(1)
                            Text("Next Steps").tag(2)
                            Text("Email").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        TextEditor(text: currentPromptBinding)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.ink2)
                            .frame(height: 160)
                            .scrollContentBackground(.hidden)
                            .background(theme.ghost)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))

                        HStack {
                            Spacer()
                            Button("Reset to default") { resetCurrentPrompt() }
                                .font(.system(size: 11))
                                .foregroundColor(theme.faint)
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()

            Divider().background(theme.line)
            VStack(spacing: 6) {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 10))
                    .foregroundColor(theme.faint)
                HStack(spacing: 16) {
                    Button("Privacy Policy") {
                        NSWorkspace.shared.open(URL(string: "https://1hsaved.com/transcribemachine/privacy")!)
                    }
                    Button("Terms of Use") {
                        NSWorkspace.shared.open(URL(string: "https://1hsaved.com/transcribemachine/terms")!)
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(theme.faint)
                .buttonStyle(.plain)
            }
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper.ignoresSafeArea())
        .onAppear { recorder.refreshMicList() }
    }

    private var settingsDivider: some View {
        Divider().background(theme.line2).padding(.horizontal, 26)
    }

    private var currentPromptBinding: Binding<String> {
        switch selectedPromptTab {
        case 1:  return $promptDecisions
        case 2:  return $promptNextSteps
        case 3:  return $promptEmail
        default: return $promptRecap
        }
    }

    private func resetCurrentPrompt() {
        switch selectedPromptTab {
        case 1:  promptDecisions = OllamaService.defaultPromptDecisions
        case 2:  promptNextSteps = OllamaService.defaultPromptNextSteps
        case 3:  promptEmail     = OllamaService.defaultPromptEmail
        default: promptRecap     = OllamaService.defaultPromptRecap
        }
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.faint)
                .textCase(.uppercase)
                .kerning(0.5)
            content()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    // MARK: – Logic

    private func checkSilenceTimeout() {
        guard recorder.isRecording, silenceTimeoutMinutes > 0 else {
            if silenceWarningActive { silenceWarningActive = false }
            return
        }
        let reference = transcriber.lastActivityDate ?? recordingStartDate
        guard let ref = reference else { return }
        let elapsed = Date().timeIntervalSince(ref)
        let limit = Double(silenceTimeoutMinutes) * 60
        if elapsed >= limit {
            silenceWarningActive = false
            stopRecording()
        } else if elapsed >= limit - 60 {
            silenceWarningActive = true
        } else {
            silenceWarningActive = false
        }
    }

    private func stopRecording() {
        recorder.stopAll()
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
        let custom = customInstructions
        let source = recorder.detectedAudioSource
        Task {
            let r = await ollama.run(action: selectedAction, transcript: transcript,
                                     options: options, customInstructions: custom, audioSource: source)
            await MainActor.run { aiResult = r; isProcessingAI = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatElapsed(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func exportTranscript() {
        let text = showingDiarized ? diarizedTranscriptText : transcriber.fullTranscript
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "transcript.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: – Speaker helpers

    private func speakerKey(_ seg: DiarizedSegment) -> String { "\(seg.source)|\(seg.speaker)" }

    private func displayName(_ seg: DiarizedSegment) -> String {
        let key = speakerKey(seg)
        if let name = speakerNames[key] { return name }
        let allKeys = Array(Set(diarizedSegments.map { speakerKey($0) })).sorted()
        let idx = (allKeys.firstIndex(of: key) ?? 0) + 1
        return "Speaker \(idx)"
    }

    private func color(for seg: DiarizedSegment) -> Color {
        let keys = Array(Set(diarizedSegments.map { speakerKey($0) })).sorted()
        let idx = keys.firstIndex(of: speakerKey(seg)) ?? 0
        return speakerColor(idx, theme: theme)
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


struct DownloadConfirmSheet: View {
    let sizeMB: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(Color(hex: 0xB0623F))
            Text("Download AI Model")
                .font(.system(size: 18, weight: .bold))
            Text("TranscribeMachine needs to download a speech recognition model (\(sizeMB) MB) to work. This happens once and requires an internet connection.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Not Now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Download (\(sizeMB) MB)", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 360)
    }
}

// MARK: – Row Views

struct SpeakerBlock: View {
    let theme: PaperTheme
    let label: String
    let color: Color
    let text: String
    let onTapLabel: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(theme.hair).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                if let onTapLabel {
                    Button(action: onTapLabel) {
                        Text(label.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .kerning(1.1)
                            .foregroundColor(color)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(label.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(1.1)
                        .foregroundColor(color)
                }
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundColor(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 14)
        }
    }
}

// MARK: – Shared UI Components

struct SourceRow: View {
    let theme: PaperTheme
    let title: String
    let subtitle: String
    let icon: String
    let tileColor: Color
    let tileTint: Color
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isActive ? tileColor : tileTint)
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(isActive ? .white : tileColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(isDisabled ? theme.faint : theme.ink2)
                    Text(isActive ? "Recording…" : subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(isActive ? tileColor : theme.faint)
                }
                Spacer()
                PaperToggleIndicator(isOn: isActive, accent: tileColor, theme: theme)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

struct PaperToggleIndicator: View {
    let isOn: Bool
    let accent: Color
    let theme: PaperTheme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? accent : theme.toggle)
                .frame(width: 40, height: 23)
            Circle()
                .fill(isOn ? Color.white : theme.knob)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                .padding(2.5)
        }
    }
}

struct BlinkingDot: View {
    let color: Color
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(dim ? 0.3 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct RecordingPulse: View {
    let color: Color
    @State private var pulsing = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
                .scaleEffect(pulsing ? 1.3 : 1.0).opacity(pulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulsing)
            Text("REC").font(.system(size: 10, weight: .bold)).foregroundColor(color.opacity(0.8)).kerning(1.2)
        }
        .onAppear { pulsing = true }
    }
}

struct PermissionBanner: View {
    let theme: PaperTheme
    let message: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundColor(.orange).font(.system(size: 12))
            Text(message)
                .font(.system(size: 11)).foregroundColor(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(buttonLabel, action: action)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
    }
}

struct AIUnavailableNotice: View {
    let theme: PaperTheme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("AI engine not found").font(.system(size: 12, weight: .semibold)).foregroundColor(theme.ink2)
                Text("Please reinstall the app to set up AI features.").font(.system(size: 11)).foregroundColor(theme.faint)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.18), lineWidth: 1))
    }
}

struct PaperActionPillStyle: ButtonStyle {
    let theme: PaperTheme
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? theme.accentInk : theme.muted)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(isSelected ? theme.accent : theme.ghost)
                    .overlay(RoundedRectangle(cornerRadius: 999)
                        .stroke(isSelected ? Color.clear : theme.line, lineWidth: 1))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
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
