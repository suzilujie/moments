import SwiftUI

/// 生词本（M6）。
///
/// 这一页承载的心智模型是：**生词是从自己的材料里长出来的**，
/// 不是从词库里背的。每一条生词都带着它的原句 —— 那才是记忆的钩子。
struct VocabularyView: View {

    @ObservedObject private var store = VocabularyStore.shared
    @ObservedObject private var settings = AppSettings.shared

    enum SortMode: String, CaseIterable {
        case time
        case difficulty

        var title: String {
            self == .time ? "按收录时间" : "按难度"
        }
    }

    @State private var sortMode: SortMode = .time
    @State private var hidesMastered = false
    @State private var editingNoteFor: VocabularyItem?
    @State private var draftNote = ""
    @State private var frequencyReady = false
    @State private var exportFiles: [ExportFile] = []
    @State private var exportError: String?

    /// 导出文件。生成一次后缓存 URL —— 在 body 里现算会导致每次渲染都写一次盘。
    private struct ExportFile: Identifiable {
        let title: String
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        NavigationStack {
            List {
                if !frequencyReady {
                    frequencyMissingSection
                }

                if store.items.isEmpty {
                    emptySection
                } else {
                    statisticsSection
                    controlsSection
                    vocabularySection
                }

                exportSection
                aboutSection
            }
            .navigationTitle("生词本")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if settings.exportEnabled {
                        Menu {
                            ForEach(exportFiles) { file in
                                ShareLink(item: file.url) { Text(file.title) }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(exportFiles.isEmpty)
                    }
                }
            }
            .task {
                // 词频表是懒加载的（首次查询时才读文件），这里主动触发一次，
                // 好让"是否可用"能在界面上如实显示，而不是等用户点开某句才发现
                WordFrequencyTable.shared.loadIfNeeded()
                frequencyReady = WordFrequencyTable.shared.isReady
                prepareExport()
            }
            // 生词数量变化后重新生成导出文件，否则导出的是旧内容
            .onChange(of: store.totalCount) { prepareExport() }
            .alert("备注", isPresented: noteBinding) {
                TextField("这个词的备注", text: $draftNote, axis: .vertical)
                Button("取消", role: .cancel) { editingNoteFor = nil }
                Button("保存") {
                    if let item = editingNoteFor {
                        store.updateNote(id: item.id, note: draftNote)
                    }
                    editingNoteFor = nil
                }
            } message: {
                Text("备注只有你自己看得到，不影响生词判定。")
            }
        }
    }

    private var noteBinding: Binding<Bool> {
        Binding(
            get: { editingNoteFor != nil },
            set: { if !$0 { editingNoteFor = nil } }
        )
    }

    // MARK: - 区块

