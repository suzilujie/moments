import Foundation

/// 生词本条目。
struct VocabularyItem: Codable, Identifiable {

    /// 归一化词形（小写）—— 作为主键，避免 "Run" / "run" 存成两条
    var id: String
    /// 展示形式
    var word: String
    var addedAtMs: Int64
    /// 从哪次会话收进来的（可空：用户也可以手动加词）
    var sourceSessionId: String?
    /// 收录时的原句 —— 保留语境是背单词最需要的东西，
    /// 孤立的一个词记不住，而"我当时在聊什么"能记住。
    var sourceSentence: String?
    /// 收录时的词表排名（nil 表示词表之外）
    var rank: Int?
    /// 用户自己的注释
    var note: String
    /// 是否已标记为掌握
    var mastered: Bool
    /// 复习次数（为将来的复习计划留字段）
    var reviewCount: Int

    var addedAt: Date {
        Date(timeIntervalSince1970: Double(addedAtMs) / 1000.0)
    }

    var difficultyText: String {
        guard let rank else { return "词表之外" }
        switch rank {
        case ...1000: return "极常用"
        case ...3000: return "常用"
        case ...6000: return "较少见"
        default: return "罕见"
        }
    }

    /// 排序用的可比较值：越大越"生"
    var difficultyRank: Int { rank ?? Int.max }
}

/// 生词本（M6 的核心学习资产）。
///
/// ## 为什么存 JSON 而不是进 SQLite
/// 与声纹库（M3c）同理：生词本是**用户长期积累的资产**，
/// 不是可以从别处重建的索引。放进 SQLite 也可以，但那样它就会与
/// "数据库可整库重建"的策略纠缠在一起（见 SearchIndex 的架构说明）——
/// 一旦哪天重建逻辑写错，赔掉的是用户几个月的积累。
/// 单独一个 JSON 文件，边界清楚、坏了也只坏这一个文件。
///
/// ## 位置
/// `Application Support/Moments/Vocabulary/vocabulary.json`
/// **刻意与音频目录分开**：音频会按保留期清理，生词本不会也不该。
@MainActor
final class VocabularyStore: ObservableObject {

    static let shared = VocabularyStore()

    @Published private(set) var items: [VocabularyItem] = []

    private let queue = DispatchQueue(label: "com.xfish.moments.vocabulary", qos: .utility)

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder = JSONDecoder()

    private init() {
        reload()
    }

    // MARK: - 路径与读写

    var fileURL: URL? {
        (try? AppPaths.vocabularyDirectory())?.appendingPathComponent("vocabulary.json")
    }

    func reload() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        do {
            items = try decoder.decode([VocabularyItem].self, from: data)
                .sorted { $0.addedAtMs > $1.addedAtMs }
        } catch {
            // 损坏时不静默清空：留下日志，原文件保留以便人工抢救
            Log.shared.error(.storage, "生词本解析失败｜\(error.localizedDescription)｜原文件保留未动")
            items = []
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = items

        // 与声纹库同理：**在进入后台队列前完成编码**。
        // encoder 是本 @MainActor 类型的属性，在后台闭包里引用它属隔离违规
        // （Swift 6 下是错误）。顺带编码也不占用主线程。
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            Log.shared.error(.storage, "生词本编码失败｜\(error.localizedDescription)")
            return
        }

        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.shared.error(.storage, "生词本写入失败｜\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 增删改

    func contains(_ word: String) -> Bool {
        items.contains { $0.id == word.lowercased() }
    }

    /// 收词。- Returns: true 表示新增，false 表示已存在（不重复收）
    @discardableResult
    func add(
        word: String,
        displayWord: String? = nil,
        sourceSessionId: String? = nil,
        sourceSentence: String? = nil,
        rank: Int? = nil
    ) -> Bool {
        let key = word.lowercased()
        guard !key.isEmpty else { return false }
        guard !contains(key) else { return false }

        items.insert(
            VocabularyItem(
                id: key,
                word: displayWord ?? word,
                addedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                sourceSessionId: sourceSessionId,
                sourceSentence: sourceSentence,
                rank: rank,
                note: "",
                mastered: false,
                reviewCount: 0
            ),
            at: 0
        )
        persist()
        Log.shared.info(.storage, "生词已收录｜\(key)｜累计 \(items.count) 条")
        return true
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets where items.indices.contains(index) {
            items.remove(at: index)
        }
        persist()
    }

    func toggleMastered(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].mastered.toggle()
        persist()
    }

    func updateNote(id: String, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].note = note
        persist()
    }

    func clear() {
        items = []
        persist()
        Log.shared.info(.storage, "生词本已清空")
    }

    // MARK: - 统计与筛选

    var totalCount: Int { items.count }

    var masteredCount: Int { items.filter { $0.mastered }.count }

    var pendingCount: Int { totalCount - masteredCount }

    /// 按难度排序（越生僻越靠前）
    func sortedByDifficulty(includeMastered: Bool = true) -> [VocabularyItem] {
        items
            .filter { includeMastered || !$0.mastered }
            .sorted { lhs, rhs in
                if lhs.difficultyRank != rhs.difficultyRank { return lhs.difficultyRank > rhs.difficultyRank }
                return lhs.addedAtMs > rhs.addedAtMs
            }
    }

    /// 按收录时间排序（最新在前）
    func sortedByTime(includeMastered: Bool = true) -> [VocabularyItem] {
        items
            .filter { includeMastered || !$0.mastered }
            .sorted { $0.addedAtMs > $1.addedAtMs }
    }

    func summary() -> String {
        "\(totalCount) 词｜已掌握 \(masteredCount)｜待复习 \(pendingCount)"
    }

    /// 全部生词（供会话详情的"本句生词是否已在生词本"判断，避免逐词线性查找）
    var wordSet: Set<String> {
        Set(items.map { $0.id })
    }
}
