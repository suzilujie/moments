import SwiftUI
// 语言包可用性查询（LanguageAvailability）在这个模块里；
// `.translationTask` 也定义在这里（SessionListView 曾因漏 import 而报
// "some View has no member 'translationTask'"）。
import Translation

/// 录音页。
///
/// ## 一屏三段式（2026-10-17 重设计）
/// 这个 App 是商业应用，录音页只该回答三个问题：
/// **录多久了、它在听什么、怎么停**。因此：
///   · **待机**：居中大圆按钮 = 唯一的视觉重心，下面是"上一次录音"的摘要卡
///   · **识别中**：顶部计时 + 声波带，中间到下面整块给字幕（停止在右上角）
///   · **刚停止**：回到待机，摘要卡贴底
///
/// ## 为什么不再是 List
/// 之前这页是一个 `List` + 分组标题 + 解释性小字 —— 那是**设置页的形状**：
/// 最显眼的元素是 Section 标题，而"正在录"只靠一个 14pt 的圆点表示。
/// 改成固定布局后，信息按重要性从大到小排：计时 > 声波 > 字幕 > 其他。
///
/// ## 工程指标去哪了
/// 分片数 / 落盘耗时 / 丢弃帧数 / 断口从主界面移进「诊断」。
/// **判据没变、呈现方式变了**：正常时界面不出现数字，异常时在计时下方
/// 自动弹一条橙色横幅（见 `alertBanner`）—— 让"出问题"比"看数字"更早被注意到。
/// 这条例外是刻意推翻设计文档 11.2 第 3 条的，理由写在 11.9。
struct RecordView: View {

    // MARK: - 依赖

    @ObservedObject private var session = RecordingSession.shared
    @ObservedObject private var settings = AppSettings.shared
    /// 实时字幕（非终稿）。两稿分离是设计文档 5.4 的核心：
    /// 这一份会被不断改写，只求当场可读；准确版本由终稿负责。
    @ObservedObject private var live = LiveTranscriber.shared
    /// 必须观察：字幕区的提示要能反映"模型正在后台自动下载"及其进度，
    /// 否则首次使用时用户看到的是"尚未下载"，而实际上正在下。
    @ObservedObject private var models = ModelManager.shared
    /// 实时翻译（逐句翻）。与实时字幕是两件事：字幕是本机识别，翻译走系统翻译框架。
    @ObservedObject private var translation = TranslationService.shared

    // MARK: - 界面状态

    @State private var showingSettings = false
    @State private var showingDiagnostics = false
    /// 字幕区是否"贴在底部"。用户主动往上翻看历史时不自动滚 ——
    /// 否则新句子会把他正在看的内容拽走（那会变成新的烦人点）。
    @State private var isSubtitlePinnedToBottom = true
    /// 实时字幕未启动时的原因提示（模型未下载等），必须显式给出，不能静默无反应
    @State private var liveHint: String?
    /// 实时翻译语言包的可用性。
    /// **主动查**：缺语言包 / 正在下载这类状态要出现在字幕下方，
    /// 而等到开始准备才知道缺，中间那段时间他只能干等。
    @State private var livePackStatus: LanguageAvailability.Status?

