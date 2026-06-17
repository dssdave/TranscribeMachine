import SwiftUI
import UniformTypeIdentifiers

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
    @State private var isProcessingAI = false
    @State private var selectedAction: AIAction = .recap
    @State private var options = AIOptions()
    @State private var copiedTranscript = false
    @State private var copiedAI = false
    @State private var customInstructions = ""

    @AppStorage("silenceTimeoutMinutes") private var silenceTimeoutMinutes: Int = 10
    @AppStorage("whisperModelQuality") private var whisperModelQuality: String = "fast"

    @State private var showSettings = false
    @State private var diarizedSegments: [DiarizedSegment] = []
    @State private var speakerNames: [String: String] = [:]
    @State private var renamingKey: String?
    @State private var renameText = ""
    @State private var recordingStartDate: Date?
    @State private var elapsedSeconds = 0
    @State private var silenceWarningActive = false
    @State private var silenceTick = 0

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                    VStack(spacing: 16) {
                        recordButtons
                        if !isReady { setupBanner }
                        if hasContent || recorder.isRecording { transcriptSection }
                        if hasContent && !recorder.isRecording { aiSection }
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                }
            }

            if renamingKey != nil { renameOverlay }
            if showSettings    { settingsOverlay }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            recorder.transcriptionEngine = transcriber
            recorder.refreshMicList()
            transcriber.prepareModel()
            whisperX.installIfNeeded()
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
    }

    // MARK: – Header

    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("TranscribeMachine")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text("Local · Private · Offline")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.3))
            }
            Spacer()
            statusIndicator
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings = true }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundColor(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    @ViewBuilder var statusIndicator: some View {
        if whisperX.setupState == .installing || whisperX.isRunning
            || ollama.state == .starting || ollama.state == .downloading {
            HStack(spacing: 7) {
                ProgressView().scaleEffect(0.6)
                Text(currentStatusLabel)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        } else if isReady && ollama.state == .ready {
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
        if transcriber.isDownloading { return "Setting up transcriptionu2026" }
        if whisperX.setupState == .installing { return "Setting up…" }
        if whisperX.isRunning { return whisperX.progress.isEmpty ? "Analyzing…" : whisperX.progress }
        if ollama.state == .downloading { return ollama.downloadProgress }
        if ollama.state == .starting { return "Starting AI…" }
        return ""
    }

    var setupBanner: some View {
        HStack(spacing: 10) {
            if transcriber.modelStatus == "Download failed" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text("Transcription setup failed — please check your internet connection and relaunch.")
                    .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6))
            } else {
                ProgressView().scaleEffect(0.7)
                Text("Setting up transcription engine (one-time download, may take a minute)…")
                    .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: – Record Buttons

    var recordButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RecordButton(
                    title: "Microphone", subtitle: "In-room", icon: "mic.fill",
                    accentColor: speakerPalette[0], isActive: recorder.micActive, isDisabled: !isReady
                ) { recorder.toggleMic() }

                RecordButton(
                    title: "Computer Audio", subtitle: "Zoom / Meet / Remote", icon: "speaker.wave.2.fill",
                    accentColor: speakerPalette[1], isActive: recorder.systemActive, isDisabled: !isReady
                ) { recorder.toggleSystemAudio() }
            }

            if recorder.micPermissionDenied {
                PermissionBanner(
                    message: "Microphone access denied. Open System Settings → Privacy & Security → Microphone and enable TranscribeMachine.",
                    buttonLabel: "Open Settings",
                    action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                )
            }

            if recorder.screenRecordingPermissionDenied {
                PermissionBanner(
                    message: "Screen Recording access required for Computer Audio. Open System Settings → Privacy & Security → Screen Recording and enable TranscribeMachine.",
                    buttonLabel: "Open Settings",
                    action: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                )
            }

            if recorder.isRecording {
                Button { stopRecording() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle.fill")
                        Text("Stop")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(StopButtonStyle())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if silenceWarningActive {
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
        }
        .animation(.easeInOut(duration: 0.2), value: recorder.isRecording)
        .animation(.easeInOut(duration: 0.2), value: silenceWarningActive)
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
                if showingDiarized { speakerCountBadge }
                Spacer()
                if recorder.isRecording {
                    RecordingPulse()
                    Text(formatElapsed(elapsedSeconds))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                }
                tinyButton(icon: copiedTranscript ? "checkmark" : "doc.on.doc",
                           label: copiedTranscript ? "Copied" : "Copy") {
                    copy(showingDiarized ? diarizedTranscriptText : transcriber.fullTranscript)
                    copiedTranscript = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedTranscript = false }
                }
                tinyButton(icon: "square.and.arrow.up", label: "Export") { exportTranscript() }
                tinyButton(icon: "trash", label: "Clear") {
                    transcriber.clear(); diarizedSegments = []; aiResult = nil
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if showingDiarized {
                            ForEach(diarizedSegments) { seg in
                                DiarizedRow(seg: seg, name: displayName(seg), color: color(for: seg)) {
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
                .frame(minHeight: 56, maxHeight: 140)
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
        VStack(alignment: .leading, spacing: 14) {

            // Four tap-to-run action buttons
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
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(ActionButtonStyle(
                        isSelected: selectedAction == action && aiResult != nil && !isProcessingAI
                    ))
                    .disabled(isProcessingAI || ollama.state != .ready)
                }
            }

            // Custom instructions field
            TextField("Optional: e.g. keep it brief · formal tone · focus on tech decisions · write to a client",
                      text: $customInstructions)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.65))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))

            if ollama.state == .unavailable { AIUnavailableNotice() }

            if let result = aiResult {
                VStack(alignment: .leading, spacing: 12) {

                    // Main output text
                    ScrollView {
                        Text(result.main)
                            .font(.system(size: 14))
                            .foregroundColor(Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 56, maxHeight: 168)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1))

                    // Follow-ups — clean arrow list, no checkboxes or green card
                    if !result.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Follow-ups")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.35))
                                .textCase(.uppercase)
                                .kerning(0.8)
                            ForEach(result.actionItems) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("→")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.white.opacity(0.25))
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.task)
                                            .font(.system(size: 13))
                                            .foregroundColor(Color.white.opacity(0.85))
                                            .textSelection(.enabled)
                                        let meta = [
                                            item.owner != "Unknown" ? item.owner : nil,
                                            item.due   != "Not specified" ? item.due : nil
                                        ].compactMap { $0 }.joined(separator: " · ")
                                        if !meta.isEmpty {
                                            Text(meta)
                                                .font(.system(size: 11))
                                                .foregroundColor(Color.white.opacity(0.35))
                                        }
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    HStack {
                        Spacer()
                        Button {
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

    // MARK: – Settings overlay (tap outside to dismiss)

    var settingsOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { showSettings = false }
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showSettings = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(Color.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Microphone")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                    Picker("", selection: $recorder.selectedMicID) {
                        ForEach(recorder.availableMics, id: \.uniqueID) { dev in
                            Text(dev.localizedName).tag(dev.uniqueID)
                        }
                    }
                    .labelsHidden()
                    .disabled(recorder.micActive)
                    if recorder.micActive {
                        Text("Stop recording to change mic")
                            .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                    }
                }

                Divider().background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcription Quality")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                    Picker("", selection: $whisperModelQuality) {
                        Text("Fast").tag("fast")
                        Text("Balanced").tag("balanced")
                        Text("Quality").tag("quality")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Fast: small model, ~8s updates. Balanced: ~15s. Quality: large model, ~30s — best accuracy. Takes effect on next launch.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }

                Divider().background(Color.white.opacity(0.1))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-Stop")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
                    Picker("", selection: $silenceTimeoutMinutes) {
                        Text("Never").tag(0)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Recording stops if no audio is detected for this long.")
                        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.3))
                }

                Spacer()

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.2))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(18)
            .frame(width: 300, height: 410)
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.5), radius: 40)
            .onAppear { recorder.refreshMicList() }
        }
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
            Image(systemName: seg.speaker.icon)
                .font(.system(size: 8))
                .foregroundColor(seg.speaker.color)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(seg.speaker.color.opacity(0.12))
                .clipShape(Capsule())
                .frame(width: 26, alignment: .center)

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

