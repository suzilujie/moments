import SwiftUI

/// 学习模式（设计文档 8.6）。
///
/// ## 为什么做成"整屏进入"而不是会话详情页上的一个开关
/// 文档写的是「在会话详情页增加一个开关，切换后界面重组为学习视图」。
/// 实现选了 `fullScreenCover`（整屏进入、退出即还原），理由两条：
///   1. 会话详情页已经承载了文字稿 / 说话人 / 双语 / 播放 / 生词 / 检索入口，
///      再往它里面塞一套"重组逻辑"，改坏的代价远大于收益；
///   2. 学习模式的使用姿态是「沉浸在一句句里反复听」，
///      与「翻看一次录音的详情」本来就是两种场景，整屏切换比原地变形更贴合。
/// 退出后原有状态（阅读稿版本、播放器）不受影响。
///
/// ## 两条明确不做 / 不做假的能力
///   · 文档 8.6 的筛选条件「只看目标语言的句子」依赖 7.5 逐段语言检测，
///     而**该能力尚未实现**。因此这里只提供「只看有生词的句子」，
///     不做那个做不出来的开关。
///   · 界面上的按钮文案是「复读原声」「朗读」，不出现"发音评分"一类措辞
///     （见 PronunciationScorer 的边界说明）。
struct StudyModeView: View {

    let manifest: SessionManifest

    @StateObject private var player = SentencePlayer()
    @ObservedObject private var reader = SpeechReader.shared
    @ObservedObject private var vocabulary = VocabularyStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var cards: [StudyCard] = []
    @State private var index = 0
    @State private var loadError: String?

    /// 只看有生词的句子（文档 8.6 的筛选之一）
    @State private var onlyWithVocabulary = false
    @State private var showsOriginal = true
    @State private var showsTranslation = true

    @State private var showingVocabularyList = false
    @State private var practiceTarget: StudyCard?
    /// 朗读相关的即时提示（如"这一句还没有译文"）
    @State private var speechNotice: String?

    // MARK: - 数据

    private struct StudyCard: Identifiable {
        let id: String
        let startMs: Int
        let endMs: Int
        let original: String
        let translated: String?
        let candidates: [VocabularyCandidate]

        var hasVocabulary: Bool { !candidates.isEmpty }
    }