    // MARK: - 骨架

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if session.snapshot.state.isActive {
                    recordingLayout
                } else {
                    idleLayout
                }
            }
            .animation(.easeInOut(duration: 0.25), value: session.snapshot.state.isActive)
            // 标题留空：待机页在内容里显示「时刻」，录音页上方是计时，
            // 导航栏再写一遍标题只会抢视觉重心。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { sessionId in
                // 会话详情按需加载清单（放在这里而不是算进 body：
                // 在 body 里读磁盘会让每一次刷新都解一遍 manifest.json）
                if let manifest = RecordingLibrary.shared.loadManifest(sessionId: sessionId) {
                    SessionDetailView(manifest: manifest)
                } else {
                    ContentUnavailableView(
                        "找不到这次录音",
                        systemImage: "exclamationmark.triangle",
                        description: Text("会话 \(sessionId) 的清单不存在，可能已被清理。")
                    )
                }
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingDiagnostics) {
                diagnosticsSheet
            }
            // 实时翻译：configuration 非 nil 时这个 translationTask 就开始工作，
            // 并一直跑到 stopLive() 把它置回 nil（见 TranslationService.runLive 的说明）。
            // **session 只能由视图拿到** —— 这是系统框架的约束，不是设计选择。
            .translationTask(translation.liveConfiguration) { session in
                await translation.runLive(with: session)
            }
            // 字幕每出一句就把最新几句交给翻译。
            // 只传后缀而不是整份列表：字幕只增不改内容（成句即定稿），所以最新的
            // 一定是后缀；而一场 8 小时的会话有数千句，每次全扫是白费。
            // 真正的去重由 TranslationService 按 id 完成，这里不承担正确性。
            .onChange(of: live.segments) { translation.enqueueLive(Array(live.segments.suffix(30))) }
            // 「自动判定」模式下要等语言锁定才知道源语言 —— 这一刻才是能启动的时候。
            // 语言锁定后才查得到语言包状态（源语言之前未知），所以这里也要刷一次。
            .onChange(of: live.pinnedLanguage) {
                syncLiveTranslation()
                Task { await refreshLivePackStatus() }
            }
            .task { await refreshLivePackStatus() }
            // 录完就停：否则翻译会话会一直挂着一个 session（切窗引擎已经停了）
            .onChange(of: session.snapshot.state.isActive) {
                if !session.snapshot.state.isActive { translation.stopLive() }
            }
            // 设置里改了目标语言要立刻生效，而不是等下次录音
            .onChange(of: settings.liveTranslationTargetLanguage) {
                syncLiveTranslation()
                Task { await refreshLivePackStatus() }
            }
        }
    }

    // MARK: - 待机

    private var idleLayout: some View {
        VStack(spacing: 0) {
            Text("时刻")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Spacer(minLength: 12)

            startButton

            Text("开始录音")
                .font(.headline)
                .padding(.top, 18)

            Text("点一下即可，锁屏也能录")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // 实时字幕不可用时要在这里说清（模型没下 / 正在下），
            // 否则用户按下开始后会觉得"识别坏了"
            if settings.realtimeTranscriptionEnabled, let hint = subtitleStatusText {
                VStack(spacing: 6) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    OpenModelSettingsButton(title: "去下载模型")
                }
                .padding(.top, 16)
                .padding(.horizontal, 32)
            }

            Spacer(minLength: 12)

            if let error = session.snapshot.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            savedCard
                .padding(.bottom, 8)
        }
    }

    /// 主按钮：128 的浅色圆 + 104 的实心圆 + 麦克风图标。
    ///
    /// 双层圆而不是单层：外层给一点"可按下去"的余地（按下时缩到 0.96），
    /// 单层实心圆在深色背景下会显得很硬。
    private var startButton: some View {
        Button {
            Task {
                await session.start()
                // 录音真正起来之后再启动字幕：会话若在检查阶段就失败，
                // 提前启动只会留下一个空转的引擎
                startLiveTranscriptionIfPossible()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 128, height: 128)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 104, height: 104)
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("开始录音")
    }

    // MARK: - 识别中

    private var recordingLayout: some View {
        VStack(spacing: 0) {
            timerBlock

            WaveformView()
                .padding(.horizontal, 20)
                .padding(.top, 14)

            alertBanner

            liveTranscriptArea
                .padding(.top, 20)
        }
    }

    /// 计时 + 状态。**这一页唯一的 44pt 字号**，其余文字都比它小。
    private var timerBlock: some View {
        VStack(spacing: 6) {
            Text(session.snapshot.recordedTimeText)
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .monospacedDigit()

            HStack(spacing: 6) {
                PulsingDot(color: stateColor)
                Text(stateTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
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

    /// 状态文案：短句。
    ///
    /// 原先每一句都是技术说明（"音频会话被打断（来电 / 其他 App 抢占 / 设备切换），
    /// 正在等待恢复"）。商业应用这里只该给结论，原因留给「诊断」。
    ///
    /// - Note: `.idle` 与 `.failed` 两个分支**在本页走不到** —— `recordingLayout`
    ///   只在 `state.isActive` 为 true 时渲染，而这两个 case 恰好都是 `isActive == false`
    ///   （它们由 `idleLayout` 承载）。保留分支只是因为 `switch` 必须穷尽。
    private var stateTitle: String {
        switch session.snapshot.state {
        case .idle: return "待机"
        case .preparing: return "正在准备"
        case .recording:
            // 不能一律写"识别中"：实时字幕被关掉、或模型还没装时，
            // 这时一个字都不会出，而"识别中"会让用户盯着空白字幕等。
            if !settings.realtimeTranscriptionEnabled { return "录音中（字幕已关闭）" }
            return live.isActive ? "识别中" : "录音中"
        case .interrupted: return "已暂停（来电或设备切换）"
        case .recovering: return "正在恢复"
        case .stopping, .finalizing: return "正在保存"
        case .failed: return "已结束"
        }
    }

    /// 异常横幅：只有"真的出过问题"才出现，点一下进诊断。
    ///
    /// 这是"工程指标移出主界面"的补偿 —— 数字不常驻，但**异常必须自己找上门**。
    /// 若不做这条，界面干净了、问题也被藏了。
    @ViewBuilder
    private var alertBanner: some View {
        if let message = alertMessage {
            Button {
                showingDiagnostics = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text("查看")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    private var alertMessage: String? {
        if let error = session.snapshot.lastError, session.snapshot.state.isActive {
            return error
        }
        if session.snapshot.totalGapMs > 0 {
            return "检测到 \(session.snapshot.gapCount) 处漏录，累计约 \(session.snapshot.totalGapMs / 1000) 秒"
        }
        if session.snapshot.droppedSamples > 0 {
            return "有音频帧被丢弃，录音可能不完整"
        }
        return nil
    }

    /// 字幕区：表头（含语言胶囊）+ 字幕流。
    private var liveTranscriptArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时字幕")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                languagePill
            }
            .padding(.horizontal, 20)

            if !settings.realtimeTranscriptionEnabled {
                Text("实时字幕已在设置中关闭。录音与终稿转写都不受影响 —— 关掉的只是「当场看字」这一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            } else if let hint = subtitleStatusText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    // 提示里说"可下载"，入口就必须就地给出：这枚按钮自带设置弹层，
                    // 不依赖本页恰好有齿轮（会话详情页此前就没有）。
                    OpenModelSettingsButton(title: "去下载模型")
                }
                .padding(.horizontal, 20)
            } else if live.segments.isEmpty {
                Text(live.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                liveSubtitleList

                // 实时翻译的状态**紧贴字幕区下沿**：用户正在看的就是字幕，
                // 状态必须出现在同一个视野里（这一条本项目已经栽过一次）。
                //
                // 刻意放在 ScrollView **之外**：它不随字幕滚动，因此无论用户往上
                // 翻到哪一句，这行提示都还在 —— 若跟着字幕滚，"往上翻着看历史时
                // 正好缺语言包"这件事就又看不见了。
                // 一切正常时返回 nil，不占任何位置。
                if let hint = liveTranslationInlineHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    /// 语言胶囊：把「识别语言」与「实时翻译成」合并成一个入口。
    ///
    /// 原先这是字幕区顶部的两行文字 + 两个省略号菜单，吃掉了约 90pt ——
    /// 而它们决定的是"字幕是什么语言"，属于**设置性信息**，
    /// 不该和字幕本身抢空间。
    private var languagePill: some View {
        Menu {
            Section("识别语言") {
                ForEach(WhisperModelCatalog.languageOptions, id: \.code) { item in
                    Button(item.name) { restartLiveTranscription(language: item.code) }
                }
            }
            Section("实时翻译") {
                Button("关闭") { settings.liveTranslationTargetLanguage = "" }
                ForEach(TranslationLanguageCatalog.all) { language in
                    Button(language.name) { settings.liveTranslationTargetLanguage = language.code }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(languagePillText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.footnote)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }

    /// 胶囊文案：`中文 → 英文` / `自动` / `中文`（翻译关闭时只显示识别语言）。
    ///
    /// 「自动判定」锁定后会变成具体语言 —— 这里直接反映锁定结果，
    /// 因此判错时用户能看出来（而不是只觉得"识别很扯"），并可一键改。
    private var languagePillText: String {
        let sourceCode = live.pinnedLanguage.isEmpty
            ? settings.transcriptionLanguage
            : live.pinnedLanguage
        let sourceName = sourceCode == "auto"
            ? "自动"
            : WhisperModelCatalog.languageName(sourceCode)

        let target = settings.liveTranslationTargetLanguage
        guard !target.isEmpty else { return sourceName }
        return "\(sourceName) → \(TranslationLanguageCatalog.name(for: target))"
    }

    // MARK: - 已保存（贴底）

    /// 刚结束的那一次录音留下了什么。
    ///
    /// ## 为什么必须说一句"已保存"
    /// 停止录音后若直接回到空闲态，**没有任何"录到了什么、存在哪"的反馈** ——
    /// 用户只知道在录、不知道录完在哪看。
    /// 这里把三件产物压成一行说清（时长 · 识别 · 译文），并给出进详情的入口。
    ///
    /// 只在"有过一次录音"时出现：`sessionId` 在开始录音时写入、
    /// 直到下次开始才重置，因此它可以当"上一次录音"的标识用。
    @ViewBuilder
    private var savedCard: some View {
        if let sessionId = session.snapshot.sessionId,
           !session.snapshot.state.isActive,
           session.snapshot.recordedMs > 0 {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                    Text("已保存")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(savedSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Button("诊断") { showingDiagnostics = true }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)

                    Spacer()

                    NavigationLink(value: sessionId) {
                        HStack(spacing: 2) {
                            Text("查看记录")
                                .font(.footnote.weight(.medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.tint)
                    }
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
        }
    }

    private var savedSummaryText: String {
        var parts = [session.snapshot.recordedTimeText]
        parts.append("\(live.lastSessionSegmentCount) 句")
        if translation.lastSessionTranslatedCount > 0 {
            parts.append("\(translation.lastSessionTranslatedCount) 句译文")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 历史入口：原先它是底部第二个 Tab（「记录」），用户确认不需要那个 Tab，
        // 于是把「历史 + 全局检索」降级为这里的一个按钮。
        //
        // **这个入口不能省掉**：会话详情页（回听 / 双语稿 / 终稿转写 / 导出）
        // 只能从历史列表进 —— 本页摘要卡里的「查看记录」只对**刚录完的那一次**有效，
        // App 重启后 snapshot 里没有 sessionId，历史就再也打不开了。
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink {
                SessionListView()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("历史记录")
        }

        if session.snapshot.state.isActive {
            // 识别中：只留「停止」。设置齿轮在这一态收起 ——
            // 录音时改设置本来就不该做，而停止是这一屏唯一需要的动作。
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    session.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .disabled(
                    session.snapshot.state == .stopping
                        || session.snapshot.state == .finalizing
                )
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
    }

    // MARK: - 诊断

    /// 诊断面板：原先直接铺在主界面上的那些数字，全部搬到这里。
    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                Section {
                    row("已录时长", session.snapshot.recordedTimeText)
                    row("分片数", "\(session.snapshot.segmentCount)")
                    row("落盘耗时", "\(session.snapshot.lastWriteCostMs) ms")
                    row("丢弃帧数", "\(session.snapshot.droppedSamples)")
                } header: {
                    Text("运行指标")
                } footer: {
                    Text("「已录时长」按采样计数推进，中断期间会停住（那段时间确实没录到）。"
                        + "「分片数」每 \(settings.segmentSeconds) 秒收尾一块，刚开始录音时是 0 属正常。"
                        + "「丢弃帧数」为 0 表示没有丢音频。")
                        .font(.footnote)
                }

                if session.snapshot.totalGapMs > 0 {
                    Section {
                        row("断口处数", "\(session.snapshot.gapCount)")
                        row("累计时长", "\(session.snapshot.totalGapMs / 1000) 秒")
                    } header: {
                        Text("断口（漏录）")
                    } footer: {
                        Text("断口是真实发生过的漏录（来电、其他 App 抢占、设备切换）。"
                            + "本项目如实标注，而不是把时间轴补齐后假装连续。")
                            .font(.footnote)
                    }
                }

                Section {
                    row("录音模式", settings.captureSource.title)
                    row("音频会话", settings.sessionMode.title)
                    row("识别语言", settings.transcriptionLanguage == "auto"
                        ? "自动判定"
                        : WhisperModelCatalog.languageName(settings.transcriptionLanguage))
                    row("实时模型",
                        WhisperModelCatalog.model(id: settings.realtimeModelId)?.displayName
                            ?? settings.realtimeModelId)
                } header: {
                    Text("录音配置")
                }

                if let error = session.snapshot.lastError {
                    Section("最近一次错误") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingDiagnostics = false }
                }
            }
        }
    }

    // MARK: - 字幕

    /// 实时字幕列表：**自动吸底**。
    ///
    /// 吸底策略是"**只在你本来就在底部时才自动滚**"：用户主动往上翻看历史时，
    /// 新句子不该把他拽回底部。判据用 `onScrollGeometryChange`（iOS 18 起可用），
    /// 阈值给 40 点余量 —— 手指离开后还有惯性在滚，判得太紧会在临界处抖。
    ///
    /// 与上一版不同：不再固定 280pt 高度。录音时底部没有按钮了，
    /// 字幕可以一直铺到屏幕底部，能多看到两三句。
    private var liveSubtitleList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(live.segments) { segment in
                        liveSegmentRow(segment)
                            .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y
                    - geometry.containerSize.height < 40
            } action: { _, atBottom in
                isSubtitlePinnedToBottom = atBottom
            }
            .onChange(of: live.segments.count) {
                guard isSubtitlePinnedToBottom, let last = live.segments.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 一句实时字幕：最新一句 19pt 主色，历史句 16pt 次级。
    ///
    /// 用字号而不是背景色区分"最新"：字幕是一段连续的话，
    /// 给最新一句加底色会把阅读流切断，看起来像一条条通知。
    private func liveSegmentRow(_ segment: TranscriptSegment) -> some View {
        let isLatest = segment.id == live.segments.last?.id

        return VStack(alignment: .leading, spacing: 4) {
            Text(segment.timeText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Text(segment.text)
                .font(.system(size: isLatest ? 19 : 16))
                .foregroundStyle(isLatest ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            // 译文贴在原文下方。**没有译文就不显示任何占位** ——
            // 占位符会让"还没翻到"看起来像"翻译坏了"。
            if let translated = translation.liveTranslations[segment.id] {
                Text(translated)
                    .font(.system(size: isLatest ? 15 : 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 业务动作（以下逻辑与上一版一致，只换了外层壳）

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
            // **这里刻意一个字都不写**：模型相关的提示（尚未下载 / 正在下载及其进度 /
            // 下载完成后提示自动消失）统一由 `subtitleStatusText` 动态计算。
            //
            // 曾经在这里写死一句"尚未下载"，后果是：用户在本次录音中途把模型下完了，
            // 界面却一直说没下 —— 因为 `liveHint` 是静态值，而它在
            // `subtitleStatusText` 里排在动态判断**之前**直接短路返回。
            // 同一件事有两个状态源，就一定会有说错话的那一天。
            liveHint = nil
            return
        }
        // 会话已建立（上面已确认 state.isActive），因此 sessionId 必然存在；
        // 取不到就说明状态机与本页不同步 —— 此时宁可不启动字幕，
        // 也不要启动一个"识别结果不知道存到哪一次录音"的字幕。
        guard let sessionId = session.snapshot.sessionId else {
            liveHint = "会话 id 尚未就绪，实时字幕未启动。"
            return
        }
        liveHint = nil
        live.start(
            sessionId: sessionId,
            modelId: settings.realtimeModelId,
            modelURL: modelURL,
            language: settings.transcriptionLanguage,
            denoiseEnabled: settings.realtimeDenoiseEnabled
        )
        // 识别语言若是明确指定的，这一刻就知道源语言，可以立刻开始翻；
        // 若是「自动判定」，则要等锁定（见 syncLiveTranslation 的说明）。
        syncLiveTranslation()
    }

    /// 切换识别语言并**立即重启字幕引擎**（不必停止录音）。
    ///
    /// 同时写回设置：用户在录音中改语言就是他真实的偏好，
    /// 下次不该又回到"自动判定"再错一遍。
    private func restartLiveTranscription(language: String) {
        settings.transcriptionLanguage = language
        guard live.isActive,
              let sessionId = session.snapshot.sessionId,
              let modelURL = ModelManager.shared.installedURL(for: settings.realtimeModelId)
        else { return }
        // 传同一个 sessionId：引擎据此知道"这是同一场录音的重启"，
        // 于是**不清空留档累计** —— 切识别语言不该把已识别的内容从落盘里抹掉。
        live.start(
            sessionId: sessionId,
            modelId: settings.realtimeModelId,
            modelURL: modelURL,
            language: language,
            denoiseEnabled: settings.realtimeDenoiseEnabled
        )
        // 改成明确语言后源语言立刻可知，实时翻译该跟着重启（若在等锁定的话）
        syncLiveTranslation()
    }

    private var targetLanguageName: String {
        TranslationLanguageCatalog.name(for: settings.liveTranslationTargetLanguage)
    }

    /// 实时翻译的状态提示，**显示在字幕（源语）下方**。
    ///
    /// 用户明确要求把「缺少语言包 / 正在下载」这类状态放在这里 ——
    /// 而不是藏在设置里：他正在看的就是字幕，状态必须出现在同一个视野里。
    /// **一切正常时返回 nil**（不显示任何东西）：正常状态下多一行字只是噪音。
    private var liveTranslationInlineHint: String? {
        guard !settings.liveTranslationTargetLanguage.isEmpty else { return nil }

        // 失败原因最需要被看到，优先
        if let message = translation.liveMessage { return message }

        switch translation.liveStage {
        case .preparing:
            return "正在准备「\(targetLanguageName)」语言包（首次使用需要联网下载一次）…"
        case .translating:
            return nil        // 正常工作中，什么都不说
        default:
            break
        }

        guard session.snapshot.state.isActive else { return nil }

        // 还没启动：多半是缺语言包，或在等识别语言锁定
        switch livePackStatus {
        case .supported:
            return "缺少「\(targetLanguageName)」语言包 —— 首次使用需要联网下载一次，"
                + "翻译开始时系统会提示下载。想省掉这次等待，"
                + "可在设置 →「语言」里提前准备好。"
        case .unsupported:
            return "系统不支持「当前语言 → \(targetLanguageName)」这对语言，实时翻译无法进行。"
        default:
            break
        }

        if translation.liveConfiguration == nil {
            return "实时翻译将在识别语言锁定后开始…"
        }
        return nil
    }

    /// 查一次实时翻译语言包的状态。
    ///
    /// 源语言取"当前**实际**会用的那个"（已锁定优先，否则设置里指定的），
    /// 与 `syncLiveTranslation` 用**同一判据** —— 两处不一致会出现
    /// "说缺语言包、其实是源语言不对"这类自相矛盾。
    private func refreshLivePackStatus() async {
        let target = settings.liveTranslationTargetLanguage
        guard !target.isEmpty else {
            livePackStatus = nil
            return
        }
        let sourceCode = live.pinnedLanguage.isEmpty
            ? settings.transcriptionLanguage
            : live.pinnedLanguage
        guard sourceCode != "auto",
              let source = TranslationLanguageCatalog.identifier(forWhisperCode: sourceCode),
              source != target
        else {
            livePackStatus = nil
            return
        }
        livePackStatus = await translation.availability(from: source, to: target)
    }

    /// 启动 / 停止实时翻译。
    ///
    /// ## 一处真实的不兼容（必须说清，否则会被当成 bug）
    /// 系统翻译**不支持"源语言自动判定"**，而识别侧默认就是「自动判定」——
    /// 所以这条路径下只能**等**：等首个出字把识别语言锁定，才知道要翻的是什么语言。
    /// 等多久取决于用户说第一句话的时间。
    /// 若希望一开始就能翻，把识别语言设成具体语言即可（语言胶囊里可改）。
    private func syncLiveTranslation() {
        let target = settings.liveTranslationTargetLanguage
        guard !target.isEmpty else {
            translation.stopLive()
            return
        }
        guard session.snapshot.state.isActive else { return }

        let sourceCode = live.pinnedLanguage.isEmpty
            ? settings.transcriptionLanguage
            : live.pinnedLanguage
        guard sourceCode != "auto",
              let source = TranslationLanguageCatalog.identifier(forWhisperCode: sourceCode)
        else { return }

        // 实时译文要落盘（见 TranslationService.persistLiveTranslations），
        // 而它需要知道"这是哪一次录音的译文"
        guard let sessionId = session.snapshot.sessionId else { return }

        // 语言对变了必须重启：不重启就会把新语言的句子按旧语言的假设去翻。
        //（自动判定锁定后源语言会变化，那是正常路径，不是异常。）
        // 注意 stopLive() 会**先把已经翻好的译文落盘**再清内存，
        // 因此换目标语言不会把上一门语言的译文丢掉。
        if let running = translation.livePair, running.source != source || running.target != target {
            translation.stopLive()
        }
        translation.startLive(source: source, target: target, sessionId: sessionId)
        // 追上已经出过的句子
        translation.enqueueLive(live.segments)
    }

    /// 实时字幕区的状态说明。
    ///
    /// ## 唯一的权威来源是"模型现在到底在不在"
    /// 全部文案都在这里**现算**，不存快照：判断依据永远是
    /// `ModelManager.installedURL` 与当前的下载进度，因此
    /// 「尚未下载 → 正在下载（带进度）→ 提示自动消失」是一条连续状态，
    /// 用户在本次录音中途把模型下完，界面会立刻跟上。
    ///
    /// ## `liveHint` 只剩下一个用途
    /// 表示**无法从模型状态推导**的原因（目前只有"会话 id 尚未就绪"）。
    /// 模型类提示绝不能再写进 `liveHint` —— 那是静态值，会压在这段动态判断
    /// 前面短路返回，把"下完了"说成"没下"。
    private var subtitleStatusText: String? {
        if let liveHint { return liveHint }

        let modelId = settings.realtimeModelId
        guard ModelManager.shared.installedURL(for: modelId) == nil else { return nil }

        let name = WhisperModelCatalog.model(id: modelId)?.displayName ?? modelId
        if let progress = models.states[modelId]?.progress {
            return "模型「\(name)」正在下载：\(progress.summary)。"
                + "下载完成后，下次开始录音会自动启用实时字幕。"
        }
        // 入口必须写出来：它只是一个右上角的齿轮图标，说"可在设置中下载"
        // 而不说设置在哪，等于没有提示。
        return "模型「\(name)」尚未下载。点「去下载模型」，或右上角齿轮（设置）→「模型」区下载；"
            + "下载后下次录音自动启用。录音本身与终稿转写不受影响。"
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

// MARK: - 子视图

/// 实时声波带：32 根柱，跟随输入电平。
///
/// ## 为什么只观察 `AudioLevelMonitor`
/// 电平每 100 ms 变一次。若让录音页整体（`RecordingSession`）承载这个值，
/// 整页每秒会重绘 10 次 —— 而除这 32 根柱子之外没有任何东西在变，
/// 字幕区还在同时重排布局，叠加起来就是滚动掉帧。
/// 把"观察电平"收进这个小视图，重绘范围就只有它自己。
///
/// ## 波形为什么是"真的"
/// 数据来自 `CapturePipeline` 在后台消费队列上算出的均方根电平，
/// 不是在放动画：静音时它必须落成一条细线。
/// 一条"不说话也在动"的波形会让人以为它在瞎动，比没有波形更糟。
///
/// ## 颜色为什么是绿而不是红
/// 这个 App 里红色已经专属于"出错 / 正在停止"（异常横幅、停止按钮）。
/// 录音中再拿红色画波峰，会被读成"一直在报警"。
/// 用绿色与计时旁边那颗状态点同色，含义就统一成"正常工作"。
private struct WaveformView: View {

    @ObservedObject private var meter = AudioLevelMonitor.shared

    /// 32 个历史电平（越靠右越新）。每来一个新值就整体左移一格，
    /// 视觉上表现为波峰自右向左流动。
    ///
    /// 注意 `ForEach` 用下标作 id（位置固定），所以动画效果是"每根柱子
    /// 插值到左邻的旧高度"，而不是真正的横向位移 —— 观感近似滚动，成本低得多。
    @State private var levels = [CGFloat](repeating: 0, count: WaveformView.barCount)

    private static let barCount = 32
    private let maxHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.green.opacity(0.65))
                    .frame(width: 3, height: barHeight(levels[index]))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: maxHeight)
        // 两端淡出：整排柱子在左右边缘硬切会显得像进度条
        .mask(
            LinearGradient(
                colors: [.clear, .black, .black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .onChange(of: meter.level) { _, newValue in
            levels.removeFirst()
            levels.append(CGFloat(newValue))
        }
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }

    /// 最矮留 3pt：静音时是一排细线，而不是空白（空白会被当成"没在收音"）。
    private func barHeight(_ level: CGFloat) -> CGFloat {
        max(3, level * maxHeight)
    }
}

/// 状态点：缓慢呼吸，表示"还在工作"。
///
/// 只用在状态行（录音中 / 恢复中）。它不承载信息 ——
/// 真正的信息是旁边的文字与颜色，所以它对辅助功能隐藏。
private struct PulsingDot: View {

    let color: Color

    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    RecordView()
}
