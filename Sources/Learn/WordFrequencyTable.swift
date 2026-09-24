import Foundation

/// 词频表（M6）—— 「生词判定」的数据基础。
///
/// ## 为什么用词频而不是 LLM 判生词
/// "这个词对学习者算不算生词"本质上是一个**词频问题**，不是语义问题：
/// 母语者与学习者的差别集中在低频词上。
///
/// 用 LLM 判生词有三个问题，而学习材料恰恰最怕第三点：
///   1) 慢 —— 一句一次推理，几百句的会话不可接受；
///   2) 要联网 —— 与"纯离线"定位冲突；
///   3) **不可复现** —— 同一句话两次跑可能给出不同判断，
///      而"今天标出的生词明天变了"会直接毁掉复习计划。
///
/// 一张固定词表则完全反过来：离线、微秒级、**结果永远一致**。
///
/// ## 数据来源（由 CI 下载后随 ipa 打包）
///   · 英语：google-10000-english（按频率排序的一万词，约 74 KB）
///   · 中文：jieba 词典（词 + 词频），CI 里**显式按词频降序排序后取前 2 万**再打包
///
/// 中文那份刻意在 CI 里重排，而不是直接信上游文件顺序：
/// 上游并未承诺 dict.txt 按词频排序，一旦它变了，行号就不再等于排名，
/// 而生词判定会**静默地全错**（每个词都标成生词，或全都不标）。这类错误
/// 在真机上看起来只是"标得有点多"，极难追查 —— 因此宁可多一步 sort。
///
/// ## 已知边界
/// 只支持已经备好词表的语言（当前：英语、中文）。
/// 其它语言（如日语）没有词表，判定会**关闭并明确提示**，
/// 而不是拿另一门语言的词表去判 —— 那会把每个词都标成生词。
final class WordFrequencyTable {

    static let shared = WordFrequencyTable()

    /// 支持的语言 → 资源文件名
    struct Catalog {
        let code: String
        let title: String
        let fileName: String

        /// 词表规模上限（用于说明，也用于自检）
        var note: String { "\(title)（\(fileName)）" }
    }

    static let catalog: [Catalog] = [
        Catalog(code: "en", title: "英语", fileName: "en_top10k.txt"),
        Catalog(code: "zh", title: "中文", fileName: "zh_top20k.txt")
    ]

    static func catalogEntry(for language: String) -> Catalog? {
        let primary = primaryCode(language)
        return catalog.first { $0.code == primary }
    }

    /// 取主语言代码（`zh-Hans` → `zh`）
    static func primaryCode(_ language: String) -> String {
        String(language.split(separator: "-").first ?? "").lowercased()
    }

    enum Availability: Equatable {
        /// 已就绪，词表规模已知
        case ready(words: Int)
        /// 该语言没有词表（不是"资源缺失"，而是"我们本来就不支持"）
        case unsupported
        /// 资源缺失（构建时未打进包）
        case missing
        /// 读取失败
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        func text(languageTitle: String) -> String {
            switch self {
            case .ready(let words): return "\(languageTitle)已加载 \(words) 词"
            case .unsupported: return "\(languageTitle)无词表（判定不可用）"
            case .missing: return "\(languageTitle)词表缺失（未打进包）"
            case .failed(let reason): return "\(languageTitle)词表读取失败：\(reason)"
            }
        }
    }

    /// 语言 → 词 → 排名（从 1 开始）
    private var ranks: [String: [String: Int]] = [:]
    private var states: [String: Availability] = [:]

    private let lock = NSLock()

    private init() {}

