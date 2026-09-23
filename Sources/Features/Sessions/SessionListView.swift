import AVFoundation
import SwiftUI

/// 记录列表：按时间浏览所有录音。
struct SessionListView: View {

    @State private var sessions: [SessionManifest] = []
    @State private var totalBytes: Int = 0

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "还没有录音",
                        systemImage: "waveform",
                        description: Text("到「录音」标签页点开始，录到的内容会出现在这里。")
                    )
                } else {
                    Section {
                        ForEach(sessions, id: \.id) { item in
                            NavigationLink {
                                SessionDetailView(manifest: item)
                            } label: {
                                SessionRow(manifest: item)
                            }
                        }
                        .onDelete(perform: delete)
                    } footer: {
                        Text("共 \(sessions.count) 次录音，占用 \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))")
                    }
                }
            }
            .navigationTitle("记录")
            .onAppear(perform: reload)
            .refreshable { reload() }
        }
    }

    private func reload() {
        sessions = RecordingLibrary.shared.listSessions()
        totalBytes = sessions.reduce(0) { $0 + $1.totalBytes }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let item = sessions[index]
            try? RecordingLibrary.shared.deleteSession(item.id)
        }
        reload()
    }
}

/// 列表行。
private struct SessionRow: View {
    let manifest: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localTimeText)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(manifest.durationText())
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label("\(manifest.segments.count) 片", systemImage: "square.stack.3d.up")
                Label(manifest.sizeText, systemImage: "internaldrive")
                if manifest.hasGap {
                    Label("断口 \(manifest.totalGapMs / 1000)s", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if manifest.state != .done {
                    Text(manifest.state == .recording ? "录制中" : "异常结束")
                        .foregroundStyle(manifest.state == .recording ? .green : .red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 时间一律换算为**用户本地时区**展示（项目既有约定）
    private var localTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: manifest.startedAt)
    }
}

/// 会话详情：元数据、断口、分片播放。
struct SessionDetailView: View {

    let manifest: SessionManifest
    @StateObject private var player = SessionAudioPlayer()
    @ObservedObject private var asr = TranscriptionService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var transcript: TranscriptDocument?
    @State private var selectedPass: TranscriptPass = .final

    private var sessionDirectory: URL {
        RecordingLibrary.shared.sessionDirectory(manifest.id)
    }

    var body: some View {
        List {
            transcriptSection
            overviewSection
            if manifest.hasGap { gapSection }
            if let note = manifest.note { noteSection(note) }
            segmentsSection
            deleteSection
        }
        .navigationTitle(manifest.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { initializePass() }
        .onChange(of: selectedPass) { reloadTranscript() }
        .onChange(of: asr.stage) { reloadTranscript() }
        .onDisappear { player.stop() }
    }

    private var overviewSection: some View {
        Section("概要") {
            row("开始时间", fullLocalTime)
            if let ended = manifest.endedAtMs {
                row("结束时间", fullLocalTime(of: ended))
            }
            row("已录时长（按样本）", manifest.durationText())
            row("墙钟时长", wallClockText)
            row("原生采样率", manifest.nativeSampleRate > 0
                ? "\(Int(manifest.nativeSampleRate)) Hz"
                : "未记录")
            row("分片时长设定", "\(manifest.segmentSeconds) 秒")
            row("保存码率", "\(manifest.bitRate / 1000) kbps")
            row("体积", manifest.sizeText)

            if manifest.totalGapMs > 0 {
                Text("录音有效时长 \(manifest.durationText())，墙钟跨度 \(wallClockText)。两者不同是正常的，差值即中断造成的漏录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var gapSection: some View {
        Section("断口（漏录）") {
            ForEach(gapRows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.subheadline)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func noteSection(_ note: String) -> some View {
        Section("备注") {
            Text(note)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private var segmentsSection: some View {
        Section("分片") {
            if manifest.segments.isEmpty {
                Text("没有分片记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(segmentRows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.subheadline)
                            .monospacedDigit()
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        toggle(row.segment)
                    } label: {
                        Image(systemName: player.playingSegment == row.fileName
                            ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.exists)
                }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                try? RecordingLibrary.shared.deleteSession(manifest.id)
                dismiss()
            } label: {
                Text("删除这次录音")
            }
        } footer: {
            Text("将同时删除音频分片与这份记录，不可恢复。")
        }
    }

    // MARK: - 文字稿（M2）

    private var transcriptSection: some View {
        Section {
            if asr.runningSessionId == manifest.id {
                transcribingView
            } else if let transcript, !transcript.isEmpty {
                passPicker
                ForEach(transcriptRows) { row in
                    Button {
                        playSegment(containingMs: row.startMs)
                    } label: {
                        transcriptRowView(row)
                    }
                    .buttonStyle(.plain)
                }
                if let note = transcript.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                emptyTranscriptView
            }
        } header: {
            HStack {
                Text("文字稿")
                Spacer()
                if let transcript {
                    Text("\(transcript.characterCount) 字｜\(transcript.modelId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(transcriptFooterText)
        }
    }

    private var passPicker: some View {
        Picker("版本", selection: $selectedPass) {
            ForEach(TranscriptPass.allCases, id: \.self) { pass in
                Text(pass.title).tag(pass)
            }
        }
        .pickerStyle(.segmented)
    }

    private var transcribingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(asr.stage.text)
                .font(.subheadline)
                .bold()
            ProgressView(value: asr.progress)
                .progressViewStyle(.linear)
            Text("已处理 \(asr.processedSegments) / \(asr.totalSegments) 个分片")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("转写在本机离线进行，可以随时取消；已转部分会保留，之后可继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消转写", role: .destructive) {
                asr.cancel()
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private var emptyTranscriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyTranscriptHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("转写为文字") {
                asr.transcribe(sessionId: manifest.id, pass: .final)
            }
            .disabled(!hasAnyAudio)
        }
        .padding(.vertical, 2)
    }

    private var emptyTranscriptHint: String {
        guard hasAnyAudio else {
            return "音频已按保留期清理，无法再生成文字稿。文字稿只能对尚存的音频生成。"
        }
        let modelId = AppSettings.shared.finalModelId
        if ModelManager.shared.installedURL(for: modelId) == nil {
            let name = WhisperModelCatalog.model(id: modelId)?.displayName ?? modelId
            return "终稿模型「\(name)」尚未下载，请先到「设置 → 模型」下载。"
        }
        return "尚未转写。全程在本机离线完成，音频不会离开设备。"
    }

    private var transcriptFooterText: String {
        "点句子可播放它所在的那一段音频。"
            + "M2 只能定位到所属分片（约 1 分钟），精确到句内位置属 M4。"
            + "实时稿是「先出、再改对」的，准确文本以终稿为准。"
    }

    private var hasAnyAudio: Bool {
        manifest.segments.contains { fileExists($0) }
    }

    private struct TranscriptRow: Identifiable {
        let id: String
        let startMs: Int
        let timeText: String
        let text: String
        let isProvisional: Bool
    }

    private var transcriptRows: [TranscriptRow] {
        guard let transcript else { return [] }
        return transcript.segments.map { segment in
            TranscriptRow(
                id: segment.id,
                startMs: segment.startMs,
                timeText: segment.timeText,
                text: segment.text,
                isProvisional: segment.isProvisional
            )
        }
    }

    /// 单句渲染。用方法而不是独立 struct：
    /// `TranscriptRow` 是本类型的私有嵌套类型，文件作用域的独立视图无法引用它。
    @ViewBuilder
    private func transcriptRowView(_ row: TranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.timeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if row.isProvisional {
                    Text("识别中")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Image(systemName: "play.circle")
                    .foregroundStyle(.tint)
            }
            Text(row.text)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 2)
    }

    /// 点句回听：先定位到**包含该句的分片**再播放。
    ///
    /// 为什么只做到分片级：精确到句内偏移需要给 AVAudioPlayer 设置 currentTime 并
    /// 与样本计数推导出的时间轴对齐，属 M4「点句回听」的正式范围。
    /// 现在先给出"能听到那句话所在的这一段"，比做一个不精确的跳转更诚实。
    private func playSegment(containingMs ms: Int) {
        guard let entry = manifest.segments.last(where: { $0.startMs <= ms }) else { return }
        let url = RecordingLibrary.shared.segmentURL(sessionId: manifest.id, fileName: entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        player.play(url: url, segmentName: entry.fileName)
    }

    private func initializePass() {
        if TranscriptStore.shared.exists(sessionId: manifest.id, pass: .final) {
            selectedPass = .final
        } else if TranscriptStore.shared.exists(sessionId: manifest.id, pass: .live) {
            selectedPass = .live
        }
        reloadTranscript()
    }

    private func reloadTranscript() {
        transcript = TranscriptStore.shared.load(sessionId: manifest.id, pass: selectedPass)
    }

    // MARK: - 播放

    private func toggle(_ segment: SessionManifest.SegmentEntry) {
        let url = RecordingLibrary.shared.segmentURL(sessionId: manifest.id, fileName: segment.fileName)
        if player.playingSegment == segment.fileName {
            player.stop()
        } else {
            player.play(url: url, segmentName: segment.fileName)
        }
    }

    private func fileExists(_ segment: SessionManifest.SegmentEntry) -> Bool {
        FileManager.default.fileExists(
            atPath: RecordingLibrary.shared
                .segmentURL(sessionId: manifest.id, fileName: segment.fileName).path
        )
    }

    // MARK: - 文本

    private var fullLocalTime: String { fullLocalTime(of: manifest.startedAtMs) }

    private func fullLocalTime(of ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }

    private var wallClockText: String {
        let seconds = manifest.wallClockMs / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private func msText(_ ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%02d:%02d.%01d", seconds / 60, seconds % 60, (ms % 1000) / 100)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - 行数据（把重表达式拆成预计算字符串，避免 SwiftUI 类型检查超时）

    private struct GapRow: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    private struct SegmentRow: Identifiable {
        let id: Int
        let fileName: String
        let segment: SessionManifest.SegmentEntry
        let title: String
        let detail: String
        let exists: Bool
    }

    private var gapRows: [GapRow] {
        manifest.gaps.enumerated().map { index, gap in
            GapRow(
                id: index,
                title: "第 \(index + 1) 处｜\(msText(gap.startMs)) → \(msText(gap.endMs))",
                detail: "时长 \(gap.durationMs / 1000) 秒｜原因：\(gap.reason)"
            )
        }
    }

    private var segmentRows: [SegmentRow] {
        manifest.segments.map { segment in
            SegmentRow(
                id: segment.seq,
                fileName: segment.fileName,
                segment: segment,
                title: "#\(segment.seq)　\(msText(segment.startMs)) → \(msText(segment.endMs))",
                detail: "\(byteText(segment.bytes))｜样本 \(segment.sampleCount)",
                exists: fileExists(segment)
            )
        }
    }

    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// 分片播放器。M1 只做"逐片播放"，连续回放与点句回听属 M4。
@MainActor
final class SessionAudioPlayer: ObservableObject {

    @Published private(set) var playingSegment: String?
    private var player: AVAudioPlayer?

    func play(url: URL, segmentName: String) {
        stop()
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            playingSegment = segmentName
            Log.shared.info(.storage, "开始播放分片 \(segmentName)")
        } catch {
            Log.shared.error(.storage, "播放失败｜\(segmentName)｜\(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingSegment = nil
    }
}
