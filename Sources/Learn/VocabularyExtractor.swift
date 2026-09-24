import Foundation
import NaturalLanguage

/// 生词候选。
struct VocabularyCandidate: Identifiable, Hashable {

    /// 归一化后的词（小写、仅字母）—— 作为生词本的键
    let word: String
    /// 原文中出现过的形式（如 "running" / "don't"），用于展示
    let surface: String
    /// 词表排名；nil 表示不在词表内
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
///   1. 至少含一个字母（纯数字与标点不参与）
///   2. 长度达到该语言的下限（拉丁 3、CJK 1，见 Options 的说明）
///   3. 不是"句中首字母大写"的词（专有名词启发式，**仅对有大写的文字生效**）
///   4. 词表排名 > 阈值，或**根本不在词表内**
///
/// 这四条都能向用户解释清楚 —— 学习工具里，"为什么这个词被标出来了"
/// 必须能回答，否则用户无法信任它（也无法判断是自己不会还是工具错了）。
///
/// ## 关于 CJK 分词：纠正一处此前的误判
/// 上一版把中文生词判定列为"不做"，理由是"中文需要形态素分析，
/// 得引入 MeCab 一类分词器"。**这个判断是错的**：系统自带 `NLTokenizer`，
/// 零依赖、离线、随系统更新 —— 设计文档 8.5 写的也正是它。
/// 现在改为按语言分流：拉丁文字走自写的切词（轻、可控），
/// CJK 走 `NLTokenizer`。
///
/// ## 已知噪声（诚实记录，不掩盖）
///   · **专有名词**：人名/地名会被判为生词。已用"句中首字母大写"压掉一部分，
///     但全小写的专有名词（如产品名）仍会漏进来；中文完全没有大小写可依，故此项无法压。
///   · **专业术语**：术语必然低频，被判为生词其实是合理的 —— 它确实是生词。
///   · **拼写错误**：识别错误的词也不在词表里，同样会被标出。
///   · **缩写与连字符**：为了查表，key 会去掉撇号与连字符（"don't" → "dont"），
///     因此收缩形式可能因查不到而偶被误标。展示用的 surface 保留原形。
enum VocabularyExtractor {

    struct Options {
        /// 排名超过此值即视为候选生词。
        /// 默认 3000：大致对应"四六级之上"，是学习者最值得投入的区间。
        /// 实际生效值由用户选择的水平档覆盖（见 VocabularyLevel）。
        var rankThreshold = 3000
        /// 拉丁文字的最短词长。3 以下没有学习价值（"a" / "of"），且极易误判。
        var latinMinimumLength = 3
        /// CJK 的最短词长。**必须放宽到 1** ——
        /// 中文里单字词（了 / 的 / 很 / 好）是正常词汇，
        /// 用 3 会把几乎所有词直接过滤掉，判定就完全失效了。
        var cjkMinimumLength = 1
        /// 至少出现几次才收
        var minimumOccurrences = 1
        /// 是否启用专有名词启发式（只对有大写的文字有效）
        var ignoreProperNouns = true
        /// 生词判定总开关
        var enabled = true

        init() {}
    }

    // MARK: - 对外入口

    /// 从整段转写提取生词候选。
    ///
    /// - Parameter language: 材料语言（`en` / `zh` / `zh-Hans` …）。
    ///   该语言必须有词表，否则返回空数组 —— **这是刻意的**：
    ///   拿一门语言的词表去判另一门语言，会把每个词都标成生词。
    static func extract(
        from segments: [TranscriptSegment],
        language: String,
        options: Options = Options()
    ) -> [VocabularyCandidate] {
        let text = segments.map { $0.text }.joined(separator: "\n")
        return extract(from: text, language: language, options: options)
    }