    /// 载入某语言的词表（幂等）。
    @discardableResult
    func load(language: String) -> Availability {
        let code = Self.primaryCode(language)

        lock.lock()
        defer { lock.unlock() }

        if let existing = states[code] { return existing }

        guard let entry = Self.catalogEntry(for: code) else {
            states[code] = .unsupported
            return .unsupported
        }

        let url = Bundle.main.bundleURL.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            states[code] = .missing
            Log.shared.warn(.asr, "词频表缺失（\(entry.fileName)），\(entry.title)生词判定不可用")
            return .missing
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var table: [String: Int] = [:]
            var rank = 0
            for line in content.split(separator: "\n") {
                let word = line.trimmingCharacters(in: .whitespaces).lowercased()
                guard !word.isEmpty else { continue }
                rank += 1
                // 文件本身按频率降序排列，行号即排名。
                // 重复词只保留首次出现（即更高频的那次）。
                if table[word] == nil { table[word] = rank }
            }
            ranks[code] = table
            states[code] = .ready(words: table.count)
            Log.shared.info(.asr, "词频表已加载｜\(entry.title)｜\(table.count) 词")
            return states[code]!
        } catch {
            states[code] = .failed(error.localizedDescription)
            Log.shared.error(.asr, "词频表读取失败｜\(entry.fileName)｜\(error.localizedDescription)")
            return states[code]!
        }
    }

    func availability(language: String) -> Availability {
        let code = Self.primaryCode(language)
        // 读缓存要持锁，但**不能把 load 包在锁里** ——
        // NSLock 不可重入，而 load 自己也要取同一把锁，那样会直接死锁。
        lock.lock()
        let cached = states[code]
        lock.unlock()
        if let cached { return cached }
        return load(language: language)
    }

    func isReady(language: String) -> Bool {
        availability(language: language).isReady
    }

    /// 查一个词在某语言词表里的排名。查不到返回 nil（表示不在词表内）。
    ///
    /// 英文会尝试几种最小化的词形还原，**且只在还原结果确实存在于词表时才采用** ——
    /// 见 `candidates(for:)` 的说明。
    func rank(of word: String, language: String) -> Int? {
        let code = Self.primaryCode(language)
        // 先确保已载入（load 会自己取锁），再持锁读一次快照 —— 顺序不能反，否则死锁
        _ = load(language: code)

        lock.lock()
        let table = ranks[code]
        lock.unlock()

        guard let table else { return nil }
        for candidate in candidates(for: word, language: code) {
            if let rank = table[candidate] { return rank }
        }
        return nil
    }

    /// 各语言状态汇总（自检页展示用）
    var summary: String {
        // 注意是 Self.catalog：catalog 是静态成员，
        // 在实例方法里直接写 `catalog` 会编译不过
        Self.catalog.map { entry in
            let state = availability(language: entry.code)
            switch state {
            case .ready(let words): return "\(entry.code) \(words) 词"
            case .unsupported: return "\(entry.code) 不支持"
            case .missing: return "\(entry.code) 缺失"
            case .failed: return "\(entry.code) 失败"
            }
        }
        .joined(separator: "｜")
    }

    // MARK: - 词形还原

    /// 词形还原的候选序列（原形优先）。CJK 不做还原。
    func candidates(for word: String, language: String) -> [String] {
        let lower = word.lowercased()
        guard Self.primaryCode(language) == "en" else { return [lower] }

        var result = [lower]

        // 所有格
        if lower.hasSuffix("'s") || lower.hasSuffix("’s") {
            result.append(String(lower.dropLast(2)))
        }
        // 复数 / 三单
        if lower.hasSuffix("ies"), lower.count > 4 {
            result.append(String(lower.dropLast(3)) + "y")   // studies → study
        }
        if lower.hasSuffix("es"), lower.count > 3 {
            result.append(String(lower.dropLast(2)))          // boxes → box
        }
        if lower.hasSuffix("s"), lower.count > 2 {
            result.append(String(lower.dropLast(1)))          // runs → run
        }
        // 过去式 / 过去分词
        if lower.hasSuffix("ed"), lower.count > 3 {
            let stem = String(lower.dropLast(2))
            result.append(stem)                                // walked → walk
            result.append(String(lower.dropLast(1)))           // used → use
            if let last = stem.last, stem.count > 2, stem.dropLast().last == last {
                result.append(String(stem.dropLast()))         // stopped → stop
            }
        }
        // 进行式
        if lower.hasSuffix("ing"), lower.count > 4 {
            let stem = String(lower.dropLast(3))
            result.append(stem)                                // walking → walk
            result.append(stem + "e")                          // making → make
            if let last = stem.last, stem.count > 2, stem.dropLast().last == last {
                result.append(String(stem.dropLast()))         // running → run
            }
        }
        // 副词
        if lower.hasSuffix("ly"), lower.count > 4 {
            result.append(String(lower.dropLast(2)))           // quickly → quick
        }

        return result
    }

    /// 极简词形还原的说明（保留在代码里，因为它解释了"为什么不做完整词干化"）：
    ///
    /// 刻意不做完整词干化（Porter / Snowball）：那类算法会把语义无关的词
    /// 归到同一词干（如 universe / universal / university），
    /// 而本用途是"查排名" —— **误归类比不归类更糟**，
    /// 因为它会把生词当成常用词而漏掉（漏判是无声的，用户不会发现）。
    /// 因此只处理英语里最常见、歧义最小的几种后缀，
    /// 并且由 `rank(of:language:)` 保证"只有真的能在词表里查到才采用"。
}
