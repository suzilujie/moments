import Foundation

/// 一条「谁在什么时候说话」。
struct SpeakerTurn: Codable, Identifiable {

    var id: String
    var startMs: Int
    var endMs: Int

    /// 全局说话人编号（跨块对齐之后）。
    /// 它只是**编号**，不代表身份 —— 身份由声纹库决定（见 SpeakerProfileStore）。
    var speakerIndex: Int

    /// 声纹库命中时的姓名；未命中为 nil（界面显示「说话人 N」）
    var personName: String?

    /// 与声纹库命中的相似度（余弦）。命中才有值。
    var matchScore: Float?

    /// 该段是否可能包含**重叠说话**（两人以上同时讲）。
    ///
    /// 明确标注而不是藏起来：重叠说话是全行业公认难题，
    /// 分割准确率会明显下降。假装准确比承认不可靠更糟 ——
    /// 用户会据此产生错误信任。
    var mayOverlap: Bool

    var durationMs: Int { max(0, endMs - startMs) }

    /// 时间轴展示（相对会话起点）
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

/// 一次会话的说话人时间轴（持久化单元）。
///
/// 与转写稿**分开存**是刻意的：说话人分离与转写是两条独立的链路，
/// 各自可能失败、各自可能重跑。合存一份会让"某一条失败就毁掉另一条"。
///
/// 两者通过**时间戳**关联，而不是靠 id 强绑 —— 转写片段自带 startMs/endMs，
/// 用时间重叠就能回填出「这句话是谁说的」，且任一方重跑后另一方不需要改。
struct SpeakerTimeline: Codable {

    var sessionId: String
    var createdAtMs: Int64
    /// 实际使用的模型（便于日后判断"这份结果值不值得用更好的模型重跑"）
    var segmentationModel: String
    var embeddingModel: String
    /// 识别出的说话人数（全局编号的个数）
    var speakerCount: Int
    var turns: [SpeakerTurn]
    /// 每个全局说话人的声纹质心（**已归一化**）。
    ///
    /// 存下来的收益有两个，都很实际：
    ///   1. **命名即录入**：用户在会话里把「说话人 2」命名为"张三"时，
    ///      直接把这份质心写进声纹库 —— 不需要再录一遍音。
    ///   2. **重新认人不必重跑分离**：声纹库更新后，可以对历史会话
    ///      只用质心重做比对（秒级），而不必把几小时的音频重新分离一遍。
    /// 体积代价很小：192 维 float × 人数，通常不到 10 KB。
    var centroids: [[Float]]?
    var note: String?

    // MARK: - 派生

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
    }

    var isEmpty: Bool { turns.isEmpty }

    var totalSpeechMs: Int {
        turns.reduce(0) { $0 + $1.durationMs }
    }

    /// 已认出身份的人数（声纹库命中）
    var recognizedCount: Int {
        Set(turns.compactMap { $0.personName }).count
    }

    /// 时间点落在哪一段。用于把说话人回填到转写片段。
    func turn(atMs ms: Int) -> SpeakerTurn? {
        turns.first { ms >= $0.startMs && ms < $0.endMs }
    }

    /// 与某段时间**重叠最多**的那一段。
    ///
    /// 为什么不用「起点落在谁里面」：转写片段的边界与说话人片段边界不会对齐，
    /// 一个句子很可能横跨两次"换人"。取重叠最多者能让归属更稳定，
    /// 而不是因为一个毫秒的偏差就把标签抖到别人头上。
    func dominantTurn(fromMs: Int, toMs: Int) -> SpeakerTurn? {
        var best: SpeakerTurn?
        var bestOverlap = 0
        for turn in turns {
            let overlap = min(turn.endMs, toMs) - max(turn.startMs, fromMs)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = turn
            }
        }
        return best
    }

    /// 全局编号 → 展示名。未命名时显示「说话人 N」。
    func displayName(for index: Int) -> String {
        if let named = turns.first(where: { $0.speakerIndex == index && $0.personName != nil })?.personName {
            return named
        }
        return "说话人 \(index + 1)"
    }

    /// 摘要（列表与自检页用）
    var summary: String {
        if turns.isEmpty { return "无结果" }
        let recognized = recognizedCount
        var text = "\(speakerCount) 人｜\(turns.count) 段"
        if recognized > 0 { text += "｜已认出 \(recognized) 人" }
        if turns.contains(where: { $0.mayOverlap }) { text += "｜含可能重叠段" }
        return text
    }
}

/// 说话人时间轴的持久化层（与会话清单、转写稿同处一个会话目录）。
///
/// ```
/// Application Support/Moments/Audio/{sessionId}/
/// ├─ manifest.json
/// ├─ transcript-final.json
/// ├─ speakers.json          ← 本文件
/// └─ 000000.m4a
/// ```
final class SpeakerTimelineStore {

    static let shared = SpeakerTimelineStore()

    private let queue = DispatchQueue(label: "com.xfish.moments.speaker.store", qos: .utility)
    private let fileName = "speakers.json"

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder = JSONDecoder()

    private init() {}

    func url(sessionId: String) -> URL {
        RecordingLibrary.shared.sessionDirectory(sessionId).appendingPathComponent(fileName)
    }

    func exists(sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: url(sessionId: sessionId).path)
    }

    func save(_ timeline: SpeakerTimeline) throws {
        let target = url(sessionId: timeline.sessionId)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(timeline)
        try data.write(to: target, options: .atomic)
    }

    func saveAsync(_ timeline: SpeakerTimeline) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.save(timeline)
            } catch {
                Log.shared.error(
                    .storage,
                    "说话人时间轴写入失败｜\(timeline.sessionId)｜\(error.localizedDescription)"
                )
            }
        }
    }

    func load(sessionId: String) -> SpeakerTimeline? {
        let target = url(sessionId: sessionId)
        guard let data = try? Data(contentsOf: target) else { return nil }
        do {
            return try decoder.decode(SpeakerTimeline.self, from: data)
        } catch {
            Log.shared.error(.storage, "说话人时间轴解析失败｜\(sessionId)｜\(error.localizedDescription)")
            return nil
        }
    }

    func delete(sessionId: String) {
        let target = url(sessionId: sessionId)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.removeItem(at: target)
        Log.shared.info(.storage, "已删除说话人时间轴｜\(sessionId)")
    }

    /// 已做说话人分离的会话数 / 总会话数
    func coverage() -> (analyzed: Int, total: Int) {
        let sessions = RecordingLibrary.shared.listSessions()
        let analyzed = sessions.filter { exists(sessionId: $0.id) }.count
        return (analyzed, sessions.count)
    }
}
