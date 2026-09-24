import AVFoundation
import SwiftUI
// 必须 import：`.translationTask` 这个 SwiftUI 修饰器定义在 Translation 模块里，
// 不 import 的话会报 "value of type 'some View' has no member 'translationTask'"
// —— 这条错误与"框架没链接"无关，纯粹是模块可见性问题。
import Translation

/// 记录列表：按时间浏览所有录音。
struct SessionListView: View {

    @State private var sessions: [SessionManifest] = []
    @State private var totalBytes: Int = 0
    @ObservedObject private var index = SearchIndex.shared

    @State private var searchQuery = ""
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                if isSearchActive {
                    searchResultSection
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        "还没有录音",
                        systemImage: "waveform",
                        description: Text("到「录音」标签页点开始，录到的内容会出现在这里。")
                    )
                } else {
                    sessionSection
                }
            }
            .navigationTitle("记录")
            .searchable(text: $searchQuery, prompt: "搜索转写内容")
            .task(id: searchQuery) { await runSearch() }
            .onAppear(perform: reload)
            .refreshable { reload() }
        }
    }

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sessionSection: some View {
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

    /// 检索结果。
    ///
    /// 点进去会**自动播放那一句**（见 SessionDetailView 的 focus 系列参数）——
    /// 搜一句话的目的就是"听那一句"，让用户再从长列表里找一遍纯属多余。
    private var searchResultSection: some View {
        Section {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("搜索中…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if searchHits.isEmpty {
                Text("没有找到包含该内容的句子。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchHits) { hit in
                    if let target = sessions.first(where: { $0.id == hit.sessionId }) {
                        NavigationLink {
                            SessionDetailView(
                                manifest: target,
                                focusSegmentId: hit.id,
                                focusStartMs: hit.startMs,
                                focusEndMs: hit.endMs
                            )
                        } label: {
                            searchHitRow(hit)
                        }
                    }
                }
            }
        } header: {
            Text(searchHits.isEmpty ? "搜索" : "命中 \(searchHits.count) 句")
        } footer: {
            Text("检索覆盖全部转写文本（实时稿与终稿均已索引）。"
                + "索引能力：\(index.capability.title)。")
        }
    }

    private func searchHitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.text)
                .font(.body)
                .lineLimit(3)
            Text(hitSubtitle(hit))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 命中行的副标题。**必须标出"这条命中来自译文"** ——
    /// 否则用户会以为自己的录音里真的说了那句译文。
    private func hitSubtitle(_ hit: SearchHit) -> String {
        var parts: [String] = [hit.sessionTitle, hit.timeText]
        if hit.isTranslation {
            parts.append(hit.languageText)
        }
        parts.append(hit.pass.title)
        return parts.joined(separator: "｜")
    }

    private func runSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchHits = []
            isSearching = false
            return
        }
        isSearching = true
        let hits = await SearchIndex.shared.search(query)
        // 边打字边搜会连续触发多次查询；只接受**与当前输入一致**的结果，
        // 否则会出现"结果闪回上一次查询"的错乱，而用户会以为自己搜错了
        guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        searchHits = hits
        isSearching = false
    }

    private func reload() {
        sessions = RecordingLibrary.shared.listSessions()
        totalBytes = sessions.reduce(0) { $0 + $1.totalBytes }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let item = sessions[index]
            try? RecordingLibrary.shared.deleteSession(item.id)
            // 同步移除检索索引，否则会搜到已经不存在的会话
            SearchIndex.shared.remove(sessionId: item.id)
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
    /// 从搜索结果进入时要自动播放的那一句（M4）。
    /// 给默认值是为了不破坏既有的 `SessionDetailView(manifest:)` 调用点。
    var focusSegmentId: String? = nil
    var focusStartMs: Int? = nil
    var focusEndMs: Int? = nil
    @StateObject private var player = SentencePlayer()
    @ObservedObject private var asr = TranscriptionService.shared
    @ObservedObject private var diarization = DiarizationService.shared
    @ObservedObject private var profiles = SpeakerProfileStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var transcript: TranscriptDocument?
    @State private var selectedPass: TranscriptPass = .final
    @State private var speakerTimeline: SpeakerTimeline?
    /// 正在命名哪个说话人（弹窗）
    @State private var namingSpeakerIndex: Int?
    @State private var draftSpeakerName = ""

    // M5 翻译
    @ObservedObject private var translation = TranslationService.shared
    /// 空字符串表示"尚未初始化"：初值在 onAppear 里从设置读取。
    /// 不在属性初始化式里直接读 AppSettings（那是 @MainActor 隔离的属性，
    /// 在非隔离的初始化式里访问会构成隔离问题）。
    @State private var targetLanguage = ""
    /// 源语言。系统翻译**不支持"源语言自动判定"**，必须显式指定，
    /// 因此界面上必须有这一项 —— 假装它自己知道是错的。
    /// 源语言。**取持久化的设置值并写回** ——
    /// 此前它是纯局部状态，每次进入都重置为 zh-Hans：用户改成 en、退出再进来又变回去，
    /// 而"源语言与目标语言相同"是无效组合，界面还会就地纠正一次，等于每次都要重选。
    @State private var sourceLanguage = AppSettings.shared.defaultSourceLanguage
    @State private var displayMode: TranscriptDisplayMode = .bilingual
    /// 当前语言已翻好的片段（segmentId → 译文）
    @State private var translationMap: [String: String] = [:]
    /// 各语言对的可用性（前置校验结果，界面必须显示出来）
    @State private var languageStatus: [String: String] = [:]

    // M6 生词
    @ObservedObject private var vocabulary = VocabularyStore.shared
    /// 每句的生词候选（按片段 id 索引）
    @State private var segmentVocabulary: [String: [VocabularyCandidate]] = [:]
    @State private var highlightsVocabulary = true
    /// 跟读比对的目标句（非 nil 时弹出跟读页）
    @State private var practiceTarget: TranscriptRow?
    /// 学习模式（M6 收尾）
    @State private var showingStudyMode = false
    /// 文字稿导出文件的 URL（受「允许导出」开关控制，文字稿载入时生成一次）
    @State private var transcriptExportURL: URL?

    private var sessionDirectory: URL {
        RecordingLibrary.shared.sessionDirectory(manifest.id)
    }

    var body: some View {
        List {
            transcriptSection
            speakerSection
            overviewSection
            if manifest.hasGap { gapSection }
            if let note = manifest.note { noteSection(note) }
            segmentsSection
            deleteSection
        }
        .navigationTitle(manifest.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            initializePass()
            reloadSpeakerTimeline()
            if targetLanguage.isEmpty {
                targetLanguage = AppSettings.shared.defaultTargetLanguage
            }
            // 源语言与目标语言相同是无效组合（自己翻自己）。
            // 默认值确实可能撞车（用户既以中文为主要语言、默认目标也可能是中文），
            // 与其让用户点一次才发现在报错，不如在这里纠正一次。
            if sourceLanguage == targetLanguage {
                targetLanguage = (sourceLanguage == "en") ? "zh-Hans" : "en"
            }
            reloadTranslationMap()
            playFocusedSentenceIfNeeded()
        }
        .onChange(of: selectedPass) {
            reloadTranscript()
            reloadTranslationMap()
        }
        .onChange(of: asr.stage) { reloadTranscript() }
        .onChange(of: diarization.stage) { reloadSpeakerTimeline() }
        .onChange(of: targetLanguage) { reloadTranslationMap() }
        // 源语言变了，所有语言对的可用性都会变，必须重查
        .onChange(of: sourceLanguage) {
            // 写回设置：下次进来不用重选
            AppSettings.shared.defaultSourceLanguage = sourceLanguage
            Task { await refreshLanguageStatus() }
        }
        // 关掉生词高亮后不必重算，但重新打开必须重算（之前的结果已被清空）
        .onChange(of: highlightsVocabulary) { reloadVocabulary() }
        // 水平档变了必须重算：否则"改了设置但标注没变化"会被当成没生效
        .onChange(of: settings.vocabularyLevel) { reloadVocabulary() }
        .onChange(of: translation.stage) { reloadTranslationMap() }
        // 系统翻译框架要求由**视图**拿到 TranslationSession，
        // 因此把真正的执行挂在这里（见 TranslationService 里对两段式设计的说明）
        .translationTask(translation.configuration) { session in
            await translation.execute(with: session)
        }
        .task { await refreshLanguageStatus() }
        .alert("命名说话人", isPresented: namingBinding) {
            TextField("姓名", text: $draftSpeakerName)
            Button("取消", role: .cancel) { namingSpeakerIndex = nil }
            Button("保存") { commitSpeakerName() }
        } message: {
            Text("命名后，这个人的声纹会存入声纹库；以后再录到他，会自动标出名字。")
        }
        .onDisappear { player.stop() }
        // M6b：跟读比对。用 sheet(item:) 而不是 sheet(isPresented:) ——
        // 前者把"要读的是哪一句"作为数据带过去，不必再维护一份"当前选中句"的状态
        .sheet(item: $practiceTarget) { row in
            PracticeView(referenceText: row.text)
        }
        // 学习模式整屏进入。不做成"原地重组会话详情页"的开关：
        // 这一页已经承载了文字稿 / 说话人 / 双语 / 播放 / 生词 / 检索入口，
        // 再塞一套重组逻辑的收益远小于改坏它的风险（详见 StudyModeView 的说明）
        .fullScreenCover(isPresented: $showingStudyMode) {
            StudyModeView(manifest: manifest)
        }
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
                        Image(systemName: player.playingSegmentId == row.fileName
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

    // MARK: - 说话人（M3c）

    private var namingBinding: Binding<Bool> {
        Binding(
            get: { namingSpeakerIndex != nil },
            set: { if !$0 { namingSpeakerIndex = nil } }
        )
    }

    private var speakerSection: some View {
        Section {
            if diarization.runningSessionId == manifest.id {
                diarizingView
            } else if let speakerTimeline, !speakerTimeline.isEmpty {
                speakerList(speakerTimeline)
            } else {
                emptySpeakerView
            }
        } header: {
            HStack {
                Text("说话人")
                Spacer()
                if let speakerTimeline, !speakerTimeline.isEmpty {
                    Text(speakerTimeline.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(speakerFooterText)
        }
    }

    private var diarizingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diarization.stage.text)
                .font(.subheadline)
                .bold()
            ProgressView(value: diarization.progress)
                .progressViewStyle(.linear)
            Text("已处理 \(diarization.processedChunks) / \(diarization.totalChunks) 块音频")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("长录音会分段处理，再用声纹把各段的「说话人1」接续成同一个人。可随时取消。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消分析", role: .destructive) {
                diarization.cancel()
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func speakerList(_ timeline: SpeakerTimeline) -> some View {
        ForEach(speakerRows(timeline)) { row in
            Button {
                guard !row.isNamed else { return }
                draftSpeakerName = ""
                namingSpeakerIndex = row.index
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.isNamed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("命名")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var emptySpeakerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptySpeakerHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("识别说话人") {
                diarization.analyze(sessionId: manifest.id)
            }
            .disabled(!hasAnyAudio || !SherpaBundledModel.isReady)
        }
        .padding(.vertical, 2)
    }

    private var emptySpeakerHint: String {
        guard hasAnyAudio else {
            return "音频已按保留期清理，无法再做说话人分离。"
        }
        if !SherpaBundledModel.isReady {
            let missing = SherpaBundledModel.missingModels.map { $0.displayName }.joined(separator: "、")
            return "缺少内置模型（\(missing)），说话人分离不可用。"
        }
        return "尚未分析。全程在本机离线完成，音频不会离开设备。"
    }

    private var speakerFooterText: String {
        "重叠说话（多人同时讲）准确率会明显下降，这类片段标注为「可能重叠」，"
            + "而不是假装判断正确。未命名的说话人可点一下命名 —— 命名后声纹入库，以后再录到会自动认出。"
    }

    private struct SpeakerRow: Identifiable {
        let id: Int
        let index: Int
        let displayName: String
        let detail: String
        let isNamed: Bool
    }

    private func speakerRows(_ timeline: SpeakerTimeline) -> [SpeakerRow] {
        let grouped = Dictionary(grouping: timeline.turns, by: { $0.speakerIndex })
        return grouped.keys.sorted().map { index in
            let turns = grouped[index] ?? []
            let durationMs = turns.reduce(0) { $0 + $1.durationMs }
            var detail = "\(turns.count) 段｜共 \(durationMs / 1000) 秒"
            if turns.contains(where: { $0.mayOverlap }) { detail += "｜含可能重叠" }
            return SpeakerRow(
                id: index,
                index: index,
                displayName: timeline.displayName(for: index),
                detail: detail,
                isNamed: turns.contains { $0.personName != nil }
            )
        }
    }

    private func commitSpeakerName() {
        defer { namingSpeakerIndex = nil }
        guard let index = namingSpeakerIndex, let name = normalizedSpeakerName() else { return }
        guard var timeline = speakerTimeline,
              let centroids = timeline.centroids,
              index >= 0, index < centroids.count else {
            Log.shared.warn(.asr, "无法命名说话人 \(index)：时间轴里没有声纹质心")
            return
        }

        // 命名即入库：质心早就随时间轴存下了，不需要重新录音或重跑分离
        SpeakerProfileStore.shared.upsert(name: name, centroid: centroids[index], source: "session")

        for position in timeline.turns.indices where timeline.turns[position].speakerIndex == index {
            timeline.turns[position].personName = name
        }
        speakerTimeline = timeline
        try? SpeakerTimelineStore.shared.save(timeline)
    }

    private func normalizedSpeakerName() -> String? {
        let trimmed = draftSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func reloadSpeakerTimeline() {
        speakerTimeline = SpeakerTimelineStore.shared.load(sessionId: manifest.id)
    }

    /// 转写片段的说话人：取**时间重叠最多**的那一段。
    /// 不用"起点落在谁里面"是因为两个时间轴边界不会对齐，用重叠量更稳。
    private func speakerName(fromMs: Int, toMs: Int) -> String? {
        guard let speakerTimeline else { return nil }
        guard let turn = speakerTimeline.dominantTurn(fromMs: fromMs, toMs: toMs) else { return nil }
        return speakerTimeline.displayName(for: turn.speakerIndex)
    }

    // MARK: - 翻译（M5）

    private var transcriptSegments: [TranscriptSegment] {
        transcript?.segments ?? []
    }

    /// 语言与显示方式控制。
    ///
    /// 三项都放在转写列表**上方**：语言切换是高频操作（设计文档 11.5 明确要求
    /// 不藏在设置里），显示模式决定用户看到的每一行，必须一眼可见。
    private var translationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("源语言", selection: $sourceLanguage) {
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(language.name).tag(language.code)
                }
            }

            Picker("翻译成", selection: $targetLanguage) {
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(languageOptionTitle(language)).tag(language.code)
                }
            }

            Picker("显示", selection: $displayMode) {
                ForEach(TranscriptDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if translation.runningSessionId == manifest.id {
                ProgressView(value: translation.progress)
                    .progressViewStyle(.linear)
                Text("已翻 \(translation.completedSegments) / \(translation.totalSegments) 句")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("取消翻译", role: .destructive) {
                    translation.cancel()
                }
                .font(.footnote)
            } else {
                Button(translateButtonTitle) {
                    translation.requestTranslation(
                        sessionId: manifest.id,
                        source: sourceLanguage,
                        target: targetLanguage,
                        pass: selectedPass,
                        segments: transcriptSegments,
                        existing: translationMap
                    )
                }
                .font(.footnote)
                .disabled(transcriptSegments.isEmpty)
            }

            if let status = languageStatus[targetLanguage], status != "已就绪" {
                Text("语言状态：\(status)")
                    .font(.caption)
                    .foregroundStyle(status.contains("不支持") ? .red : .orange)
            }

            Text("译文仅供参考：端侧翻译在口语、俚语、长难句、专业术语与人名上会明显失真 —— "
                + "所以原文始终显示在译文上方，且译文可人工修正（修正后不会被自动翻译覆盖）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var translateButtonTitle: String {
        let name = TranslationLanguageCatalog.name(for: targetLanguage)
        if translationMap.isEmpty {
            return "翻译成\(name)"
        }
        return "补齐译文（已有 \(translationMap.count) 句）"
    }

    /// 语言选项文案里带上可用性。
    ///
    /// **必须在选中之前就能看出来**，而不是选完才提示 ——
    /// 否则用户已经以为它会工作、并且已经按下了翻译。
    private func languageOptionTitle(_ language: TranslationLanguage) -> String {
        guard let status = languageStatus[language.code], status != "已就绪" else {
            return language.name
        }
        return "\(language.name)（\(status)）"
    }

    /// 前置校验各语言对。不能省：不查就翻，用户会得到"点了没反应"。
    private func refreshLanguageStatus() async {
        let source = sourceLanguage
        var result: [String: String] = [:]
        // 跳过源语言自身（自己翻自己没有意义）
        for language in TranslationLanguageCatalog.all where language.code != source {
            let status = await translation.availability(from: source, to: language.code)
            result[language.code] = TranslationService.describe(status)
        }
        languageStatus = result
    }

    private func reloadTranslationMap() {
        guard !targetLanguage.isEmpty else { return }
        translationMap = TranslationStore.shared
            .load(sessionId: manifest.id)
            .texts(for: targetLanguage)
    }

    // MARK: - 学习模式与导出（M6 收尾）

    /// 学习模式入口 + 文字稿导出。
    private var studyModeRow: some View {
        HStack(spacing: 12) {
            Button {
                showingStudyMode = true
            } label: {
                Label("学习模式", systemImage: "text.book.closed")
            }
            .font(.footnote)

            Spacer()

            if !settings.exportEnabled {
                Text("导出已在设置中关闭")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let url = transcriptExportURL {
                ShareLink(item: url) {
                    Label("导出文字稿", systemImage: "square.and.arrow.up")
                        .font(.footnote)
                }
            } else {
                // 还没生成好或生成失败：给出明确状态，不给一个点了没反应的按钮
                Text("文字稿暂不可导出")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 生成文字稿导出文件（Markdown 纯文本）。
    ///
    /// 在**文字稿载入时生成一次**并缓存 URL，而不是在 body 里现算 ——
    /// 后者会让每次渲染都产生一次磁盘写入。
    private func generateTranscriptExport() {
        guard settings.exportEnabled, let transcript, !transcript.isEmpty else {
            transcriptExportURL = nil
            return
        }

        var lines: [String] = []
        lines.append("# \(manifest.title)")
        lines.append("")
        lines.append(
            "> 录制 \(manifest.startedAt.formatted(date: .numeric, time: .shortened))"
                + "｜时长 \(manifest.durationText())｜\(transcript.segments.count) 句"
        )
        if manifest.hasGap {
            // 断口必须写进导出文件：导出的文本是"留档"用的，
            // 拿到它的人有权知道哪一段当时没录上
            lines.append(">")
            lines.append(
                "> 注意：本次录音存在断口 \(manifest.gaps.count) 处，"
                    + "累计约 \(manifest.totalGapMs / 1000) 秒 —— 断口期间没有音频。"
            )
        }
        lines.append("")

        for segment in transcript.segments {
            lines.append("**[\(segment.timeText)]** \(segment.text)")
            if let translated = translationMap[segment.id], !translated.isEmpty {
                lines.append("")
                lines.append("> \(translated)")
            }
            lines.append("")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-transcript-\(manifest.id).md")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            transcriptExportURL = url
        } catch {
            Log.shared.error(.storage, "文字稿导出写入失败｜\(error.localizedDescription)")
            transcriptExportURL = nil
        }
    }

    // MARK: - 生词（M6）

    /// 一句里的生词 chips。点一下即收录 —— 收录动作必须**零成本**：
    /// 若要点进另一个页面才能存词，用户就会放弃存词，
    /// 而"存不下来"等于这个功能不存在。
    @ViewBuilder
    private func vocabularyChips(_ candidates: [VocabularyCandidate], sentence: String) -> some View {
        let shown = Array(candidates.prefix(4))
        HStack(spacing: 6) {
            ForEach(shown) { candidate in
                let inBook = vocabulary.contains(candidate.word)
                Button {
                    guard !inBook else { return }
                    vocabulary.add(
                        word: candidate.word,
                        displayWord: candidate.surface,
                        sourceSessionId: manifest.id,
                        sourceSentence: sentence,
                        rank: candidate.rank
                    )
                } label: {
                    Text(candidate.word)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((inBook ? Color.green : Color.blue).opacity(0.14), in: Capsule())
                        .foregroundStyle(inBook ? Color.green : Color.blue)
                }
                .buttonStyle(.borderless)
            }

            if candidates.count > shown.count {
                Text("+\(candidates.count - shown.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - 文字稿（M2）

    private var transcriptSection: some View {
        Section {
            if asr.runningSessionId == manifest.id {
                transcribingView
            } else if let transcript, !transcript.isEmpty {
                passPicker
                transcriptActions
                studyModeRow
                playbackControls
                translationControls
                if let error = player.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(transcriptRows) { row in
                    Button {
                        playSentence(row)
                    } label: {
                        transcriptRowView(row)
                    }
                    .buttonStyle(.plain)
                    // M6b：跟读入口放在左滑。不挤进行内，是因为一行里已经有
                    // 时间、识别中标记、播放、生词 chips —— 再加图标会让主操作
                    //（点句子听音频）变得难以点准。
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            practiceTarget = row
                        } label: {
                            Label("跟读", systemImage: "mic.fill")
                        }
                        .tint(.orange)
                    }
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

    /// 转写相关的动作。
    ///
    /// 「对照转写」的存在理由：降噪会引入失真伪影，**可能反而让识别更差**。
    /// 与其争论，不如让用户在**同一段音频**上用**同一个模型**跑两次
    /// （终稿 = 原始音频，对照稿 = 降噪音频），直接比较文字 ——
    /// 这是本项目对"降噪到底有没有用"给的唯一诚实答案。
    private var transcriptActions: some View {
        HStack {
            Button("重新转写") {
                asr.transcribe(sessionId: manifest.id, pass: .final)
            }
            .font(.footnote)

            Spacer()

            Button("对照转写（降噪）") {
                asr.transcribe(sessionId: manifest.id, pass: .control, denoise: true)
            }
            .font(.footnote)
            .disabled(!hasAnyAudio)
        }
    }

    /// 播放控制：倍率与单句循环。
    ///
    /// 放在转写列表**上方**而不是收进菜单：慢放与复读是语言学习最高频的操作，
    /// 跳两层才能按到等于没有（设计文档 8.3 / 11.6）。
    /// 用 `.borderless` 是因为在 List 行里放多个按钮时，
    /// 默认样式会让整行都触发第一个按钮。
    private var playbackControls: some View {
        HStack(spacing: 14) {
            Button {
                player.cycleRate()
            } label: {
                Label(player.rateText, systemImage: "gauge.with.needle")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)

            Button {
                player.toggleLoop()
            } label: {
                Label(player.isLooping ? "循环中" : "单句循环", systemImage: "repeat")
                    .font(.footnote)
                    .foregroundStyle(player.isLooping ? .green : .secondary)
            }
            .buttonStyle(.borderless)

            // M6：生词高亮开关。放在这一排是因为它和倍率、循环同属
            // "读这段材料时的辅助手段"，不该藏进设置。
            Toggle("生词", isOn: $highlightsVocabulary)
                .font(.footnote)
                .fixedSize()

            Spacer()

            if player.isPlaying {
                Button("停止") { player.stop() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
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
        "点句子播放这一句。左滑句子可进入「跟读比对」——"
            + "它比的是「模型听成了哪些词」，不是音素级发音评分。"
            + "句子下方的蓝色词是该句的生词，点一下就收进生词本。"
            + "实时稿是「先出、再改对」的，准确文本以终稿为准。"
    }

    private var hasAnyAudio: Bool {
        manifest.segments.contains { fileExists($0) }
    }

    private struct TranscriptRow: Identifiable {
        let id: String
        let startMs: Int
        /// 结束时间：用于按**时间重叠**回填说话人（见 speakerName(fromMs:toMs:)）
        let endMs: Int
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
                endMs: segment.endMs,
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
                if let speaker = speakerName(fromMs: row.startMs, toMs: row.endMs) {
                    Text(speaker)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Image(systemName: player.playingSegmentId == row.id
                    ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(.tint)
            }
            if displayMode.showsOriginal {
                Text(row.text)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            if displayMode.showsTranslation {
                if let translated = translationMap[row.id] {
                    Text(translated)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !displayMode.showsOriginal {
                    // 只看译文但还没翻：明确说"尚无译文"，
                    // 而不是给用户一片空白让他以为是 Bug
                    Text("（尚无译文）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let candidates = segmentVocabulary[row.id], !candidates.isEmpty {
                vocabularyChips(candidates, sentence: row.text)
            }
        }
        .padding(.vertical, 2)
    }

    /// 点句回听：播放**这一句**（从句子起点到终点）。
    ///
    /// 这是 M4 相对 M2 的关键改进：M2 只能跳到所属分片（约 1 分钟），
    /// 用户还得自己听出是哪一句 —— 那基本等于没做。现在精确到句，
    /// 并支持变速不变调与单句循环（设计文档 9.3）。
    private func playSentence(_ row: TranscriptRow) {
        if player.playingSegmentId == row.id {
            player.stop()
        } else {
            player.play(
                sessionId: manifest.id,
                segmentId: row.id,
                startMs: row.startMs,
                endMs: row.endMs
            )
        }
    }

    /// 从搜索结果进来时自动播放那一句。
    /// 点搜索结果的目的就是"听这一句"，让用户再点一次纯属多余。
    private func playFocusedSentenceIfNeeded() {
        guard let focusSegmentId, let focusStartMs, let focusEndMs else { return }
        player.play(
            sessionId: manifest.id,
            segmentId: focusSegmentId,
            startMs: focusStartMs,
            endMs: focusEndMs
        )
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
        reloadVocabulary()
        generateTranscriptExport()
    }

    /// 逐句提取生词。
    ///
    /// **在文本加载时算一次**，而不是每行渲染时算：一份转写可能有几百句，
    /// 放进 View 的 body 会导致每次滚动、每次状态变化都重算一遍分词与查表。
    /// 提取本身很轻（切词 + 字典查询），一次算完即可。
    private func reloadVocabulary() {
        // 词频表是懒加载的（首次查询时才读文件），这里主动触发
        WordFrequencyTable.shared.loadIfNeeded()
        guard highlightsVocabulary else {
            segmentVocabulary = [:]
            return
        }

        // 阈值**跟随设置里的水平档**：不传的话提取器会用写死的 3000，
        // 那样设置页里改水平档就不会生效 —— 等于那个开关是假的。
        var options = VocabularyExtractor.Options()
        options.rankThreshold = settings.vocabularyLevel.rankThreshold
        // 只支持英语：词频表是英语的。对其它学习语言宁可关闭判定，
        // 也不能拿英语词表去判中文材料（那会把每个词都标成生词）
        options.enabled = WordFrequencyTable.shared.isReady && settings.learningLanguage == "en"

        var result: [String: [VocabularyCandidate]] = [:]
        for segment in transcriptSegments {
            let candidates = VocabularyExtractor.extract(from: segment.text, options: options)
            if !candidates.isEmpty { result[segment.id] = candidates }
        }
        segmentVocabulary = result
    }

    // MARK: - 播放

    private func toggle(_ segment: SessionManifest.SegmentEntry) {
        if player.playingSegmentId == segment.fileName {
            player.stop()
        } else {
            // 播整片：分片列表的语义就是"这一分钟"
            player.play(
                sessionId: manifest.id,
                segmentId: segment.fileName,
                startMs: segment.startMs,
                endMs: segment.endMs
            )
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

// 分片播放器（SessionAudioPlayer）已在 M4 被 SentencePlayer 取代：
// 后者能精确到"句"而不是"整分钟"，且支持变速不变调与单句循环。
// 留着旧类只会让"现在用的是哪个播放器"变成一个需要翻代码才能回答的问题。
