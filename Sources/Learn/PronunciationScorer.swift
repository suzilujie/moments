import Foundation

/// 一个词的对齐结果。
struct WordAlignment: Identifiable, Hashable {

    enum Verdict: String {
        /// 读对了（模型听到的就是这个词）
        case hit
        /// 读成了别的词
        case substituted
        /// 参考句里有、但没被听到（漏读 / 吞音 / 声音太小）
        case missed
        /// 参考句里没有、但听到了（识别噪声，或用户自己加了词）
        case extra

        var title: String {
            switch self {
            case .hit: return "读对"
            case .substituted: return "读成别的词"
            case .missed: return "没听到"
            case .extra: return "多出来的词"
            }
        }
    }

    let id: Int
    /// 参考句里的词（extra 时为 nil）
    let expected: String?
    /// 模型听到的词（missed 时为 nil）
    let heard: String?
    let verdict: Verdict

    /// 展示用的词（优先显示参考句的词 —— 用户读的是那一句）
    var displayText: String { expected ?? heard ?? "" }
}

/// 跟读比对结果。
struct PronunciationScore {

    /// 0...1
    let score: Double
    let expectedCount: Int
    let hitCount: Int
    let missedCount: Int
    /// 错读成别的词的个数（与 missed 分开计：两者的改进方式完全不同）
    let substitutedCount: Int
    let extraCount: Int
    let alignments: [WordAlignment]
    /// 模型听到的原文
    let recognizedText: String

    var percentText: String { "\(Int((score * 100).rounded()))%" }

    var verdictText: String {
        guard expectedCount > 0 else { return "没有可对照的内容" }
        switch score {
        case 0.95...: return "几乎完全读对"
        case 0.8..<0.95: return "基本读对，个别词没听清"
        case 0.5..<0.8: return "读对一半以上，有几处需要再读"
        default: return "差距较大，建议放慢速度重读"
        }
    }

    /// 一句话结论（界面与日志共用）
    var summary: String {
        "命中 \(hitCount)/\(expectedCount)"
            + "｜没听到 \(missedCount)"
            + "｜读成别的词 \(substitutedCount)"
            + "｜多余 \(extraCount)"
    }

    var logLine: String {
        "跟读比对｜得分 \(percentText)｜\(summary)"
    }
}

/// 跟读比对（M6b 的判据）。
///
/// ## 它测的到底是什么（必须先说清楚，否则会误导用户）
/// whisper 是**语音识别**模型，不是**发音评测**模型。
/// 它输出的是"把这段声音听成了哪些词"，因此本模块测的是
/// **「读对了没有」这一层**：
///   · 能测到：漏读整个词、读成别的词、多加词、吞音、声音太小
///   · 测不到：音素级的发音质量。
///     把 "think" 读成 "sink" 会**被判为错**（这是好事，说明它有用），
///     但把 "think" 读成舌位略偏的 "think"（仍被听成 think）
///     则**看不出任何差别** —— 它无法告诉你"th 的舌位不对"。
///
/// 所以界面上不能自称"发音评分"。真正的音素级评分需要专门的
/// 发音评测模型（如 GOP 打分），本项目不引入 —— 这是 M6 的明确边界，
/// 不假装有。详见 PracticeView 的说明。
///
/// ## 为什么用编辑距离对齐，而不是逐位比较
/// 漏读一个词会让后面所有词**整体错位**。逐位比较会把"少读一个词"
/// 报成"后面每一个词都读错了"，那是灾难性的误导（用户会以为自己
/// 整句都读错了）。编辑距离先对齐，再逐词判性质，少读的词单独计为 missed。
enum PronunciationScorer {

    /// 比较用的词元。
    struct Token {
        /// 比较键：小写、仅字母（撇号/连字符不参与比较）
        let key: String
        /// 展示形式
        let display: String
    }

    static func tokenize(_ text: String) -> [Token] {
        VocabularyExtractor.latinTokens(in: text).compactMap { raw in
            let key = raw.lowercased().filter { $0.isLetter }
            guard !key.isEmpty else { return nil }
            return Token(key: key, display: raw)
        }
    }

    static func score(reference: String, recognized: String) -> PronunciationScore {
        let expected = tokenize(reference)
        let heard = tokenize(recognized)

        guard !expected.isEmpty else {
            return PronunciationScore(
                score: 0,
                expectedCount: 0,
                hitCount: 0,
                missedCount: 0,
                substitutedCount: 0,
                extraCount: 0,
                alignments: [],
                recognizedText: recognized
            )
        }

        let n = expected.count
        let m = heard.count

        // 词级编辑距离矩阵
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }

        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substituteCost = expected[i - 1].key == heard[j - 1].key ? 0 : 1
                    dp[i][j] = min(
                        dp[i - 1][j] + 1,                       // 没听到
                        dp[i][j - 1] + 1,                       // 多出来的词
                        dp[i - 1][j - 1] + substituteCost       // 配对
                    )
                }
            }
        }

        // 回溯。**优先走对角线**：代价相同时取"配对"而不是"漏读 + 多读"，
        // 这样一处错读只报一条，而不是报两条 —— 更符合用户的直觉。
        var alignments: [WordAlignment] = []
        var i = n
        var j = m

        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let substituteCost = expected[i - 1].key == heard[j - 1].key ? 0 : 1
                if dp[i][j] == dp[i - 1][j - 1] + substituteCost {
                    alignments.append(
                        WordAlignment(
                            id: alignments.count,
                            expected: expected[i - 1].display,
                            heard: heard[j - 1].display,
                            verdict: substituteCost == 0 ? .hit : .substituted
                        )
                    )
                    i -= 1
                    j -= 1
                    continue
                }
            }

            if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                alignments.append(
                    WordAlignment(
                        id: alignments.count,
                        expected: expected[i - 1].display,
                        heard: nil,
                        verdict: .missed
                    )
                )
                i -= 1
                continue
            }

            if j > 0 {
                alignments.append(
                    WordAlignment(
                        id: alignments.count,
                        expected: nil,
                        heard: heard[j - 1].display,
                        verdict: .extra
                    )
                )
                j -= 1
                continue
            }

            break
        }

        alignments.reverse()
        // 回溯是倒着生成的，反转后重新编号，保证 id 与显示顺序一致
        let ordered = alignments.enumerated().map { offset, item in
            WordAlignment(id: offset, expected: item.expected, heard: item.heard, verdict: item.verdict)
        }

        let hits = ordered.filter { $0.verdict == .hit }.count
        let missed = ordered.filter { $0.verdict == .missed }.count
        let substituted = ordered.filter { $0.verdict == .substituted }.count
        let extras = ordered.filter { $0.verdict == .extra }.count

        return PronunciationScore(
            score: Double(hits) / Double(n),
            expectedCount: n,
            hitCount: hits,
            missedCount: missed,
            substitutedCount: substituted,
            extraCount: extras,
            alignments: ordered,
            recognizedText: recognized
        )
    }
}
