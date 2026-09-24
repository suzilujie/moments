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
    /// 实时字幕（非终稿）。两稿分离是设计文档 5.4 的核心：
    /// 这一份会被不断改写，只求当场可读；准确版本由终稿负责。
    @ObservedObject private var live = LiveTranscriber.shared
    @State private var showingSettings = false
    /// 实时字幕未启动时的原因提示（模型未下载等），必须显式给出，不能静默无反应
    @State private var liveHint: String?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if session.snapshot.state.isActive { subtitleSection }
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
        Section {
            row("已录时长", session.snapshot.recordedTimeText)
            row("分片数", "\(session.snapshot.segmentCount)")
            row("落盘耗时", "\(session.snapshot.lastWriteCostMs) ms")
            row("丢弃帧数", "\(session.snapshot.droppedSamples)")

            if session.snapshot.droppedSamples > 0 {
                Text("出现丢弃帧，说明落盘跟不上采集，录音中可能存在空洞——请把这份日志反馈。")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("运行指标")
        } footer: {
            // 这三个数字都会被误读，所以把"怎么看"写在这里：
            Text("「已录时长」按采样计数实时推进（中断期间会停住 —— 那段时间确实没录到，"
                + "漏了多少由上方「断口」如实显示）。"
                + "「分片数」每 \(settings.segmentSeconds) 秒收尾一块，"
                + "因此刚开始录音时它会是 0，这是正常的。"
                + "「丢弃帧数」为 0 表示没有丢音频 —— 这是判断录音是否健康的唯一依据。")
                .font(.footnote)
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
                    Task {
                        await session.start()
                        // 录音真正起来之后再启动字幕：会话若在检查阶段就失败，
                        // 提前启动只会留下一个空转的引擎
                        startLiveTranscriptionIfPossible()
                    }
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

    // MARK: - 实时字幕

    private var subtitleSection: some View {
        Section {
            if !settings.realtimeTranscriptionEnabled {
                Text("实时字幕已在设置中关闭。录音与终稿转写都不受影响 —— 关掉的只是「当场看字」这一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let liveHint {
                VStack(alignment: .leading, spacing: 6) {
                    Text(liveHint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    // 提示里说"可在设置中下载"，而设置入口只是右上角一个齿轮图标 ——
                    // 用户找不到就会停在这里（真机验收时确实卡在这一步）。
                    // 提示因此必须**可操作**：直接给一个能跳过去的按钮，
                    // 而不是让他去猜"设置在哪"。
                    Button {
                        showingSettings = true
                    } label: {
                        Label("去下载模型", systemImage: "arrow.down.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                }
            } else if live.segments.isEmpty {
                Text(live.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(live.segments.suffix(12)) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(segment.timeText)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if segment.isProvisional {
                                Text("识别中")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                        }
                        Text(segment.text)
                            .font(.body)
                            .foregroundStyle(segment.isProvisional ? .secondary : .primary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("实时字幕")
        } footer: {
            Text("实时字幕是「先出、再改对」的：标着「识别中」的句子后续可能被修正，"
                + "这是离线识别的固有特性而非故障。录音与音频不受影响，准确文本以终稿为准。")
                .font(.footnote)
        }
    }

    /// 启动实时字幕（用户已开启且模型已下载时）。
    ///
    /// **不在这里自动下载模型**：模型上百 MB，替用户决定消耗流量是不合适的。
    /// 未下载时给出明确指引，而不是让按钮点下去什么都没发生 ——
    /// 后者是同类 App 最常见的体验缺陷。
    private func startLiveTranscriptionIfPossible() {
        guard session.snapshot.state.isActive else { return }
        guard settings.realtimeTranscriptionEnabled else {
            liveHint = nil
            return
        }
        guard let modelURL = ModelManager.shared.installedURL(for: settings.realtimeModelId) else {
            let name = WhisperModelCatalog.model(id: settings.realtimeModelId)?.displayName
                ?? settings.realtimeModelId
            // 文案必须指明**入口在哪**："可在设置中下载"没有说设置在哪，
            // 而它只是一个右上角的齿轮图标 —— 找不到入口的提示等于没有提示。
            liveHint = "实时字幕未启动：模型「\(name)」尚未下载。"
                + "点下方「去下载模型」，或右上角齿轮（设置）→「模型」区下载。"
                + "下载后下次录音自动启用；录音本身与终稿转写不受影响。"
            return
        }
        liveHint = nil
        live.start(
            modelURL: modelURL,
            language: settings.transcriptionLanguage,
            denoiseEnabled: settings.realtimeDenoiseEnabled
        )
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
