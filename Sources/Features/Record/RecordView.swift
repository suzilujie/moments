import SwiftUI

/// 录音页（M1 主界面）。
///
/// 三条界面原则来自设计文档 11.2：
///   1. **状态必须一眼可辨**：正在录 / 已中断 / 已降档 / 有断口，四种情况要能立刻分清
///   2. **不假装连续**：断口必须显示出来，而不是让用户以为全程都录到了
///   3. **关键数字要可见**：已录时长、分片数、落盘耗时、丢弃帧数 —— 这些是判断
///      "录音是否健康"的唯一依据，藏起来等于没有
struct RecordView: View {

    @ObservedObject private var session = RecordingSession.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                metricsSection
                if session.snapshot.totalGapMs > 0 { gapSection }
                if let error = session.snapshot.lastError { errorSection(error) }
                controlSection
            }
            .navigationTitle("时刻")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.snapshot.state.title)
                        .font(.title3)
                        .bold()
                    Text(stateHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.snapshot.recordedTimeText)
                    .font(.system(.title2, design: .monospaced))
                    .bold()
            }
            .padding(.vertical, 4)
        }
    }

    private var stateColor: Color {
        switch session.snapshot.state {
        case .recording: return .green
        case .interrupted, .recovering: return .orange
        case .failed: return .red
        case .preparing, .stopping, .finalizing: return .blue
        case .idle: return .secondary
        }
    }

    private var stateHint: String {
        switch session.snapshot.state {
        case .idle:
            return "点下方按钮开始。开始后可锁屏，录音会继续。"
        case .preparing:
            return "正在检查权限、磁盘与会话…"
        case .recording:
            return "正在录音。锁屏、切到其他 App 都不会中断。"
        case .interrupted:
            return "音频会话被打断（来电 / 其他 App 抢占 / 设备切换），正在等待恢复"
        case .recovering:
            return "正在重建采集引擎…"
        case .stopping, .finalizing:
            return "正在收尾，请勿关闭 App"
        case .failed:
            return "录音已停止，已录内容已保留"
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        Section("运行指标") {
            row("已录时长", session.snapshot.recordedTimeText)
            row("分片数", "\(session.snapshot.segmentCount)")
            row("落盘耗时", "\(session.snapshot.lastWriteCostMs) ms")
            row("丢弃帧数", "\(session.snapshot.droppedSamples)")

            if session.snapshot.droppedSamples > 0 {
                Text("出现丢弃帧，说明落盘跟不上采集，录音中可能存在空洞——请把这份日志反馈。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("丢弃帧数为 0 表示没有丢音频。这是判断录音是否健康的唯一依据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 断口

    private var gapSection: some View {
        Section("断口（漏录）") {
            row("断口处数", "\(session.snapshot.gapCount)")
            row("累计时长", "\(session.snapshot.totalGapMs / 1000) 秒")
            Text("断口是真实发生过的漏录（来电、其他 App 抢占、设备切换等）。"
                + "本项目选择如实标注，而不是把时间轴补齐后假装连续。")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section("提示") {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    // MARK: - 控制

    private var controlSection: some View {
        Section {
            if session.snapshot.state.isActive {
                Button(role: .destructive) {
                    session.stop()
                } label: {
                    HStack {
                        Spacer()
                        Text("停止录音").bold()
                        Spacer()
                    }
                }
                .disabled(session.snapshot.state == .stopping || session.snapshot.state == .finalizing)
            } else {
                Button {
                    Task { await session.start() }
                } label: {
                    HStack {
                        Spacer()
                        Text("开始录音").bold()
                        Spacer()
                    }
                }
            }
        } footer: {
            Text("当前模式：\(settings.captureSource.title)｜音频会话：\(settings.sessionMode.title)")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

#Preview {
    RecordView()
}
