import SwiftUI
// 语言包可用性查询（LanguageAvailability）在这个模块里；
// `.translationTask` 也定义在这里（SessionListView 曾因漏 import 而报
// "some View has no member 'translationTask'"）。
import Translation

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
    /// 必须观察：实时字幕区的提示要能反映"模型正在后台自动下载"及其进度，
    /// 否则首次使用时用户看到的是"尚未下载"，而实际上正在下。
    @ObservedObject private var models = ModelManager.shared
    /// 实时翻译（逐句翻）。与实时字幕是两件事：字幕是本机识别，翻译走系统翻译框架。
    @ObservedObject private var translation = TranslationService.shared
    @State private var showingSettings = false
    /// 实时字幕未启动时的原因提示（模型未下载等），必须显式给出，不能静默无反应
    @State private var liveHint: String?
    /// 实时翻译语言包的可用性。
    /// **主动查**：用户要求"缺语言包 / 正在下载"这类状态出现在字幕下方，
    /// 而等到开始准备才知道缺，中间那段时间他只能干等。
    @State private var livePackStatus: LanguageAvailability.Status?

    var body: some View {
        NavigationStack {
            List {
                statusSection
                // 正在自动准备模型时也要显示字幕区：用户需要知道"还在准备什么"，
                // 而不是打开 App 看到一片空白、以为功能坏了
                if session.snapshot.state.isActive || isPreparingModel { subtitleSection }
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
            // 设置里（或本页菜单里）改了目标语言要立刻生效，而不是等下次录音
            .onChange(of: settings.liveTranslationTargetLanguage) {
                syncLiveTranslation()
                Task { await refreshLivePackStatus() }
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
            liveLanguageRow
            // 实时翻译：**始终显示**，未开启时也要出现（理由见 liveTranslationRow 的说明）
            liveTranslationRow

            if !settings.realtimeTranscriptionEnabled {
                Text("实时字幕已在设置中关闭。录音与终稿转写都不受影响 —— 关掉的只是「当场看字」这一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let hint = subtitleStatusText {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    // 提示里说"可在设置中下载"，而设置入口只是右上角一枚齿轮 ——
                    // 用户找不到就会停在这里（真机验收时确实卡在这一步）。
                    // 入口统一走 OpenModelSettingsButton：它自带设置页弹层，
                    // 不依赖本页恰好有齿轮（会话详情页此前就没有）。
                    OpenModelSettingsButton(title: "去下载模型")
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
                        // 实时译文贴在原文下方。**没有译文就不显示任何占位** ——
                        // 占位符会让"还没翻到"看起来像"翻译坏了"。
                        if let translated = translation.liveTranslations[segment.id] {
                            Text(translated)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                // 实时翻译的状态**贴在源语下方**（用户明确要求的位置）。
                // 理由：用户正在看的就是字幕，状态必须出现在同一个视野里 ——
                // 藏在设置里等于没有（这一条本项目已经栽过一次）。
                // 一切正常时返回 nil，不显示任何东西。
                if let hint = liveTranslationInlineHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
        } header: {
            Text("实时字幕")
        } footer: {
            // 这段文案随 VAD 切窗一起改过：原先写的是「先出、再改对」，
            // 而现在切点由 VAD 决定、一句话说完才识别，文字出现即定稿。
            // 文案不跟着改的话，它本身就在误导用户。
            Text("字幕**成句即定稿**：切点由 VAD 决定，一句话说完才送去识别，"
                + "所以文字一旦出现就不会再变。录音与音频不受影响，"
                + "最准确的文本仍以终稿为准。"
                + "「实时翻译」开启后，每句的译文会显示在原文下方（双行）。")
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
            // 模型正在后台自动下载时**不写死**"尚未下载"：那会把动态的下载进度
            // 盖掉，用户看到的是"没下载"，而实际上正在下。
            if models.states[settings.realtimeModelId]?.isDownloading ?? false {
                liveHint = nil
            } else {
                let name = WhisperModelCatalog.model(id: settings.realtimeModelId)?.displayName
                    ?? settings.realtimeModelId
                // 文案必须指明**入口在哪**："可在设置中下载"没有说设置在哪，
                // 而它只是一个右上角的齿轮图标 —— 找不到入口的提示等于没有提示。
                liveHint = "实时字幕未启动：模型「\(name)」尚未下载。"
                    + "点下方「去下载模型」，或右上角齿轮（设置）→「模型」区下载。"
                    + "下载后下次录音自动启用；录音本身与终稿转写不受影响。"
            }
            return
        }
        liveHint = nil
        live.start(
            modelURL: modelURL,
            language: settings.transcriptionLanguage,
            denoiseEnabled: settings.realtimeDenoiseEnabled
        )
        // 识别语言若是明确指定的，这一刻就知道源语言，可以立刻开始翻；
        // 若是「自动判定」，则要等锁定（见 syncLiveTranslation 的说明）。
        syncLiveTranslation()
    }

    /// 识别语言：显示当前**实际**用的语言，并允许一键更改。
    ///
    /// ## 为什么这个入口是必需的，不是锦上添花
    /// 「自动判定」会被**锁定**（见 `LiveTranscriptionEngine.pinLanguageIfNeeded`）——
    /// 这是为了消灭"每个窗口重新判一次、结果来回跳"（真机反馈：
    /// 「实时识别有的扯淡，出现各种语言」）。但锁定意味着**判错一次就会错一整场**，
    /// 所以必须有可见、可改的出路：
    ///   · 显示锁定结果 → 判错时用户能看出来（而不是只觉得"识别很扯"）
    ///   · 一键改语言 → 不必停止录音，立刻重启字幕引擎
    private var liveLanguageRow: some View {
        HStack(spacing: 8) {
            Text("识别语言")
                .foregroundStyle(.secondary)

            Spacer()

            if live.isActive, !live.pinnedLanguage.isEmpty {
                Text("已锁定 \(WhisperModelCatalog.languageName(live.pinnedLanguage))")
                    .foregroundStyle(.green)
            } else {
                Text(settings.transcriptionLanguage == "auto"
                    ? "自动判定（首个出字窗口后锁定）"
                    : WhisperModelCatalog.languageName(settings.transcriptionLanguage))
            }

            Menu {
                ForEach(WhisperModelCatalog.languageOptions, id: \.code) { item in
                    Button(item.name) { restartLiveTranscription(language: item.code) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(!live.isActive)
        }
        .font(.footnote)
    }

    /// 切换识别语言并**立即重启字幕引擎**（不必停止录音）。
    ///
    /// 同时写回设置：用户在录音中改语言就是他真实的偏好，
    /// 下次不该又回到"自动判定"再错一遍。
    private func restartLiveTranscription(language: String) {
        settings.transcriptionLanguage = language
        guard live.isActive,
              let modelURL = ModelManager.shared.installedURL(for: settings.realtimeModelId)
        else { return }
        live.start(
            modelURL: modelURL,
            language: language,
            denoiseEnabled: settings.realtimeDenoiseEnabled
        )
        // 改成明确语言后源语言立刻可知，实时翻译该跟着重启（若在等锁定的话）
        syncLiveTranslation()
    }

    /// 实时翻译：状态 + 语言选择入口。**始终显示**。
    ///
    /// ## 为什么它必须始终显示（真机教训，我自己的设计缺陷）
    /// 这一项默认关闭 —— 理由是语言包必须先装好，否则用户会在**录音刚开始那一刻**
    /// 撞上系统下载界面。这个理由本身没错。
    /// 但我最初只在**开启之后**才显示这一行，于是用户根本不知道有这个功能：
    /// 真机反馈原话是「没看到双语，只看到源语」。
    /// **一个默认关闭的功能，必须在它被需要的地方留下可见的入口**——
    /// "不打断用户"和"用户不知道它存在"是两回事，我当时只处理了前者。
    ///
    /// 入口放在这里还有一层好处：录音时想换语言不必再进设置（与「识别语言」同理）。
    private var liveTranslationRow: some View {
        HStack(spacing: 8) {
            Text("实时翻译")
                .foregroundStyle(.secondary)

            Spacer()

            Text(liveTranslationStatusText)
                .foregroundStyle(liveTranslationStatusColor)
                .multilineTextAlignment(.trailing)

            Menu {
                Button("关闭") { settings.liveTranslationTargetLanguage = "" }
                ForEach(TranslationLanguageCatalog.all) { language in
                    Button(language.name) { settings.liveTranslationTargetLanguage = language.code }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.footnote)
    }

    /// 实时翻译那行的状态。**它同时就是排查入口**：卡在哪一关，这一行直接说出来，
    /// 而不是让用户盯着没有译文的界面猜。
    private var liveTranslationStatusText: String {
        guard !settings.liveTranslationTargetLanguage.isEmpty else {
            return "未开启（点右侧选语言）"
        }
        if let message = translation.liveMessage { return message }
        if translation.liveConfiguration != nil {
            return "\(targetLanguageName)｜已翻 \(translation.liveTranslatedCount) 句"
        }
        if session.snapshot.state.isActive {
            // 自动判定尚未锁定：这时**确实还不能翻**（系统翻译不支持源语言自动判定）
            return "\(targetLanguageName)｜等识别语言锁定…"
        }
        return "\(targetLanguageName)｜录音时生效"
    }

    private var liveTranslationStatusColor: Color {
        if settings.liveTranslationTargetLanguage.isEmpty { return .secondary }
        if translation.liveMessage != nil { return .orange }
        if translation.liveConfiguration != nil { return .green }
        return .secondary
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
    /// 若希望一开始就能翻，把识别语言设成具体语言即可（本页那行的菜单里可改）。
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

        // 语言对变了必须重启：不重启就会把新语言的句子按旧语言的假设去翻。
        //（自动判定锁定后源语言会变化，那是正常路径，不是异常。）
        if let running = translation.livePair, running.source != source || running.target != target {
            translation.stopLive()
        }
        translation.startLive(source: source, target: target)
        // 追上已经出过的句子
        translation.enqueueLive(live.segments)
    }

    /// 实时字幕区的状态说明。
    ///
    /// `liveHint` 是**开始录音那一刻算一次的静态文本**，它无法反映
    /// "模型正在后台自动下载" —— 于是首次使用时用户会看到"尚未下载"，
    /// 而实际上正在下。这里改为动态计算：在下载就显示进度，
    /// 下载完成后提示自动消失（下一句就不该再提这件事）。
    private var subtitleStatusText: String? {
        if let liveHint { return liveHint }

        let modelId = settings.realtimeModelId
        guard ModelManager.shared.installedURL(for: modelId) == nil else { return nil }

        let name = WhisperModelCatalog.model(id: modelId)?.displayName ?? modelId
        if let progress = models.states[modelId]?.progress {
            return "模型「\(name)」正在下载：\(progress.summary)。"
                + "下载完成后，下次开始录音会自动启用实时字幕。"
        }
        return "模型「\(name)」尚未下载。"
    }

    /// 是否正在准备模型（未录音时也要显示字幕区，让"还在准备"可见）。
    private var isPreparingModel: Bool {
        models.states[settings.realtimeModelId]?.isDownloading ?? false
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
