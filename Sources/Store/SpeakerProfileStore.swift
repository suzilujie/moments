import Foundation

/// 一个人物的声纹档案。
///
/// 这是「跨会话认人」的全部家当：把一次语音压成质心向量存下来，
/// 之后任何一次录音里出现相似向量，就能认出是同一个人。
struct SpeakerProfile: Codable, Identifiable {

    var id: String
    var name: String
    /// 声纹质心（**已归一化**）。归一化后余弦相似度退化为点积，且与音量无关。
    var centroid: [Float]
    /// 累计了多少段语音参与质心（越多越稳）
    var sampleCount: Int
    var createdAtMs: Int64
    var updatedAtMs: Int64
    /// 来源：从某次会话命名，或主动录入
    var source: String

    var updatedAt: Date {
        Date(timeIntervalSince1970: Double(updatedAtMs) / 1000.0)
    }

    var sourceText: String {
        source == "recorded" ? "主动录入" : "录音中命名"
    }
}

/// 声纹库（M3c 的核心资产）。
///
/// ## 为什么自己实现而不用 sherpa-onnx 自带的 SpeakerEmbeddingManager
/// 自带的管理器是**内存态**的，而我们需要的是**可持久化、可编辑**的档案：
/// 改名、合并重复人物、删除声纹、跨启动存活。
/// 这些都得自己维护，那么剩下真正要自己写的只有「余弦比对 + 阈值判断」——
/// 十几行代码，却换来对存档格式与升级路径的完全掌控。
///
/// ## 一个必须讲清楚的边界
/// 声纹识别**不是生物识别的强保证**。同一个人的不同状态（感冒、情绪、距离、麦克风）
/// 会让相似度明显波动；不同人偶尔也会相似。因此本项目的定位是
/// **"辅助认人"而不是"锁定身份"**：
///   · 命中只是**建议**，界面允许一键改名/纠正
///   · 纠正后的名字会更新质心 —— 用得越多越准
///   · 未命中不会瞎猜，显示「说话人 N」
@MainActor
final class SpeakerProfileStore: ObservableObject {

    static let shared = SpeakerProfileStore()

    @Published private(set) var profiles: [SpeakerProfile] = []

    private let queue = DispatchQueue(label: "com.xfish.moments.speaker.profiles", qos: .utility)

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder = JSONDecoder()

    private init() {
        reload()
    }

    // MARK: - 路径

    var fileURL: URL? {
        (try? AppPaths.speakersDirectory())?.appendingPathComponent("profiles.json")
    }

    // MARK: - 读写

