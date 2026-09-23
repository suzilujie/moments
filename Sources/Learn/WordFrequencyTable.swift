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
/// ## 数据来源
/// 内置 google-10000-english（英语按频率排序的 1 万词，约 74 KB），
/// 由 CI 下载后随 ipa 打包（见 .github/workflows/ios-build.yml）。
/// 体积可忽略，且它一旦确定就不会变 —— 这是"可复现"的前提。
///
/// ## 已知边界（必须说清楚）
/// **只支持英语**。中文/日语的生词判定需要形态素分析（分词），
/// 而本项目没有引入 MeCab 一类分词器的计划 —— 见 VocabularyExtractor 的说明。
final class WordFrequencyTable {

    static let shared = WordFrequencyTable()

    enum Availability: Equatable {
        /// 已就绪，词表规模已知
        case ready(words: Int)
        /// 资源缺失（构建时未打进包）
        case missing
        /// 读取失败
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var text: String {
            switch self {
            case .ready(let words): return "已加载 \(words) 词"
            case .missing: return "缺失（未打进包）"
            case .failed(let reason): return "读取失败：\(reason)"
            }
        }
    }

    private(set) var availability: Availability = .missing

    /// 词 → 排名（从 1 开始，1 表示最高频）
    private var ranks: [String: Int] = [:]

    private let lock = NSLock()
    private var didLoad = false

    private init() {}

    var isReady: Bool { availability.isReady }

    var wordCount: Int { ranks.count }

    /// 随包资源文件名（CI 下载时即按此命名）
    static let resourceFileName = "en_top10k.txt"

    func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didLoad else { return }
        didLoad = true

        let url = Bundle.main.bundleURL.appendingPathComponent(Self.resourceFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            availability = .missing
            Log.shared.warn(.asr, "词频表缺失（\(Self.resourceFileName)），生词判定不可用")
            return
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var table: [String: Int] = [:]
            var rank = 0
            for line in content.split(separator: "\n") {
                let word = line.trimmingCharacters(in: .whitespaces).lowercased()
                guard !word.isEmpty else { continue }
                rank += 1
                // 词表本身有序（按频率降序），行号即排名。
                // 重复词只保留首次出现（即更高频的那次）。
                if table[word] == nil { table[word] = rank }
            }
            // 注意：rank 是用**行号**累计的，跳过的空行不会影响相对次序
            ranks = table
            availability = .ready(words: table.count)
            Log.shared.info(.asr, "词频表已加载｜\(table.count) 词")
        } catch {
            availability = .failed(error.localizedDescription)
            Log.shared.error(.asr, "词频表读取失败｜\(error.localizedDescription)")
        }
    }

    /// 查一个词的排名。查不到返回 nil（表示不在前 1 万词内）。
    ///
    /// 内部会尝试几种最小化的词形还原，**且只在还原结果确实存在于词表时才采用** ——
    /// 见 `candidates(for:)` 的说明。
    func rank(of word: String) -> Int? {
        loadIfNeeded()
        for candidate in candidates(for: word.lowercased()) {
            if let rank = ranks[candidate] { return rank }
        }
        return nil
    }

    /// 极简词形还原的候选序列（原形优先）。
    ///
    /// **刻意不做完整词干化**（Porter / Snowball）：那类算法会把语义无关的词
    /// 归到同一词干（如 universe / universal / university），
    /// 而本用途是"查排名" —— **误归类比不归类更糟**，
    /// 因为它会把生词当成常用词而漏掉（漏判是无声的，用户不会发现）。
    ///
    /// 因此这里只处理英语里最常见、歧义最小的几种后缀，
    /// 并且由 `rank(of:)` 保证"只有真的能在词表里查到才采用"。
    func candidates(for word: String) -> [String] {
        var result = [word]
        let lower = word

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
}