struct RecordButton: View {
    let title: String; let subtitle: String; let icon: String
    let accentColor: Color; let isActive: Bool; let isDisabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if isActive {
                        Circle().fill(accentColor.opacity(0.18)).frame(width: 56, height: 56)
                            .scaleEffect(hovering ? 1.08 : 1.0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isActive)
                    }
                    Circle().fill(isActive ? accentColor : accentColor.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: icon).font(.system(size: 18, weight: .medium))
                        .foregroundColor(isActive ? .white : accentColor.opacity(0.7))
                }
                VStack(spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isDisabled ? Color.white.opacity(0.2) : Color.white.opacity(isActive ? 1 : 0.8))
                    Text(isActive ? "Recording…" : subtitle).font(.system(size: 10))
                        .foregroundColor(isActive ? accentColor : Color.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? accentColor.opacity(0.1) : Color.white.opacity(hovering ? 0.05 : 0.03))
                    .overlay(RoundedRectangle(cornerRadius: 12)
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

struct PermissionBanner: View {
    let message: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundColor(.orange).font(.system(size: 12))
            Text(message)
                .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.7))
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
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("AI engine not found").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.white.opacity(0.8))
                Text("Please reinstall the app to set up AI features.").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.18), lineWidth: 1))
    }
}

struct ActionButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.white.opacity(0.14)
                          : Color.white.opacity(configuration.isPressed ? 0.09 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.09), lineWidth: 1))
            )
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

private func tinyButton(icon: String, label: String, action: @escaping @MainActor () -> Void) -> some View {
    Button { action() } label: {
        Label(label, systemImage: icon).font(.system(size: 11))
    }
    .buttonStyle(.plain)
    .foregroundColor(Color.white.opacity(0.35))
}