    func reload() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            profiles = []
            return
        }
        do {
            profiles = try decoder.decode([SpeakerProfile].self, from: data)
                .sorted { $0.updatedAtMs > $1.updatedAtMs }
        } catch {
            // 档案损坏时不静默清空：留下日志，并保留空列表以免整个界面崩掉。
            // 真实数据仍在磁盘上，人工可救。
            Log.shared.error(.storage, "声纹库解析失败｜\(error.localizedDescription)｜文件保留未动")
            profiles = []
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = profiles
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try self.encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.shared.error(.storage, "声纹库写入失败｜\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 增删改

    /// 新建或更新一个人物。
    /// - Parameters:
    ///   - centroid: 归一化后的声纹质心
    ///   - mergingInto: 若指定，则把质心合并进已有档案（纠正/追加样本时用）
    @discardableResult
    func upsert(
        name: String,
        centroid: [Float],
        source: String,
        mergingInto existingId: String? = nil
    ) -> SpeakerProfile {
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // 已有同名人物 → 合并质心（而不是新建一个重名档案，
        // 否则同一个人会分裂成多条记录，越用越乱）
        if let index = profiles.firstIndex(where: { $0.id == existingId || $0.name == name }) {
            var profile = profiles[index]
            let merged = SpeakerMatching.merge(profile.centroid, sampleCount: profile.sampleCount, with: centroid)
            profile.centroid = merged
            profile.sampleCount += 1
            profile.updatedAtMs = now
            profile.name = name
            profiles[index] = profile
            persist()
            Log.shared.info(.storage, "声纹档案已更新｜\(name)｜累计 \(profile.sampleCount) 段")
            return profile
        }

        let profile = SpeakerProfile(
            id: "sp\(now)-\(String(UUID().uuidString.prefix(4)).lowercased())",
            name: name,
            centroid: centroid,
            sampleCount: 1,
            createdAtMs: now,
            updatedAtMs: now,
            source: source
        )
        profiles.insert(profile, at: 0)
        persist()
        Log.shared.info(.storage, "声纹档案已新建｜\(name)｜来源 \(profile.sourceText)")
        return profile
    }

    func rename(id: String, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        profiles[index].updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        persist()
    }

    func delete(id: String) {
        profiles.removeAll { $0.id == id }
        persist()
        Log.shared.info(.storage, "声纹档案已删除｜\(id)")
    }

    func delete(at offsets: IndexSet) {
        for index in offsets where profiles.indices.contains(index) {
            profiles.remove(at: index)
        }
        persist()
    }

    // MARK: - 匹配

    /// 在库中找最相似的人。
    ///
    /// 阈值以下**返回 nil 而不返回"最像的那个"** —— 这是刻意的：
    /// 认错的代价（产生错误记录）远高于认不出的代价（显示"说话人 N"）。
    func match(_ embedding: [Float]) -> (profile: SpeakerProfile, score: Float)? {
        guard !profiles.isEmpty else { return nil }
        var best: SpeakerProfile?
        var bestScore: Float = -1

        for profile in profiles {
            let score = SherpaSpeakerEmbedder.cosine(profile.centroid, embedding)
            if score > bestScore {
                bestScore = score
                best = profile
            }
        }

        guard let best, bestScore >= SpeakerMatching.identityThreshold else { return nil }
        return (best, bestScore)
    }
}

/// 说话人相关的**阈值与向量运算**。
///
/// 刻意放在一个**非隔离**的普通 enum 里，而不是放在 `SpeakerProfileStore`
/// 或 `DiarizationService`（两者都是 @MainActor）：这些函数要**在后台队列上**被调用
/// （分离 worker 里逐块计算质心），若定义在 @MainActor 类型里，
/// 从后台队列调用就是 actor 隔离违规。
enum SpeakerMatching {

    /// 跨块身份对齐阈值（**同一次录音内**，刻意较松）。
    /// 同一次会话里声学环境一致，同一个人在不同块之间的相似度天然偏高；
    /// 松一点可以避免"一个人被拆成两个说话人"。
    static let crossChunkThreshold: Float = 0.5

    /// 声纹库身份阈值（**跨会话**，刻意较严）。
    ///
    /// 0.62 是 CAM++ 这类模型上的经验默认值，**必须在真机上用真实语料标定**。
    /// 取向是偏高：认错人（把张三说成李四）会在记录里留下**错误信息**，
    /// 而认不出只是显示"说话人 N" —— 两者代价不对称。
    static let identityThreshold: Float = 0.62

    /// 质心合并：按样本数加权平均后再归一化。
    ///
    /// 直接等权平均会让"只录过一段"的新样本与"录过二十段"的老样本同权，
    /// 档案会被一次异常录音带偏。
    static func merge(_ existing: [Float], sampleCount: Int, with incoming: [Float]) -> [Float] {
        guard existing.count == incoming.count, sampleCount > 0 else {
            return SherpaSpeakerEmbedder.normalized(incoming)
        }
        let weight = Float(sampleCount)
        var mixed = [Float](repeating: 0, count: existing.count)
        for index in 0..<existing.count {
            mixed[index] = (existing[index] * weight + incoming[index]) / (weight + 1)
        }
        return SherpaSpeakerEmbedder.normalized(mixed)
    }
}
