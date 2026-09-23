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
    @Environment(\.dismiss) private var dismiss

    private var sessionDirectory: URL {
        RecordingLibrary.shared.sessionDirectory(manifest.id)
    }

    var body: some View {
        List {
            overviewSection
            if manifest.hasGap { gapSection }
            if let note = manifest.note { noteSection(note) }
            segmentsSection
            deleteSection
        }
        .navigationTitle(manifest.title)
        .navigationBarTitleDisplayMode(.inline)
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
