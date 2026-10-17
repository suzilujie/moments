import SwiftUI
// 必须 import：`.translationTask` 与 `LanguageAvailability` 都定义在 Translation 模块里，
// 不 import 会报 "value of type 'some View' has no member 'translationTask'"
// —— 这与"框架没链接"无关，纯粹是模块可见性问题（SessionListView 已踩过一次）。
import Translation

/// 设置页。
///
/// 按用户确认的原则：**未定选项由实现方定合理默认值，并做成运行时可改**。
/// 这里暴露的每一项都对应设计文档里一个"待真机标定"的参数 ——
/// 做成可调之后，真机调试就不必每次改代码再重装。
struct SettingsView: View {

    /// 作为 sheet 弹出时（`OpenModelSettingsButton`「去下载模型」）需要「完成」按钮关闭；
    /// 作为底部 Tab 时不需要（Tab 无关闭语义，此时 `dismiss` 也是 no-op）。
    var showsCloseButton: Bool = false

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var translation = TranslationService.shared
    @ObservedObject private var correction = CorrectionService.shared
    @Environment(\.dismiss) private var dismiss
    /// 实时翻译语言包的可用性。
    ///
    /// **存枚举，不存文案**：界面要判"是否已就绪"，若靠字符串相等，
    /// 改一次文案就静默失效（本项目已因这类比较吃过亏 —— 见 cut reason 处同一取舍）。
    @State private var livePackStatus: LanguageAvailability.Status?
    /// 特殊情况说明（源语言与目标语言相同），此时没有可查的语言对
    @State private var livePackNote: String?

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                storageSection
                transcriptionSection
                modelSection
                bundledModelSection
                languageSection
                exportSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
            }
            .task { await refreshLivePackStatus() }
            .onChange(of: settings.liveTranslationTargetLanguage) {
                Task { await refreshLivePackStatus() }
            }
            .onChange(of: settings.defaultSourceLanguage) {
                Task { await refreshLivePackStatus() }
            }
            // 语言包准备：与录音页的实时翻译用**不同的 configuration**，互不干扰
            //（一个 configuration 对应一个 session，共用会互相抢）。
            // 它**不主动置回 nil**：置回会让 SwiftUI 取消正在跑的 task，
            // 而这里的 task 本来就短、且离开设置页时修饰器消失、会话自然释放。
            .translationTask(translation.prepareConfiguration) { session in
                await translation.runPrepare(with: session)
            }
        }
    }

    /// 查询实时翻译语言包的状态。
    ///
    /// 源语言用设置里的「默认源语言」估算：识别侧锁定后的结果最终会映射到**同一个**
    /// 标识符（whisper 的 zh → zh-Hans，见 TranslationLanguageCatalog.identifier），
    /// 所以这里查出来的可用性与录音时一致。
    private func refreshLivePackStatus() async {
        livePackStatus = nil
        livePackNote = nil

        let target = settings.liveTranslationTargetLanguage
        guard !target.isEmpty else { return }

        let source = settings.defaultSourceLanguage
        guard source != target else {
            livePackNote = "源语言与目标语言相同，无需语言包（但也不会翻译）"
            return
        }
        livePackStatus = await translation.availability(from: source, to: target)
    }

    /// 语言包是否已就绪（用枚举判断，不用文案）
    private var isLivePackReady: Bool { livePackStatus == .installed }

    private var livePackStatusText: String {
        if let livePackNote { return livePackNote }
        guard let livePackStatus else { return "查询中…" }
        return TranslationService.describe(livePackStatus)
    }

    private var captureSection: some View {
        Section("采集") {
            Picker("音频会话模式", selection: $settings.sessionMode) {
                ForEach(AudioSessionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(settings.sessionMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("分片时长", selection: $settings.segmentSeconds) {
                Text("30 秒").tag(30)
                Text("60 秒").tag(60)
                Text("120 秒").tag(120)
            }

            Picker("落盘码率", selection: $settings.bitRate) {
                Text("32 kbps（约 14 MB/小时）").tag(32_000)
                Text("48 kbps（约 21 MB/小时）").tag(48_000)
                Text("64 kbps（更保真）").tag(64_000)
            }

            Picker("单次录制上限", selection: $settings.maxSessionHours) {
                Text("2 小时").tag(2)
                Text("6 小时").tag(6)
                Text("12 小时").tag(12)
                Text("不限制").tag(0)
            }
        }
    }

    private var storageSection: some View {
        Section("存储") {
            Picker("音频保留", selection: $settings.retentionDays) {
                Text("3 天").tag(3)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("永久保留").tag(0)
            }
            Text("转写文字永久保留；音频到期后自动删除。删除音频不会删除文字与记录。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("磁盘下限")
                Spacer()
                Text(String(format: "%.0f GB", settings.minFreeDiskGB))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.minFreeDiskGB, in: 0.5...5.0, step: 0.5)
            Text("剩余空间低于该值时自动停止录音，保护已录内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 转写

    private var transcriptionSection: some View {
        Section {
            Toggle("实时字幕", isOn: $settings.realtimeTranscriptionEnabled)
            Text("录音时当场显示文字。关掉它只是省电 —— 录音与终稿转写都不受影响。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("实时字幕使用降噪音频", isOn: $settings.realtimeDenoiseEnabled)
            Text("默认关。降噪会引入失真伪影，有可能反而让识别更差 —— "
                + "因此它是「可对照验证的选项」，不是默认增强。"
                + "录音的原始音频始终保留，随时可关掉重来。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("LLM 纠错（识别后先纠正再翻译）", isOn: $settings.llmCorrectionEnabled)
            Text("用本地 Qwen2.5-0.5B 模型纠正同音字 / 识别错误，再用纠正后的文字翻译。"
                + "需另下载纠错模型（约 \(LlamaModel.sizeText)）。"
                + "关闭或未下载时自动退回「原文直翻」。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("识别语言", selection: $settings.transcriptionLanguage) {
                ForEach(SenseVoiceModel.languageOptions, id: \.code) { item in
                    Text(item.name).tag(item.code)
                }
            }
            Text("「自动判定」（默认）由模型自己判断语言。它的代价是「猜一次」："
                + "万一开头判错，整场都会按错的语言识别。检测到的语言会显示在录音页，随时可以改。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("想更确定就直接指定你实际说的语言。指定中文时，夹在里面的英文词照样会"
                + "照原样输出（例如「这个 deadline 有点紧」）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("转写")
        } footer: {
            Text("实时字幕与终稿共用同一个 SenseVoice 模型，无需分开选择。"
                + "终稿在充电或息屏时执行，不占用你使用手机的时段。")
        }
    }

    // MARK: - 模型

    private var modelSection: some View {
        Section {
            // 自动准备的说明放在最前面：它回答的是"我到底要不要自己操作"，
            // 而这正是用户打开这一页时最可能问的问题。
            if let note = models.autoPrepareNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Toggle("首次使用自动准备模型", isOn: $settings.autoPrepareModel)
            Text("开启后，首次使用时自动下载识别模型"
                + "（\(SenseVoiceModel.displayName)，约 \(SenseVoiceModel.sizeText)），"
                + "不需要你自己操心。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("允许在移动网络下自动下载", isOn: $settings.autoPrepareOnCellular)
            Text("默认关闭 —— 上百 MB 的流量不该由 App 替你决定花。"
                + "关闭时只在 Wi-Fi 下自动下载。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("模型下载优先走镜像", isOn: $settings.preferModelMirror)
            Text("当 huggingface.co 不可达时打开此项。它只改变下载来源，不影响识别结果。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            modelRow

            Divider()

            llamaModelRow

            HStack {
                Text("模型占用")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: models.installedBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("模型")
        } footer: {
            if let message = models.lastMessage {
                Text(message)
            } else {
                Text("模型不打进安装包（蜂窝下载上限 200 MB），首次使用时在这里下载。")
            }
        }
    }

    /// 单模型下载行。SenseVoice 只有一个模型、实时与终稿通用，因此不再按模型遍历。
    @ViewBuilder
    private var modelRow: some View {
        let state = models.state
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(SenseVoiceModel.displayName).bold()
                        Text("实时与终稿通用")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("中文优化的端到端模型，同音字更准，音乐自动识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelAction(state: state)
            }
            if case .downloading(let progress) = state {
                // 服务器给了总大小才画确定进度；否则用不确定动画 ——
                // 后者的意义是"确实在动"，而不是一条永远停在 0% 的死线。
                if progress.isProportional {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(progress.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // 长时间收不到数据必须当场说出来 ——
                // 这正是用户最需要知道、而原实现完全不显示的状态。
                if progress.idleSeconds >= 8 {
                    Text("最近 \(Int(progress.idleSeconds)) 秒没有收到数据；"
                        + "累计 \(Int(ModelDownloader.stallSeconds)) 秒无数据会自动改试另一个地址。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func modelAction(state: ModelDownloadState) -> some View {
        switch state {
        case .installed:
            Button("删除", role: .destructive) {
                try? models.delete()
            }
            .font(.footnote)

        case .downloading:
            Button("取消") {
                models.cancelDownload()
            }
            .font(.footnote)

        case .notInstalled, .failed:
            Button("下载 \(SenseVoiceModel.sizeText)") {
                models.download(preferMirror: settings.preferModelMirror)
            }
            .font(.footnote)
        }
    }

    /// 纠错模型下载行（Qwen2.5-0.5B）。与 SenseVoice 模型独立下载、单独管理。
    @ViewBuilder
    private var llamaModelRow: some View {
        let state = correction.state
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(LlamaModel.displayName).bold()
                        Text("纠错专用")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Text("本地小模型，纠正识别同音字；只在「LLM 纠错」开启时使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                llamaModelAction(state: state)
            }
            if case .downloading(let progress) = state {
                if progress.isProportional {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                Text(progress.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if progress.idleSeconds >= 8 {
                    Text("最近 \(Int(progress.idleSeconds)) 秒没有收到数据；"
                        + "累计 \(Int(ModelDownloader.stallSeconds)) 秒无数据会自动改试另一个地址。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func llamaModelAction(state: ModelDownloadState) -> some View {
        switch state {
        case .installed:
            Button("删除", role: .destructive) {
                try? correction.delete()
            }
            .font(.footnote)

        case .downloading:
            Button("取消") {
                correction.cancelDownload()
            }
            .font(.footnote)

        case .notInstalled, .failed:
            Button("下载 \(LlamaModel.sizeText)") {
                correction.download(preferMirror: settings.preferModelMirror)
            }
            .font(.footnote)
        }
    }

    // MARK: - 内置模型（M3）

    private var bundledModelSection: some View {
        Section {
            ForEach(SherpaBundledModel.allCases, id: \.self) { model in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.subheadline)
                        Text(model.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(model.isAvailable ? "已内置" : "缺失")
                        .font(.caption)
                        .foregroundStyle(model.isAvailable ? .green : .red)
                }
            }
        } header: {
            Text("内置模型（VAD / 降噪）")
        } footer: {
            Text("这些模型随安装包一起提供（合计约 "
                + ByteCountFormatter.string(fromByteCount: SherpaBundledModel.totalBytes, countStyle: .file)
                + "），不需要下载 —— 它们的原始托管地址在交付环境实测不可达，"
                + "做成下载会让这些功能直接不可用。")
        }
    }

    private var languageSection: some View {
        Section("语言") {
            // 「我正在学」这一项已随语言学习功能移除（2026-10-17）。
            // 它原本兼作实时翻译默认目标语言的兜底来源，现在该角色由
            // AppSettings.learningLanguage 内部承担，不再暴露给用户。
            Picker("默认翻译成", selection: $settings.defaultTargetLanguage) {
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Picker("实时翻译成", selection: $settings.liveTranslationTargetLanguage) {
                Text("关闭").tag("")
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            if !settings.liveTranslationTargetLanguage.isEmpty {
                livePackRow
            }
            Text("「默认翻译成」决定打开会话时默认的目标语言。"
                + "「实时翻译成」决定**录音时**把每句字幕实时翻成哪门语言（显示在原文下方），"
                + "选「关闭」就不做实时翻译。"
                + "实时翻译依赖系统翻译的语言包：首次使用需要联网下载一次，"
                + "录音页会在字幕下方提示缺少语言包或正在下载；"
                + "也可以在这里先把它准备好，就省掉那次下载。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 语言包状态 + 准备入口。
    ///
    /// ## 为什么必须在**设置页**准备
    /// 语言包首次使用必须联网下载，而系统只在 `prepareTranslation()` 时弹下载界面 ——
    /// 那要求**页面在屏上**。若留到录音时才准备，用户会在录音刚开始的那一刻
    /// 撞上系统弹窗，而那时他很可能已经锁屏走开了。
    /// 所以：在这里备好，录音时只是用它。
    @ViewBuilder
    private var livePackRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("语言包")
                    .foregroundStyle(.secondary)
                Text(livePackStatusText)
                    .foregroundStyle(isLivePackReady ? .green : .orange)
                Spacer()
            }
            .font(.footnote)

            // 只在「系统支持该语言对、但语言包还没装」时给准备入口。
            // 对 .unsupported（系统压根不支持这对语言）**不给按钮** ——
            // 那是个必然失败的假入口，而用户会以为是网络问题、反复重试。
            if livePackStatus == .supported {
                Button("准备语言包（会联网下载一次）") {
                    translation.prepareLanguagePack(
                        source: settings.defaultSourceLanguage,
                        target: settings.liveTranslationTargetLanguage
                    )
                }
                .font(.footnote)
            } else if livePackStatus == .unsupported {
                Text("这对语言系统不支持（本机翻译只覆盖系统已支持的语言对），换一门目标语言试试。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = translation.prepareMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 导出

    /// 导出开关。
    ///
    /// 2026-10-17：「生词本」功能已移除，本区因此只剩文字稿导出；
    /// 原「学习语言」「生词水平档」两个设置项随之删除
    ///（`AppSettings.vocabularyLevel` 与对应持久化键一并清掉）。
    private var exportSection: some View {
        Section {
            Toggle("允许导出", isOn: $settings.exportEnabled)
            Text("导出的是会话文字稿（Markdown）。"
                + "关掉它只是不生成导出文件，数据本身不受影响。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("导出")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
            }
            HStack {
                Text("提交")
                Spacer()
                Text(BuildInfo.commit).foregroundStyle(.secondary)
            }
            Text("一键录音 → 实时字幕 → 实时翻译 → 结束即保存"
                + "（音频、文字稿、译文三件都在）。转写全程离线完成，音频不离开设备。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