    /// 词频表缺失时必须显式说清楚。
    /// 否则用户会看到"一个生词都没有"，以为是自己的材料太简单 ——
    /// 而真实原因是判据本身没装进来。
    private var frequencyMissingSection: some View {
        Section {
            Label("生词判定不可用：词频表未打进安装包", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        } footer: {
            Text("生词判定依赖一份内置的英语词频表。它缺失时不会误标，但也不会标出任何生词。"
                + "请确认使用的是 CI 构建的安装包（词频表由 CI 下载并打包）。")
        }
    }

    private var emptySection: some View {
        Section {
            Text("生词本还是空的。\n\n到「记录」里打开一次录音，展开文字稿，"
                + "每句下方会列出该句的生词 —— 点一下就能收进来。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statisticsSection: some View {
        Section {
            HStack {
                statistic("共收录", "\(store.totalCount)")
                Divider()
                statistic("已掌握", "\(store.masteredCount)")
                Divider()
                statistic("待复习", "\(store.pendingCount)")
            }
        }
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlsSection: some View {
        Section {
            Picker("排序", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("隐藏已掌握", isOn: $hidesMastered)
        }
    }

    private var vocabularySection: some View {
        Section {
            ForEach(visibleItems) { item in
                vocabularyRow(item)
            }
            .onDelete(perform: store.remove)
        } header: {
            Text(hidesMastered ? "待复习（\(visibleItems.count)）" : "全部（\(visibleItems.count)）")
        } footer: {
            Text("点左侧圆圈标记已掌握，左滑删除。生词本与录音分开保存 —— "
                + "录音按保留期清理时，生词本不会受影响。")
        }
    }

    private var visibleItems: [VocabularyItem] {
        let includeMastered = !hidesMastered
        switch sortMode {
        case .time: return store.sortedByTime(includeMastered: includeMastered)
        case .difficulty: return store.sortedByDifficulty(includeMastered: includeMastered)
        }
    }

    private func vocabularyRow(_ item: VocabularyItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.word)
                    .font(.headline)
                    .foregroundStyle(item.mastered ? .secondary : .primary)
                    .strikethrough(item.mastered, color: .secondary)

                Text(item.difficultyText)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.toggleMastered(id: item.id)
                } label: {
                    Image(systemName: item.mastered ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.mastered ? .green : .secondary)
                }
                .buttonStyle(.borderless)
            }

            if !item.note.isEmpty {
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            if let sentence = item.sourceSentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Text(item.addedAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("备注") {
                    draftNote = item.note
                    editingNoteFor = item
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    /// 导出区。
    ///
    /// 这里也是设置里那个「允许导出」开关的**唯一落点** ——
    /// 此前它只在 `AppSettings` 里声明，既没有界面也没有实现。
    /// 一个有开关、有文案、却什么都不做的设置项，是最容易被发现的缺陷。
    private var exportSection: some View {
        Section {
            if !settings.exportEnabled {
                Text("导出已在「设置 → 学习」中关闭。生词本本身不受影响，只是不生成导出文件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let exportError {
                Text(exportError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if store.items.isEmpty {
                Text("还没有生词，暂无可导出内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("点右上角分享按钮导出。表格为制表符分隔，用 Anki 的「导入文件」直接选它即可 ——"
                    + "列顺序是：词形 / 难度 / 备注 / 来源句 / 来源。"
                    + "注意首行就是数据、不是表头（Anki 按顺序映射字段，给表头会多出一张脏卡片）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("导出")
        }
    }

    /// 生成导出文件。
    private func prepareExport() {
        exportFiles = []
        exportError = nil
        guard settings.exportEnabled else { return }

        let items = store.sortedByTime(includeMastered: true)
        guard !items.isEmpty else { return }

        // 会话标题映射：导出里写「某次会议的标题」比写一个 sessionId 有用得多
        var titles: [String: String] = [:]
        for manifest in RecordingLibrary.shared.listSessions() {
            titles[manifest.id] = manifest.title
        }

        var files: [ExportFile] = []

        let csv = VocabularyExporter.ankiCSV(items: items, sessionTitles: titles)
        if let url = VocabularyExporter.writeToTemporaryFile(
            contents: csv,
            fileName: VocabularyExporter.fileName(withExtension: "csv")
        ) {
            files.append(ExportFile(title: "表格（Anki 导入用）", url: url))
        }

        let markdown = VocabularyExporter.markdown(items: items, sessionTitles: titles)
        if let url = VocabularyExporter.writeToTemporaryFile(
            contents: markdown,
            fileName: VocabularyExporter.fileName(withExtension: "md")
        ) {
            files.append(ExportFile(title: "Markdown（可直接阅读）", url: url))
        }

        if files.isEmpty {
            exportError = "导出文件生成失败，详见日志。"
        }
        exportFiles = files
    }

    private var aboutSection: some View {
        Section("生词是怎么判定的") {
            Text("判据是词频，不是 AI：一个词只含拉丁字母、长度 ≥ 3、"
                + "不是句中首字母大写（专有名词启发式）、且排名在常用词之外，就标为生词。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            // 水平档必须在这里说出来：同样的材料在不同档位下会得到不同的生词表，
            // 不显示当前档位的话，用户会以为自己看到的判定结果是"客观事实"
            Text("当前水平档：\(settings.vocabularyLevel.title) —— \(settings.vocabularyLevel.detail)。"
                + "可在「设置 → 学习」里调整；改档会改变这里的判定结果。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("用词频而非 AI 的理由：结果永远一致。"
                + "同一句话昨天不是生词、今天变成生词，会直接毁掉复习计划。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("已知会把这些人名/地名/拼写错误的词也标出来 —— "
                + "它们被判为生词其实无害（确实是你不认识的词），"
                + "只是需要你自己忽略。目前只支持英语：中文/日语需要形态素分词，尚未实现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    VocabularyView()
}
