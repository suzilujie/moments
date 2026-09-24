import SwiftUI

/// M0 自检页。
///
/// 这一页不是为了好看，而是为了在「无断点调试器」的前提下，把后续必然会用到
/// 的前提一次性验证掉：plist 声明是否真的生效、麦克风权限能否拿到、音频会话
/// 能否激活、原生采集格式与音频事件能否收到（设计文档 4.14）。
///
/// 原则：**关键状态必须在设备上直接可见，而不是靠猜。**
struct RootView: View {

    @StateObject private var model = SelfCheckModel()
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            List {
                buildSection
                environmentSection
                permissionSection
                sessionSection
                systemSection
                eventSection
                asrSection
                logSection
            }
            .navigationTitle("自检")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("日志") { showingLogs = true }
                }
            }
            .sheet(isPresented: $showingLogs) {
                LogView()
            }
        }
        .task { await model.refresh() }
    }

    // MARK: - 构建指纹

    private var buildSection: some View {
        Section("构建") {
            row("版本", "\(AppInfo.version) (\(AppInfo.build))")
            row("提交", BuildInfo.commit)
            row("构建时间", BuildInfo.builtAt)
        }
    }

    // MARK: - 运行环境与 plist 声明

    private var environmentSection: some View {
        Section("运行环境") {
            row("设备", "\(AppInfo.deviceModel) / iOS \(AppInfo.systemVersion)")
            row("Bundle ID", AppInfo.bundleID)
            row("后台模式", AppInfo.backgroundModes.isEmpty
                ? "（空）"
                : AppInfo.backgroundModes.joined(separator: ", "))

            if AppInfo.hasAudioBackgroundMode {
                note("后台音频模式已声明 —— 锁屏后录音不被挂起的前提已具备", color: .secondary)
            } else {
                note("后台音频模式缺失 —— 锁屏后录音会被挂起，请检查 Resources/Info.plist", color: .red)
            }
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section("麦克风权限") {
            row("当前状态", model.permissionText)
            row("用途说明", AppInfo.microphoneUsageDescription)

            Button("申请录音权限") {
                Task { await model.requestPermission() }
            }
            .disabled(model.permissionText == "已授权")
        }
    }

    // MARK: - 音频会话

    private var sessionSection: some View {
        Section("音频会话") {
            Picker("会话模式", selection: $model.mode) {
                ForEach(AudioSessionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            note(model.mode.detail, color: .secondary)

            row("会话状态", model.sessionText)
            row("原生采集格式", model.inputFormatText)

            HStack {
                Button("激活会话") { model.activateSession() }
                Spacer()
                Button("释放会话") { model.releaseSession() }
                    .foregroundStyle(.secondary)
            }

            Button("记录一次音频上下文") { model.logContext() }
        }
    }

    // MARK: - 系统状态

    private var systemSection: some View {
        Section("系统状态") {
            note(model.systemStateText, color: .secondary)
            Button("记录一次状态快照") { model.logSnapshot() }
            Button("检查磁盘余量") { model.checkDisk() }
        }
    }

    // MARK: - 音频事件监听

    private var eventSection: some View {
        Section("音频事件监听") {
            row("监听状态", model.observerText)
            row("已收到事件数", "\(model.eventCount)")
            note(
                "已监听：会话中断 / 路由变更 / 媒体服务重置 / 媒体服务丢失 / 音频图配置变更。"
                    + "其中「音频图配置变更」不报错却会让音频静默中断，是 M1 最需要确认的一类。",
                color: .secondary
            )
        }
    }

    // MARK: - 离线引擎（M2 转写 / M3 语音处理）

    private var asrSection: some View {
        Section("离线引擎（M2 / M3）") {
            row("whisper 后端", model.whisperBackend)
            row("sherpa-onnx", model.sherpaVersion)
            row("内置模型（M3）", model.bundledModelsText)
            row("已安装模型", model.installedModelsText)
            row("模型占用", model.modelBytesText)
            row("转写覆盖率", model.coverageText)
            row("已转写字数", model.characterCountText)
            row("说话人覆盖率", model.diarizationCoverageText)
            row("声纹库", model.voiceprintText)
            row("检索索引", model.searchIndexText)
            row("翻译（M5）", model.translationText)
            row("生词（M6）", model.vocabularyText)
            row("朗读语音（M6）", model.speechText)

            if let message = TranscriptionService.shared.lastMessage {
                note(message, color: .secondary)
            }

            note(
                "「whisper 后端」与「sherpa-onnx」非空即证明两个第三方静态库都已真正链接"
                    + "（而不是编译通过的空壳）—— 这是集成类里程碑最硬的验收依据。"
                    + "转写覆盖率 = 已有文字稿的会话数 / 总会话数。",
                color: .secondary
            )

            Button("刷新引擎信息") { model.refreshASR() }

            Button("检索自检（在内存库跑真实 SQL）") { model.runSearchSelfTest() }
            ForEach(Array(model.searchSelfTestLines.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.caption)
                    .foregroundStyle(colorForSelfTestLine(item.element))
            }
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("日志") {
            row("内存条数", "\(model.logCount)")
            row("落盘文件", model.logFilePath)
            row("文件大小", model.logFileSize)
            row("已写入行数", "\(model.logLines)")

            if let error = model.logFileError {
                note("落盘异常：\(error)（已降级为仅内存日志）", color: .orange)
            } else {
                note("日志同时写入内存、磁盘与系统日志；App 被系统杀掉后仍可从文件取证。", color: .secondary)
            }

            Button("查看日志 / 导出") { showingLogs = true }
        }
    }

    // MARK: - 小组件

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    /// 自检输出行的颜色：✓ 通过、✗ 失败、其余为说明。
    ///
    /// 用颜色而不是图标来区分，是因为自检结果里既有"通过"也有"跳过"，
    /// 一眼扫过去要能立刻看出有没有红字。
    private func colorForSelfTestLine(_ line: String) -> Color {
        if line.hasPrefix("✗") { return .red }
        if line.hasPrefix("✓") { return .green }
        return .secondary
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
    }
}

/// 自检页的状态与动作。
///
/// 刻意不做成「页面直接调 AudioSessionManager」，是因为 M1 之后录音内核会变成
/// 一个状态机（设计文档 4.7），UI 只能作为观察者。现在就把这层分开，
/// 后面替换内核时 UI 不需要重写。
@MainActor
final class SelfCheckModel: ObservableObject {

    @Published var permissionText = "读取中…"
    @Published var sessionText = "尚未配置"
    @Published var inputFormatText = "未读取"
    @Published var systemStateText = "-"
    @Published var observerText = "-"
    @Published var eventCount = 0
    @Published var logCount = 0
    @Published var logFilePath = "-"
    @Published var logFileSize = "-"
    @Published var logLines = 0
    @Published var logFileError: String?
    @Published var mode: AudioSessionMode = .coexistent

    // M2 转写
    @Published var whisperBackend = "-"
    /// M3 语音处理（sherpa-onnx）—— 版本号能取到即证明静态库已链接
    @Published var sherpaVersion = "-"
    /// M3 内置模型（VAD / 降噪 / 说话人分割 / 声纹）的齐备情况
    @Published var bundledModelsText = "-"
    /// M3c：说话人覆盖率（已分离的会话数 / 总会话数）
    @Published var diarizationCoverageText = "-"
    /// M3c：声纹库里已录入的人数
    @Published var voiceprintText = "-"
    /// M4：检索索引能力与规模
    @Published var searchIndexText = "-"
    /// M4：检索自检的逐行结果
    @Published var searchSelfTestLines: [String] = []
    /// M5：翻译引擎与译文缓存规模
    @Published var translationText = "-"
    /// M6：词频表状态与生词本规模
    @Published var vocabularyText = "-"
    /// M6：系统 TTS 的可用语音规模（语言学习依赖语音包，而"有没有装"只能在设备上看）
    @Published var speechText = "-"
    @Published var installedModelsText = "-"
    @Published var modelBytesText = "-"
    @Published var coverageText = "-"
    @Published var characterCountText = "-"

    private let audio = AudioSessionManager.shared

    func refresh() async {
        permissionText = audio.permissionDescription()
        sessionText = audio.lastResult
        refreshDiagnostics()
        refreshASR()
        if permissionText == "已授权" {
            inputFormatText = audio.nativeInputFormat()
        }
    }

    /// 刷新转写相关信息。
    ///
    /// 其中 `WhisperEngine.systemInfo` 是 M2a 的**验收依据**：
    /// 它调用的是 whisper.cpp 的 C 接口，能返回后端信息就说明
    /// CI 构建的静态 xcframework 确实被链接进来了 ——
    /// 这比"编译通过"强得多（编译通过也可能只是没引用而已）。
    func refreshASR() {
        whisperBackend = WhisperEngine.systemInfo
        sherpaVersion = SherpaOnnxEngine.summary
        bundledModelsText = SherpaBundledModel.summary

        let diarizationCoverage = SpeakerTimelineStore.shared.coverage()
        diarizationCoverageText = "\(diarizationCoverage.analyzed) / \(diarizationCoverage.total)"
        voiceprintText = "\(SpeakerProfileStore.shared.profiles.count) 人"

        let search = SearchIndex.shared
        searchIndexText = "\(search.capability.title)｜\(search.indexedSessions) 会话 / \(search.indexedSegments) 句"

        let translationCoverage = TranslationStore.shared.coverage()
        let entryCount = TranslationStore.shared.totalEntryCount()
        translationText = "\(TranslationService.engineIdentifier)@\(TranslationService.engineVersion)"
            + "｜已翻 \(translationCoverage.translated)/\(translationCoverage.total) 次会话"
            + "｜\(entryCount) 条译文"

        // 词频表是懒加载的，这里主动触发一次，好让"是否可用"如实显示 ——
        // 生词判定失效时界面不能表现为"这段材料没有生词"
        WordFrequencyTable.shared.loadIfNeeded()
        vocabularyText = "词频表 \(WordFrequencyTable.shared.availability.text)"
            + "｜水平档 \(AppSettings.shared.vocabularyLevel.title)"
            + "｜生词本 \(VocabularyStore.shared.summary())"
        speechText = SpeechReader.availableVoicesSummary()

        let installed = ModelManager.shared.installedModels
        installedModelsText = installed.isEmpty
            ? "（无）"
            : installed.map { $0.displayName }.joined(separator: "、")
        modelBytesText = ByteCountFormatter.string(
            fromByteCount: ModelManager.shared.installedBytes,
            countStyle: .file
        )

        let coverage = TranscriptStore.shared.coverage()
        coverageText = "\(coverage.transcribed) / \(coverage.total)"
        characterCountText = "\(TranscriptStore.shared.totalCharacterCount())"
    }

    /// 运行检索自检。
    ///
    /// 这一步不能省：本项目的 CI 只能验证「能编译、能链接」，
    /// **运行期 SQL 错误它一条都抓不到**（跑不了 iOS App）。
    /// schema 写错、FTS5 建不起来、参数绑定错 —— 都不会让构建失败，
    /// 只会在用户点下搜索时安静地什么也不返回。
    /// 自检用内存库跑**与正式代码同一套语句**，逐条报告结果。
    func runSearchSelfTest() {
        let lines = SearchIndex.shared.selfTest()
        searchSelfTestLines = lines
        Log.shared.info(.storage, "检索自检执行｜\(lines.joined(separator: " ／ "))")
    }

    func requestPermission() async {
        let granted = await audio.requestPermission()
        permissionText = audio.permissionDescription()
        Log.shared.info(.session, "权限申请完成｜结果=\(granted ? "已授权" : "被拒绝")")
        if granted {
            inputFormatText = audio.logInputFormat()
        }
        refreshDiagnostics()
    }

    func activateSession() {
        audio.activate(mode)
        sessionText = audio.lastResult
        if permissionText == "已授权" {
            inputFormatText = audio.nativeInputFormat()
        }
        refreshDiagnostics()
    }

    func releaseSession() {
        audio.deactivate()
        sessionText = audio.lastResult
        refreshDiagnostics()
    }

    func logContext() {
        Log.shared.info(.session, "手动记录音频上下文｜\(audio.contextText())")
        refreshDiagnostics()
    }

    func logSnapshot() {
        SystemStateMonitor.shared.logSnapshot("自检页手动触发")
        refreshDiagnostics()
    }

    func checkDisk() {
        SystemStateMonitor.shared.checkDisk(reason: "自检页手动触发")
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        systemStateText = SystemStateMonitor.shared.snapshotText()
        eventCount = AudioEventObserver.shared.eventCount
        observerText = AudioEventObserver.shared.isStarted ? "已注册" : "未注册"

        let log = Log.shared
        logCount = log.snapshot().count
        logFilePath = log.filePathText
        logFileSize = log.fileSizeText
        logLines = log.fileWrittenLines
        logFileError = log.fileErrorText
    }
}

#Preview {
    RootView()
}