    private struct SessionVocabularyEntry: Identifiable {
        let cardId: String
        let candidate: VocabularyCandidate
        let sentence: String
        var id: String { "\(cardId)|\(candidate.word)" }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    errorView(loadError)
                } else if cards.isEmpty {
                    ProgressView("正在准备材料…")
                } else {
                    content
                }
            }
            .navigationTitle("学习模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { load() }
            .onChange(of: onlyWithVocabulary) { clampIndex() }
            // 离开就停声：不停的话朗读会在返回后继续念（用户已经不在这个界面了）
            .onDisappear {
                reader.stop()
                player.stop()
            }
            .sheet(item: $practiceTarget) { card in
                PracticeView(referenceText: card.original)
            }
            .sheet(isPresented: $showingVocabularyList) { vocabularySheet }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                onlyWithVocabulary.toggle()
            } label: {
                Image(systemName: onlyWithVocabulary
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }

            Button {
                showingVocabularyList = true
            } label: {
                Image(systemName: "text.book.closed")
            }

            Menu {
                Toggle("显示原文", isOn: $showsOriginal)
                Toggle("显示译文", isOn: $showsTranslation)
            } label: {
                Image(systemName: "eye")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let card = currentCard {
            VStack(spacing: 0) {
                statusBar
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let notice = vocabularyUnavailableNotice {
                            noticeView(notice)
                        }
                        cardView(card)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                Divider()
                controls(card)
            }
        } else {
            // 只看有生词但一句都没有 —— 这是完全可能的状态（材料确实没有生词）
            VStack(spacing: 12) {
                Text("当前筛选下没有句子。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("显示全部句子") { onlyWithVocabulary = false }
                    .font(.footnote)
            }
            .padding(32)
        }
    }

    // MARK: - 顶栏状态

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("第 \(index + 1) / \(visibleCards.count) 句")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if onlyWithVocabulary {
                Text("只看有生词")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let speechNotice {
                Text(speechNotice)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if let error = reader.lastError ?? player.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func noticeView(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    // MARK: - 卡片

    @ViewBuilder
    private func cardView(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsOriginal {
                highlighted(card.original, candidates: card.candidates)
                    .font(.title3)
                    .textSelection(.enabled)
            }

            if showsTranslation {
                if let translated = card.translated, !translated.isEmpty {
                    Text(translated)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    // 没译文时说清楚"去哪儿弄"，而不是留一片空白
                    Text("尚无译文。可在会话详情里选择目标语言生成后再回来。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            if !showsOriginal, !showsTranslation {
                Text("原文与译文都被隐藏了 —— 这正是「先盲听」的练法，听完再用上方眼睛图标打开对照。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if card.hasVocabulary {
                chips(card.candidates, sentence: card.original)
            } else if showsOriginal {
                Text("这一句没有生词。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 用生词表给原句着色。
    ///
    /// 按**位置**切分再拼接 `Text`，而不是拿词列表重拼 —— 后者会丢掉标点、
    /// 把中文句子拼坏，而学习材料一旦显示得和原文不一样就失去对照价值。
    private func highlighted(_ text: String, candidates: [VocabularyCandidate]) -> Text {
        let keys = Set(candidates.map { $0.word })
        guard !keys.isEmpty else { return Text(text) }

        let tokens = VocabularyExtractor.locateTokens(in: text)
        guard !tokens.isEmpty else { return Text(text) }

        var output = Text("")
        var cursor = text.startIndex

        for token in tokens {
            if cursor < token.range.lowerBound {
                output = output + Text(String(text[cursor..<token.range.lowerBound]))
            }
            if keys.contains(token.key) {
                output = output + Text(token.text).foregroundStyle(.orange).bold()
            } else {
                output = output + Text(token.text)
            }
            cursor = token.range.upperBound
        }
        if cursor < text.endIndex {
            output = output + Text(String(text[cursor...]))
        }
        return output
    }

    @ViewBuilder
    private func chips(_ candidates: [VocabularyCandidate], sentence: String) -> some View {
        // 每句最多铺 4 个：全铺会把卡片撑散，反而看不清句子本身
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
                        .padding(.vertical, 3)
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

    // MARK: - 操作区

    private func controls(_ card: StudyCard) -> some View {
        VStack(spacing: 12) {
            // 主操作：复读原声。
            // 设计文档 11.6 明确要求它是页面上最大、最易按的控件 ——
            // 学习模式的主操作是「再听一遍」，不是「读文字」。
            Button {
                togglePlay(card)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isPlaying(card) ? "stop.circle.fill" : "play.circle.fill")
                    Text(isPlaying(card) ? "停止" : "复读原声")
                    Text(player.rateText)
                        .font(.caption)
                        .opacity(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 10) {
                Button {
                    step(-1)
                } label: {
                    Label("上一句", systemImage: "chevron.left")
                }
                .disabled(index == 0)

                Button {
                    step(1)
                } label: {
                    Label("下一句", systemImage: "chevron.right")
                }
                .disabled(index >= visibleCards.count - 1)
            }
            .font(.footnote)
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                Button(player.rateText) { player.cycleRate() }
                Button(player.isLooping ? "循环开" : "循环关") { player.toggleLoop() }

                Menu {
                    Button("读原文") { speakOriginal(card) }
                    Button("读译文") { speakTranslation(card) }
                    Button("连播全部译文") { speakAllTranslations() }
                } label: {
                    Label("朗读", systemImage: "speaker.wave.2")
                }

                Button {
                    practiceTarget = card
                } label: {
                    Label("跟读", systemImage: "mic")
                }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 播放

    private func isPlaying(_ card: StudyCard) -> Bool {
        player.isPlaying && player.playingSegmentId == card.id
    }

    private func togglePlay(_ card: StudyCard) {
        speechNotice = nil
        if isPlaying(card) {
            player.stop()
            return
        }
        // 复读与朗读互斥：两者同时出声会互相盖住，用户分不清在听哪一个
        reader.stop()
        player.play(
            sessionId: manifest.id,
            segmentId: card.id,
            startMs: card.startMs,
            endMs: card.endMs
        )
    }

    private func step(_ delta: Int) {
        let count = visibleCards.count
        guard count > 0 else { return }
        index = min(max(0, index + delta), count - 1)
        // 切句先停声：不停的话上一句会继续念，用户分不清在听哪一句
        speechNotice = nil
        reader.stop()
        player.stop()
    }

    // MARK: - 朗读（TTS）

    private func speakOriginal(_ card: StudyCard) {
        speechNotice = nil
        player.stop()
        reader.speak(
            id: card.id,
            text: card.original,
            language: settings.defaultSourceLanguage
        )
    }

    private func speakTranslation(_ card: StudyCard) {
        player.stop()
        guard let translated = card.translated, !translated.isEmpty else {
            speechNotice = "这一句还没有译文"
            return
        }
        speechNotice = nil
        reader.speak(
            id: card.id,
            text: translated,
            language: settings.defaultTargetLanguage
        )
    }

    private func speakAllTranslations() {
        let items = visibleCards.compactMap { card -> (id: String, text: String, language: String)? in
            guard let translated = card.translated, !translated.isEmpty else { return nil }
            return (id: card.id, text: translated, language: settings.defaultTargetLanguage)
        }
        player.stop()
        guard !items.isEmpty else {
            speechNotice = "当前材料还没有译文，无法连播"
            return
        }
        speechNotice = nil
        reader.speakAll(items)
    }

    // MARK: - 生词列表

    private var vocabularySheet: some View {
        NavigationStack {
            List {
                if sessionVocabulary.isEmpty {
                    Text("这次录音里没有生词。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(sessionVocabulary) { entry in
                            Button {
                                jump(to: entry.cardId)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.candidate.word)
                                            .font(.headline)
                                        Text(entry.candidate.difficultyText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if vocabulary.contains(entry.candidate.word) {
                                            Text("已在生词本")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Text(entry.sentence)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("共 \(sessionVocabulary.count) 个词｜点一下跳到所在句子")
                    }
                }
            }
            .navigationTitle("本会话生词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingVocabularyList = false }
                }
            }
        }
    }

    private func jump(to cardId: String) {
        showingVocabularyList = false
        // 被筛选挡住时先关掉筛选，否则"点了却没跳"会让人以为功能坏了
        if !visibleCards.contains(where: { $0.id == cardId }) {
            onlyWithVocabulary = false
        }
        guard let position = visibleCards.firstIndex(where: { $0.id == cardId }) else { return }
        index = position
        reader.stop()
        player.stop()
    }

    // MARK: - 派生数据

    private var visibleCards: [StudyCard] {
        onlyWithVocabulary ? cards.filter { $0.hasVocabulary } : cards
    }

    private var currentCard: StudyCard? {
        let list = visibleCards
        guard !list.isEmpty else { return nil }
        guard list.indices.contains(index) else { return list.first }
        return list[index]
    }

    private func clampIndex() {
        let count = visibleCards.count
        index = count == 0 ? 0 : min(index, count - 1)
    }

    /// 本会话生词汇总（越生僻越靠前）
    private var sessionVocabulary: [SessionVocabularyEntry] {
        var seen: Set<String> = []
        var entries: [SessionVocabularyEntry] = []
        for card in cards {
            for candidate in card.candidates where !seen.contains(candidate.word) {
                seen.insert(candidate.word)
                entries.append(
                    SessionVocabularyEntry(
                        cardId: card.id,
                        candidate: candidate,
                        sentence: card.original
                    )
                )
            }
        }
        return entries.sorted { lhs, rhs in
            let left = lhs.candidate.rank ?? Int.max
            let right = rhs.candidate.rank ?? Int.max
            if left != right { return left > right }
            return lhs.candidate.word < rhs.candidate.word
        }
    }

    /// 生词判定不可用时的说明。**必须显式告知** ——
    /// 否则用户看到的是"这段材料没有生词"，而真相是判据根本没生效。
    private var vocabularyUnavailableNotice: String? {
        if !WordFrequencyTable.shared.isReady {
            return "生词判定不可用：词频表未打进安装包。"
        }
        if settings.learningLanguage != "en" {
            return "生词判定目前只支持英语（当前学习语言：\(settings.learningLanguage)）。"
        }
        return nil
    }

    // MARK: - 载入

    private func load() {
        WordFrequencyTable.shared.loadIfNeeded()

        // 与阅读视图同一取舍：优先终稿，没有则用实时稿
        let pass: TranscriptPass = TranscriptStore.shared.exists(sessionId: manifest.id, pass: .final)
            ? .final
            : .live

        guard let document = TranscriptStore.shared.load(sessionId: manifest.id, pass: pass),
              !document.isEmpty else {
            loadError = "这次录音还没有文字稿。\n请先在会话详情里点「转写为文字」，再回到这里。"
            return
        }

        // 译文只取**同一稿 + 当前目标语言**：
        // 不按稿过滤，会把终稿的译文贴到实时稿的句子上（两稿的句子不是同一条）。
        let translationDocument = TranslationStore.shared.load(sessionId: manifest.id)
        var translated: [String: String] = [:]
        for entry in translationDocument.entries
        where entry.targetLang == settings.defaultTargetLanguage && entry.pass == pass {
            translated[entry.segmentId] = entry.text
        }

        let options = vocabularyOptions()
        cards = document.segments.map { segment in
            StudyCard(
                id: segment.id,
                startMs: segment.startMs,
                endMs: segment.endMs,
                original: segment.text,
                translated: translated[segment.id],
                candidates: VocabularyExtractor.extract(from: segment.text, options: options)
            )
        }
        index = 0
    }

    /// 生词判定选项：**阈值跟随用户选的水平档**。
    ///
    /// 之所以要专门取一次：提取器的默认阈值是写死的 3000，
    /// 若这里不传，设置页里改水平档就不会生效 —— 那等于开关是假的。
    private func vocabularyOptions() -> VocabularyExtractor.Options {
        var options = VocabularyExtractor.Options()
        options.rankThreshold = settings.vocabularyLevel.rankThreshold
        // 只支持英语：词频表是英语的。对其它学习语言宁可关闭判定，
        // 也不能让它用英语词表去判中文材料（那会把每个词都标成生词）。
        options.enabled = WordFrequencyTable.shared.isReady && settings.learningLanguage == "en"
        return options
    }

    // MARK: - 兜底

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(32)
    }
}
