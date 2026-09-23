import Foundation

/// 生词候选。
struct VocabularyCandidate: Identifiable, Hashable {

    /// 归一化后的词（小写）—— 作为生词本的键
    let word: String
    /// 原文中出现过的形式（如 "running"），用于展示
    let surface: String
    /// 词表排名；nil 表示不在前 1 万词内
    let rank: Int?
    /// 在本次材料里出现了几次
    let occurrences: Int

    var id: String { word }

    var difficultyText: String {
        guard let rank else { return "词表之外" }
        switch rank {
        case ...1000: return "极常用（第 \(rank)）"
        case ...3000: return "常用（第 \(rank)）"
        case ...6000: return "较少见（第 \(rank)）"
        default: return "罕见（第 \(rank)）"
        }
    }
}

/// 生词提取（M6）。
///
/// ## 判定规则（全部可解释，没有黑盒）
/// 一个词被当作生词，当且仅当满足：
///   1. 只含拉丁字母（见 `isLatinWordCharacter` 的说明）
///   2. 长度 ≥ 3
///   3. 不是"句中首字母大写"的词（专有名词启发式）
///   4. 词表排名 > 阈值，或**根本不在词表内**
///
/// 这四条都能向用户解释清楚 —— 学习工具里，"为什么这个词被标出来了"
/// 必须能回答，否则用户无法信任它（也无法判断是自己不会还是工具错了）。
///
/// ## 已知噪声（诚实记录，不掩盖）
///   · **专有名词**：人名/地名会被判为生词。已用"句中首字母大写"压掉一部分，
///     但全小写的专有名词（如产品名）仍会漏进来。
///   · **专业术语**：术语必然低频，被判为生词其实是合理的 —— 它确实是生词。
///   · **拼写错误**：识别错误的词也不在词表里，同样会被标出。
///
/// 这些噪声的代价是"多标了几个词"，而不是"漏标" ——
/// 对学习工具来说这个方向是安全的（漏标才会让用户以为已经掌握了）。
enum VocabularyExtractor {

    struct Options {
        /// 排名超过此值即视为候选生词。
        /// 默认 3000：大致对应"四六级之上"，是学习者最值得投入的区间。
        var rankThreshold = 3000
        /// 过短的词不参与判定（"a" / "of" 没有学习价值，且极易误判）
        var minimumLength = 3
        /// 至少出现几次才收
        var minimumOccurrences = 1
        /// 是否启用专有名词启发式
        var ignoreProperNouns = true
        /// 生词判定总开关（当前只对英语有效，见 WordFrequencyTable 的边界说明）
        var enabled = true

        init() {}
    }

    /// 从整段文字提取生词候选。
    ///
    /// 注意：这里把每段转写当作独立句子处理（见 `sentences(in:)` 的说明），
    /// 因此每段的**第一个词**不会被专有名词启发式排除 ——
    /// 因为我们无法判断它在原句里是否处于句首。
    static func extract(from segments: [TranscriptSegment], options: Options = Options()) -> [VocabularyCandidate] {
        let text = segments.map { $0.text }.joined(separator: "\n")
        return extract(from: text, options: options)
    }

    static func extract(from text: String, options: Options = Options()) -> [VocabularyCandidate] {
        guard options.enabled, WordFrequencyTable.shared.isReady else { return [] }

        var counts: [String: Int] = [:]
        var surfaces: [String: String] = [:]

        for sentence in sentences(in: text) {
            let tokens = latinTokens(in: sentence)
            for (index, token) in tokens.enumerated() {
                let lower = token.lowercased()
                guard lower.count >= options.minimumLength else { continue }

                // 专有名词启发式：句中首字母大写（句首词除外）。
                // 专有名词会被词表判成"生词"，但对学习没有价值，
                // 且在对话里会反复出现、噪声很大 —— 所以直接排除。
                if options.ignoreProperNouns,
                   index > 0,
                   token.first?.isUppercase == true {
                    continue
                }

                counts[lower, default: 0] += 1
                if surfaces[lower] == nil { surfaces[lower] = token }
            }
        }

        var result: [VocabularyCandidate] = []
        for (word, occurrences) in counts where occurrences >= options.minimumOccurrences {
            let rank = WordFrequencyTable.shared.rank(of: word)
            // 在词表里且排名靠前 → 不是生词
            if let rank, rank <= options.rankThreshold { continue }
            result.append(
                VocabularyCandidate(
                    word: word,
                    surface: surfaces[word] ?? word,
                    rank: rank,
                    occurrences: occurrences
                )
            )
        }

        // 排序：越生僻越靠前；同档按出现次数；再按字母序保证稳定
        return result.sorted { lhs, rhs in
            let lhsRank = lhs.rank ?? Int.max
            let rhsRank = rhs.rank ?? Int.max
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.occurrences != rhs.occurrences { return lhs.occurrences > rhs.occurrences }
            return lhs.word < rhs.word
        }
    }

    // MARK: - 切词

    /// 按句末标点与换行切句。
    ///
    /// 切句的目的**不是理解语义**，而只是为了让专有名词启发式有"句首"可言 ——
    /// 句首词的首字母大写是正常的，不能据此判为专有名词。
    private static func sentences(in text: String) -> [String] {
        text.split(whereSeparator: { "。！？.!?\n".contains($0) }).map(String.init)
    }

    /// 拉丁文字切词：按非字母切分，但保留词内的连字符与撇号
    /// （"well-known" 是一个词，"don't" 是一个词）。
    static func latinTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        for character in text {
            if isLatinWordCharacter(character) {
                current.append(character)
            } else if isInnerConnector(character), !current.isEmpty {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }

        return tokens
            .map { token in
                var trimmed = token
                while let first = trimmed.first, isInnerConnector(first) { trimmed.removeFirst() }
                while let last = trimmed.last, isInnerConnector(last) { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    private static func isInnerConnector(_ character: Character) -> Bool {
        character == "-" || character == "'" || character == "’"
    }

    /// 是否算作"拉丁单词的一部分"。
    ///
    /// **必须排除 CJK**：`Character.isLetter` 对汉字、假名、谚文同样返回 true，
    /// 而中文句子没有空格 —— 若不排除，一整句中文会被切成一个超长"单词"，
    /// 然后因为"不在词表里"被判成生词。那会让界面在中文材料上满屏生词。
    private static func isLatinWordCharacter(_ character: Character) -> Bool {
        guard character.isLetter else { return false }
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        if (0x2E80...0x9FFF).contains(value) { return false }   // CJK 部首、假名、统一表意文字
        if (0xAC00...0xD7AF).contains(value) { return false }   // 谚文
        if (0xF900...0xFAFF).contains(value) { return false }   // CJK 兼容表意文字
        if (0xFF00...0xFFEF).contains(value) { return false }   // 全角字符
        return true
    }
}
