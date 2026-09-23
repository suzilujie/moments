import Foundation

/// 转写稿的用途 —— 设计文档 5.4 的「两遍转写」。
///
/// 为什么必须分两稿，而不是只保留一份（这是本项目的核心体验设计）：
///   · whisper 是**批式模型**，实时字幕靠滑窗反复重解，同一句话会先出一版、
///     再被改对。若只有这一版，用户会对"文字乱跳"产生不信任；
///   · 终稿用更大的模型在闲置时段补跑，结果是稳定的、可用于留档的；
///   · 两稿并存，用户既能当场看到内容，事后又有准确版本可比对。
enum TranscriptPass: String, Codable, CaseIterable {
    /// 录音过程中的实时字幕（可能自我修正）
    case live
    /// 事后补跑的终稿
    case final
    /// 对照稿：与终稿用**同一个模型**，唯一差别是音频先经过降噪。
    ///
    /// 存在的唯一目的：让「降噪到底让识别更准还是更差」这个问题
    /// 由数据回答，而不是靠猜。降噪会引入失真伪影，可能反而抹掉
    /// 模型需要的语音细节（见 SherpaDenoiser），因此必须可对照验证。
    case control

    var title: String {
        switch self {
        case .live: return "实时稿"
        case .final: return "终稿"
        case .control: return "对照稿"
        }
    }

    var explanation: String {
        switch self {
        case .live: return "录音过程中生成，可能仍在修正"
        case .final: return "事后用更大模型重新转写，用于留档"
        case .control: return "与终稿同一模型，但音频先降噪，用于比较降噪是否更准"
        }
    }
}

/// 一句转写结果。
///
/// 时间戳一律是**相对整次会话起点**的毫秒偏移（不是相对分片），
/// 这样「点句回听」直接用同一个数值就能在任意分片上定位 —— 见 `TranscriptionService` 的映射逻辑。
struct TranscriptSegment: Codable, Identifiable, Hashable {

    var id: String
    /// 会话内的顺序号（排序与稳定显示用，不依赖时间戳）
    var seq: Int
    var startMs: Int
    var endMs: Int
    var text: String

    /// 说话人编号。M3（说话人分离）之前恒为 nil；
    /// 字段现在就留出，避免 M3 时再改一遍数据模型与界面。
    var speakerId: String?

    /// 该句在实时稿里是否**尚未定型**（后续可能被改写）。
    /// 存在的理由：必须让用户看到"这段还在识别中"，而不是以为文字出了故障（设计文档 R15）。
    var isProvisional: Bool

    var durationMs: Int { max(0, endMs - startMs) }

    /// 时间轴展示形式（会话内的相对位置）
    var timeText: String {
        let totalSeconds = max(0, startMs) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// 一次会话在某一稿下的完整转写结果（持久化单元）。
///
/// 与 M1 的清单文件同理，先用 JSON 落盘而不是 SQLite：
/// 音频目录自带完整解释自己的能力，真机排错时可以直接看。
/// M4（存储检索）换 SQLite + FTS5 时，本结构体作为迁移来源保留。
struct TranscriptDocument: Codable {

    var sessionId: String
    var pass: TranscriptPass
    /// 实际使用的模型 id —— 用于判断"这份终稿是不是用够好的模型跑的"，
    /// 也便于升级模型后识别哪些会话值得重跑（与译文缓存的 engine_version 同理）。
    var modelId: String
    /// 识别语言（"auto" 表示由模型判定）
    var language: String
    var createdAtMs: Int64
    /// 是否跑完（未跑完的稿表示被中断过，可续跑）
    var isComplete: Bool
    var segments: [TranscriptSegment]
    var note: String?

    // MARK: - 派生属性

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
    }

    var characterCount: Int {
        segments.reduce(0) { $0 + $1.text.count }
    }

    /// 是否为空稿（音轨里确实没有人说话，或全部转写失败）
    var isEmpty: Bool { segments.isEmpty }

    /// 时间戳覆盖到的长度（与音频时长对比可判断是否有分片没转）
    var coveredMs: Int { segments.last?.endMs ?? 0 }

    /// 列表页用的一句话预览
    var previewText: String {
        let joined = segments.prefix(3).map { $0.text }.joined(separator: " ")
        return joined.isEmpty ? "（无内容）" : joined
    }

    /// 全文拼接（导出与检索用）
    func fullText() -> String {
        segments.map { $0.text }.joined(separator: "\n")
    }

    /// 按时间戳找到第几句（点句回听的反向：由播放位置找当前句）。
    func indexOfSegment(atMs ms: Int) -> Int? {
        segments.firstIndex { ms >= $0.startMs && ms < $0.endMs }
    }
}

/// 转写相关的错误。单独成枚举而不是复用 CaptureError：
/// 转写失败的原因（模型没下载、音频被清理、内存不足）与采集失败完全不同，
/// 混淆在一起会让界面无法给出正确的引导（该去下模型还是该去重录）。
enum TranscriptionError: LocalizedError {
    case modelNotInstalled(String)
    case modelLoadFailed(String)
    case sessionNotFound(String)
    case noAudioAvailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name):
            return "转写模型「\(name)」尚未下载，请先在设置中下载模型"
        case .modelLoadFailed(let reason):
            return "模型加载失败：\(reason)"
        case .sessionNotFound(let id):
            return "找不到会话 \(id)"
        case .noAudioAvailable(let reason):
            return "没有可用于转写的音频：\(reason)"
        case .cancelled:
            return "转写已取消"
        }
    }
}