    static func extract(
        from text: String,
        language: String,
        options: Options = Options()
    ) -> [VocabularyCandidate] {
        guard options.enabled,
              WordFrequencyTable.shared.isReady(language: language) else { return [] }

        let cjk = isCJKLanguage(language)
        let minimumLength = cjk ? options.cjkMinimumLength : options.latinMinimumLength

        var counts: [String: Int] = [:]
        var surfaces: [String: String] = [:]

        for sentence in sentences(in: text) {
            for scanned in scan(sentence, cjk: cjk) {
                guard scanned.key.count >= minimumLength else { continue }

                // 专有名词启发式：句中首字母大写（句首词除外）。
                // 专有名词会被词表判成"生词"，但对学习没有价值，
                // 且在对话里会反复出现、噪声很大 —— 所以直接排除。
                // CJK 无大小写可依，此项自动跳过。
                if !cjk,
                   options.ignoreProperNouns,
                   !scanned.atSentenceStart,
                   scanned.display.first?.isUppercase == true {
                    continue
                }

                counts[scanned.key, default: 0] += 1
                if surfaces[scanned.key] == nil { surfaces[scanned.key] = scanned.display }
            }
        }

        var result: [VocabularyCandidate] = []
        for (word, occurrences) in counts where occurrences >= options.minimumOccurrences {
            let rank = WordFrequencyTable.shared.rank(of: word, language: language)
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

    private struct Scanned {
        /// 归一化比较键（小写、仅字母）
        let key: String
        /// 原文形式
        let display: String
        let atSentenceStart: Bool
    }

    private static func scan(_ sentence: String, cjk: Bool) -> [Scanned] {
        if cjk {
            return nlTokens(in: sentence).map {
                Scanned(key: normalize($0), display: $0, atSentenceStart: false)
            }
        }
        return latinTokens(in: sentence).enumerated().map { index, token in
            Scanned(key: normalize(token), display: token, atSentenceStart: index == 0)
        }
    }

    /// 归一化：小写 + 只留字母。
    ///
    /// **界面高亮与词表查找必须用同一个归一化规则**，否则会出现
    /// "标注出来了但高亮不上"这种自相矛盾的表现（此前 `don't` 就是如此：
    /// 判定用的键带撇号、高亮用的键不带，两者永远匹配不上）。
    /// 去掉撇号与连字符还有一个好处：查表时不会因为收缩形式而漏掉常见词。
    static func normalize(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter }
    }

    static func isCJKLanguage(_ language: String) -> Bool {
        switch WordFrequencyTable.primaryCode(language) {
        case "zh", "ja", "ko": return true
        default: return false
        }
    }

    // MARK: - 切词

    /// 用系统分词器切 CJK。返回**词元字符串**（需要位置请用 `locateNLTokens`）。
    static func nlTokens(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(nlLanguage(for: text))
        tokenizer.string = text

        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            if raw.contains(where: { $0.isLetter }) { result.append(raw) }
            return true
        }
        return result
    }

    /// `NLTokenizer` 需要显式语言才能正确切分（否则按当前区域猜，中文可能被逐字切开）。
    private static func nlLanguage(for text: String) -> NLLanguage {
        // 由文本自身判定：调用点未必知道语言，而分词器知道。
        // 注意这里只是给分词器一个提示，**词表选择仍由调用方显式给定的语言决定** ——
        // 两件事不能混：猜错语言最多切分差一点，用错词表则会让判定整体失效。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .simplifiedChinese
    }

    /// 扫描出所有词元及其位置（界面做生词高亮用）。
    ///
    /// **为什么必须带位置**：界面要高亮生词，就得把原句切成"词 / 非词"交替来着色。
    /// 若只拿词列表重新拼接，会丢掉标点与空格（中文句子会被拼坏）——
    /// 而学习材料一旦显示得和原文不一样，就失去对照价值了。
    static func locateTokens(in text: String, language: String) -> [LocatedToken] {
        isCJKLanguage(language) ? locateNLTokens(in: text) : locateLatinTokens(in: text)
    }

    /// 词元及其在原文中的位置
    struct LocatedToken {
        /// 原文形式（保留撇号与连字符）
        let text: String
        /// 归一化比较键（与 VocabularyCandidate.word 同一规则）
        let key: String
        let range: Range<String.Index>
    }

    private static func locateNLTokens(in text: String) -> [LocatedToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(nlLanguage(for: text))
        tokenizer.string = text

        var result: [LocatedToken] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            if raw.contains(where: { $0.isLetter }) {
                result.append(LocatedToken(text: raw, key: normalize(raw), range: range))
            }
            return true
        }
        return result
    }

    private static func locateLatinTokens(in text: String) -> [LocatedToken] {
        var result: [LocatedToken] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard isLatinWordCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }

            let start = index
            var end = index
            while end < text.endIndex {
                let character = text[end]
                if isLatinWordCharacter(character) {
                    end = text.index(after: end)
                } else if isInnerConnector(character),
                          text.index(after: end) < text.endIndex,
                          isLatinWordCharacter(text[text.index(after: end)]) {
                    // 词内的连字符/撇号：只有后面还跟着字母才算这个词的一部分。
                    // 否则 "well-" 末尾那个连字符会被并进词里，导致查表查不到。
                    end = text.index(after: end)
                } else {
                    break
                }
            }

            let raw = String(text[start..<end])
            let key = normalize(raw)
            if !key.isEmpty {
                result.append(LocatedToken(text: raw, key: key, range: start..<end))
            }
            index = end
        }

        return result
    }

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
    /// （CJK 现在有 NLTokenizer 负责，这条路只走拉丁。）
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
