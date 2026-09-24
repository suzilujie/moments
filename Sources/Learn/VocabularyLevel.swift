import Foundation

/// 生词水平档（设计文档 8.5：按用户自选水平调整分数线）。
///
/// ## 为什么必须可调
/// 「生词」是相对**使用者水平**而言的，不是绝对概念：同一个词对 A2 是生词，
/// 对 C1 可能早就是熟词。把分数线写死，等于替用户假定了一个水平 ——
/// 而本项目无从知道这件事（也没必要猜：让用户选一次，永久有效）。
///
/// 之前实现里把阈值硬编码成 3000。那对"四六级水平"大致合适，
/// 但对初学者是"几乎不标"（满屏都是生词却没标出来），
/// 对熟练者是"标了一堆早就会的词"。两种情况都会让人不再信赖这个标注。
///
/// ## 档位与分数线的对应关系
/// 用的是**词频排名**（1 = 最高频），含义是「排名在此之后的词，算生词」。
/// 阈值取的是常见英语教学大纲的大致分界（A1/A2 约 1000–2000 词为基础词汇，
/// B1/B2 扩展到 3000–5000，C1/C2 才到一万词量级）。
///
/// 这些数字是**取舍而非精确科学** —— 因此界面上只显示档位名，
/// **不展示具体分数线**，避免给出一个看起来精确、实际只是约定值的数字
/// （与「跟读比对不展示伪精确的小数分」同一原则）。
enum VocabularyLevel: String, CaseIterable, Codable {

    case a1
    case a2
    case b1
    case b2
    case c1
    case c2

    /// 默认档位。选 B1 是因为它等价于此前硬编码的 3000 ——
    /// 升级到本版本时，老用户的生词标注行为**不会发生变化**。
    static let fallback: VocabularyLevel = .b1

    var title: String {
        switch self {
        case .a1: return "A1 入门"
        case .a2: return "A2 初级"
        case .b1: return "B1 中级"
        case .b2: return "B2 中高级"
        case .c1: return "C1 高级"
        case .c2: return "C2 精通"
        }
    }

    /// 一句话说明，供设置页解释"选它会发生什么"
    var detail: String {
        switch self {
        case .a1: return "只有最基础的词不算生词，其余都会标出来"
        case .a2: return "适合能读懂简单句、词汇量约两千的阶段"
        case .b1: return "适合能读一般文章、词汇量约三四千的阶段（默认）"
        case .b2: return "适合能读新闻与专业材料、词汇量约五六千的阶段"
        case .c1: return "只标较冷僻的词，日常与常见书面词都不标"
        case .c2: return "只标语料里没见过的词（术语、专有名词、拼写错误）"
        }
    }

    /// 排名超过此值即视为生词。
    var rankThreshold: Int {
        switch self {
        case .a1: return 800
        case .a2: return 1_500
        case .b1: return 3_000
        case .b2: return 5_000
        case .c1: return 6_000
        // 词表只有约 1 万词，因此 C2 的阈值等于"表内全部视为已掌握"，
        // 实际只会标出**词表之外**的词。这是词表规模的硬上限，不是设计选择 ——
        // 想让它更严格就得换更大的词表（见 WordFrequencyTable 的说明）。
        case .c2: return 10_000
        }
    }
}
