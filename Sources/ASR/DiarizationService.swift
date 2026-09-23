import Foundation

/// 说话人分离任务的阶段（界面直接绑定）。
enum DiarizationStage: Equatable {
    case idle
    case loadingModels
    case analyzing
    case matching
    case saving
    case done
    case failed(String)
    case cancelled

    var text: String {
        switch self {
        case .idle: return "空闲"
        case .loadingModels: return "正在加载说话人模型…"
        case .analyzing: return "正在分析说话人…"
        case .matching: return "正在比对声纹库…"
        case .saving: return "正在保存…"
        case .done: return "已完成"
        case .failed(let message): return "失败：\(message)"
        case .cancelled: return "已取消"
        }
    }

    var isActive: Bool {
        switch self {
        case .loadingModels, .analyzing, .matching, .saving: return true
        default: return false
        }
    }
}

/// 说话人分离服务（M3c）。
///
/// ## 为什么必须分块处理
/// 用户选的是「一键开始、一直录」，一次会话可能有 8 小时。
/// sherpa-onnx 的离线分离接口要求**一次性喂入完整音频**：
/// 8 小时 16 kHz 单声道 = 4.6 亿个 Float = **1.8 GB 内存**，
/// 这在 iPhone 上必然被杀掉。
///
/// 因此按固定时长切块（默认 10 分钟 ≈ 38 MB），每块各自聚类，
/// 再用**声纹质心**把各块的"说话人1"接续成同一个全局编号 ——
/// 这就是设计文档 6.3 说的「分块处理 + 跨块身份对齐」。
///
/// ## 三个刻意的阈值区分（认错的代价不对称）
///   · 跨块对齐阈值（0.5，较松）：同一次录音内、同样的声学环境，
///     同一个人在不同块之间的相似度天然较高，松一点能减少"一个人被拆成两个"。
///   · 声纹库身份阈值（0.62，较严）：跨会话、跨环境，且**认错的代价远高于认不出**
///     （认错会产生错误记录，认不出只显示"说话人 N"）。
///   · 不返回"最像的那个"：低于阈值一律返回 nil，绝不硬凑。
@MainActor
final class DiarizationService: ObservableObject {

    static let shared = DiarizationService()

    @Published private(set) var stage: DiarizationStage = .idle
    @Published private(set) var runningSessionId: String?
    @Published private(set) var processedChunks = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var lastMessage: String?

    private var worker: DiarizationWorker?

    var isBusy: Bool { stage.isActive }

    var progress: Double {
        guard totalChunks > 0 else { return 0 }
        return min(1.0, Double(processedChunks) / Double(totalChunks))
    }

    private init() {}

    // MARK: - 入口

    func analyze(sessionId: String) {
        guard !isBusy else {
            lastMessage = "已有说话人分析在进行中"
            return
        }

        // 三个模型都是内置的（见 SherpaBundledModel）——
        // 缺任何一个都明确报出来，并说清后果，而不是静默降级
        var missing: [String] = []
        guard let segmentationURL = SherpaBundledModel.pyannoteSegmentation.url else {
            missing.append(SherpaBundledModel.pyannoteSegmentation.displayName)
            fail(missing: missing)
            return
        }
        guard let embeddingURL = SherpaBundledModel.speakerEmbedding.url else {
            missing.append(SherpaBundledModel.speakerEmbedding.displayName)
            fail(missing: missing)
            return
        }

        guard var manifest = RecordingLibrary.shared.loadManifest(sessionId: sessionId) else {
            stage = .failed("找不到会话 \(sessionId)")
            return
        }

        // 音频可能已被保留期策略清理（文本永久、音频有限）。
        // 明确区分"音频没了"与"分析失败"，否则用户会反复重试
        manifest.segments = manifest.segments.filter { entry in
            FileManager.default.fileExists(
                atPath: RecordingLibrary.shared
                    .segmentURL(sessionId: sessionId, fileName: entry.fileName).path
            )
        }
        guard !manifest.segments.isEmpty else {
            stage = .failed("音频已按保留期清理，无法再做说话人分离")
            Log.shared.warn(.asr, "说话人分离被拒：无可用音频｜\(sessionId)")
            return
        }

        // 与其它重任务互斥：三者同时跑会互相抢 CPU，并拖累录音（设计文档 5.4）
        LiveTranscriber.shared.setPaused(true)

        let inputs = DiarizationWorker.Inputs(
            sessionId: sessionId,
            segments: manifest.segments,
            segmentationModelPath: segmentationURL.path,
            embeddingModelPath: embeddingURL.path,
            chunkSeconds: Self.defaultChunkSeconds
        )

        runningSessionId = sessionId
        processedChunks = 0
        totalChunks = 0
        stage = .loadingModels
        lastMessage = "开始说话人分离｜\(manifest.segments.count) 个分片"

        let worker = DiarizationWorker(inputs: inputs)
        worker.onStage = { [weak self] newStage in
            Task { @MainActor in self?.stage = newStage }
        }
        worker.onProgress = { [weak self] processed, total in
            Task { @MainActor in
                self?.processedChunks = processed
                self?.totalChunks = total
            }
        }
        worker.onFinished = { [weak self] outcome in
            Task { @MainActor in self?.handle(outcome) }
        }
        self.worker = worker
        worker.start()
    }

    func cancel() {
        guard isBusy else { return }
        worker?.cancel()
        Log.shared.info(.asr, "说话人分离取消请求已发出")
    }

    /// 用当前声纹库对**所有已分离过的会话**重新认人。
    ///
    /// 为什么这一步值得单独做：它只用到时间轴里存下的声纹质心，
    /// **不重跑音频分离**（那对 8 小时会话是小时级任务），因此是秒级完成。
    /// 效果是：你新录入一个人之后，**历史录音也会立刻被认出来** ——
    /// 声纹库的价值随使用时间增长，而不是只对以后的录音生效。
    @discardableResult
    func rematchAllSessions() -> Int {
        guard !SpeakerProfileStore.shared.profiles.isEmpty else {
            lastMessage = "声纹库为空，无法认人"
            return 0
        }

        var updated = 0
        for manifest in RecordingLibrary.shared.listSessions() {
            guard var timeline = SpeakerTimelineStore.shared.load(sessionId: manifest.id),
                  let centroids = timeline.centroids,
                  !centroids.isEmpty else { continue }

            // 先清空旧名字再重比：否则上一次的错误命中会残留下来
            for index in timeline.turns.indices {
                timeline.turns[index].personName = nil
                timeline.turns[index].matchScore = nil
            }
            applyProfiles(to: &timeline, centroids: centroids)
            try? SpeakerTimelineStore.shared.save(timeline)
            updated += 1
        }

        lastMessage = "重新认人完成｜更新 \(updated) 次会话"
        Log.shared.info(.asr, lastMessage ?? "")
        return updated
    }

    /// 默认分块时长（秒）。10 分钟 ≈ 38 MB 音频常驻内存。
    /// 调大更省重复对齐开销，但内存风险上升；调小则相反。
    static let defaultChunkSeconds = 600

    private func fail(missing: [String]) {
        let text = "内置模型缺失：\(missing.joined(separator: "、"))，说话人分离不可用"
        stage = .failed(text)
        lastMessage = text
        Log.shared.error(.asr, text)
    }

    private func handle(_ outcome: DiarizationWorker.Outcome) {
        worker = nil
        runningSessionId = nil
        LiveTranscriber.shared.setPaused(false)

        switch outcome {
        case .finished(var timeline, let centroids):
            // 声纹库比对**必须回到主线程**做（SpeakerProfileStore 是 @MainActor）。
            // 放在 worker 里做会构成 actor 隔离违规 —— 这也正是
            // worker 要把质心随结果一起交回来的原因。
            applyProfiles(to: &timeline, centroids: centroids)
            do {
                try SpeakerTimelineStore.shared.save(timeline)
                stage = .done
                lastMessage = "说话人分离完成｜\(timeline.summary)"
                Log.shared.info(.asr, lastMessage ?? "")
            } catch {
                stage = .failed("保存失败：\(error.localizedDescription)")
                Log.shared.error(.asr, "说话人时间轴保存失败｜\(error.localizedDescription)")
            }

        case .cancelled(let timeline):
            stage = .cancelled
            lastMessage = timeline.map { "已取消｜已保留 \($0.turns.count) 段" } ?? "已取消"

        case .failed(let message):
            stage = .failed(message)
            lastMessage = message
            Log.shared.error(.asr, "说话人分离失败｜\(message)")
        }
    }

    /// 把全局说话人质心比对到声纹库，命中则写上姓名。
    ///
    /// 低于阈值**保持无名**（界面显示"说话人 N"），绝不硬凑最像的那个 ——
    /// 认错人会在记录里留下错误信息，比认不出更糟（见 SpeakerMatching.identityThreshold）。
    private func applyProfiles(to timeline: inout SpeakerTimeline, centroids: [[Float]]) {
        let store = SpeakerProfileStore.shared
        guard !store.profiles.isEmpty else { return }

        var hits: [Int: (name: String, score: Float)] = [:]
        for (index, centroid) in centroids.enumerated() {
            if let hit = store.match(centroid) {
                hits[index] = (hit.profile.name, hit.score)
            }
        }
        guard !hits.isEmpty else {
            Log.shared.info(.asr, "声纹库未命中（库中 \(store.profiles.count) 人，本次 \(centroids.count) 人）")
            return
        }

        for index in timeline.turns.indices {
            let speaker = timeline.turns[index].speakerIndex
            guard let hit = hits[speaker] else { continue }
            timeline.turns[index].personName = hit.name
            timeline.turns[index].matchScore = hit.score
        }
        Log.shared.info(.asr, "声纹库命中 \(hits.count)/\(centroids.count) 人")
    }
}

/// 分离执行体（**非 MainActor**，自带串行队列）。
///
/// 所有对 `SherpaDiarizer` / `SherpaSpeakerEmbedder` 的调用都落在这条队列上 ——
/// 这两个类都持有 C 指针、不是线程安全的。
final class DiarizationWorker {

    struct Inputs {
        let sessionId: String
        let segments: [SessionManifest.SegmentEntry]
        let segmentationModelPath: String
        let embeddingModelPath: String
        let chunkSeconds: Int
    }

    enum Outcome {
        /// 带上全局质心：主线程需要它们来比对声纹库（见 DiarizationService.applyProfiles）。
        /// 只交回时间轴是不够的 —— 那样主线程拿不到向量，就没法认人。
        case finished(SpeakerTimeline, centroids: [[Float]])
        case cancelled(SpeakerTimeline?)
        case failed(String)
    }

    /// 一个音频块：它是若干个会话分片首尾相接拼出来的。
    ///
    /// **为什么要记下每片的偏移**：会话里可能有断口（漏录），
    /// 此时"块内时间"与"会话时间"不是简单相加的关系。
    /// 分片自带 startMs（由样本计数推导，见设计文档 4.11），
    /// 因此逐片锚定才能让时间轴在断口处依然正确。
    private struct AudioChunk {
        struct Piece {
            let fileName: String
            let sessionStartMs: Int
            let chunkOffset: Int
            var length: Int
        }
        var pieces: [Piece] = []
        var totalSamples = 0

        /// 块内样本偏移 → 会话毫秒
        func sessionMs(forSampleOffset offset: Int) -> Int? {
            guard !pieces.isEmpty else { return nil }
            for piece in pieces.reversed() where offset >= piece.chunkOffset {
                let local = max(0, offset - piece.chunkOffset)
                return piece.sessionStartMs + local * 1000 / 16_000
            }
            return pieces.first.map { $0.sessionStartMs }
        }
    }

    private let inputs: Inputs
    private let queue = DispatchQueue(label: "com.xfish.moments.diarization.worker", qos: .utility)

    private let cancelLock = NSLock()
    private var cancelled = false

    var onStage: ((DiarizationStage) -> Void)?
    var onProgress: ((Int, Int) -> Void)?
    var onFinished: ((Outcome) -> Void)?

    init(inputs: Inputs) {
        self.inputs = inputs
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    // MARK: - 主体

    private func run() {
        onStage?(.loadingModels)

        guard let diarizer = SherpaDiarizer(
            segmentationModelPath: inputs.segmentationModelPath,
            embeddingModelPath: inputs.embeddingModelPath
        ) else {
            onFinished?(.failed("说话人分离器创建失败（内置模型可能损坏）"))
            return
        }

        guard let embedder = SherpaSpeakerEmbedder(modelPath: inputs.embeddingModelPath) else {
            diarizer.close()
            onFinished?(.failed("声纹提取器创建失败（内置模型可能损坏）"))
            return
        }

        let chunks = Self.makeChunks(segments: inputs.segments, chunkSeconds: inputs.chunkSeconds)
        guard !chunks.isEmpty else {
            diarizer.close()
            embedder.close()
            onFinished?(.failed("没有可用音频分片"))
            return
        }

        onStage?(.analyzing)
        onProgress?(0, chunks.count)

        /// 全局说话人质心（跨块累积）
        var globalCentroids: [[Float]] = []
        var turns: [SpeakerTurn] = []
        var sequence = 0

        for index in 0..<chunks.count {
            if isCancelled {
                diarizer.close()
                embedder.close()
                onFinished?(.cancelled(buildTimeline(turns: turns, centroids: globalCentroids, isComplete: false)))
                return
            }

            // 取出可变副本：读取音频时要用**真实解码长度**修正块内偏移（见 loadSamples）
            var chunk = chunks[index]
            guard let samples = loadSamples(&chunk), !samples.isEmpty else {
                Log.shared.warn(.asr, "第 \(index + 1) 块音频读取失败，跳过")
                onProgress?(index + 1, chunks.count)
                continue
            }

            let localTurns = diarizer.process(samples)
            guard !localTurns.isEmpty else {
                onProgress?(index + 1, chunks.count)
                continue
            }

            // 每个"局部说话人"取若干最长片段算质心，再映射到全局编号
            let localCentroids = Self.localCentroids(
                turns: localTurns,
                samples: samples,
                embedder: embedder
            )

            var mapping: [Int: Int] = [:]
            // 按局部编号排序后处理：字典遍历顺序不确定，而"新说话人依次追加编号"
            // 依赖顺序 —— 不排序会导致**同一段音频每次跑出的编号都不一样**，
            // 界面上的"说话人1/2"会随机互换，用户会以为功能坏了。
            for (localSpeaker, centroid) in localCentroids.sorted(by: { $0.key < $1.key }) {
                if let globalIndex = Self.bestGlobalIndex(for: centroid, in: globalCentroids) {
                    mapping[localSpeaker] = globalIndex
                    globalCentroids[globalIndex] = SpeakerMatching.merge(
                        globalCentroids[globalIndex],
                        sampleCount: 1,
                        with: centroid
                    )
                } else {
                    globalCentroids.append(centroid)
                    mapping[localSpeaker] = globalCentroids.count - 1
                }
            }

            for turn in localTurns {
                guard let globalIndex = mapping[turn.speaker] else { continue }
                guard let startMs = chunk.sessionMs(forSampleOffset: turn.startMs * 16),
                      let endMs = chunk.sessionMs(forSampleOffset: turn.endMs * 16) else { continue }
                guard endMs > startMs else { continue }
                sequence += 1
                turns.append(
                    SpeakerTurn(
                        id: "turn-\(sequence)-\(startMs)",
                        startMs: startMs,
                        endMs: endMs,
                        speakerIndex: globalIndex,
                        personName: nil,
                        matchScore: nil,
                        mayOverlap: false
                    )
                )
            }

            onProgress?(index + 1, chunks.count)
            Log.shared.info(
                .asr,
                "第 \(index + 1)/\(chunks.count) 块完成｜局部说话人 \(localCentroids.count)"
                    + "｜全局累计 \(globalCentroids.count) 人｜片段 \(turns.count)"
            )
        }

        if isCancelled {
            diarizer.close()
            embedder.close()
            onFinished?(.cancelled(buildTimeline(turns: turns, centroids: globalCentroids, isComplete: false)))
            return
        }

        diarizer.close()
        embedder.close()

        // 重叠说话：从**结果本身**推断（不同说话人的片段时间上有交叠），
        // 而不是猜。这是目前唯一可靠的判断方式 ——
        // sherpa 的 confidence 字段表达的是聚类置信度，不是重叠标志。
        Self.markOverlaps(&turns)

        onStage?(.matching)
        let timeline = buildTimeline(turns: turns, centroids: globalCentroids, isComplete: true)

        onStage?(.saving)
        // 声纹库比对与保存都在主线程做（见 DiarizationService.applyProfiles）：
        // 命中姓名要和时间轴写进**同一份**文件，在这里先写一遍、再让主线程改一遍
        // 是多余的磁盘写入，也会出现"文件先无名字后有名"的中间态。
        onFinished?(.finished(timeline, centroids: globalCentroids))
    }

    // MARK: - 分块

    private static func makeChunks(
        segments: [SessionManifest.SegmentEntry],
        chunkSeconds: Int
    ) -> [AudioChunk] {
        let samplesPerChunk = chunkSeconds * 16_000
        var chunks: [AudioChunk] = []
        var current = AudioChunk()

        for segment in segments {
            // sampleCount 是写入时的**样本数**（设计文档 4.11 用它推导时间轴），
            // 这里用它估算块的大小；实际解码长度会略有出入，但不影响分块决策。
            let length = max(1, segment.sampleCount)
            if current.totalSamples > 0, current.totalSamples + length > samplesPerChunk {
                chunks.append(current)
                current = AudioChunk()
            }
            current.pieces.append(
                AudioChunk.Piece(
                    fileName: segment.fileName,
                    sessionStartMs: segment.startMs,
                    chunkOffset: current.totalSamples,
                    length: length
                )
            )
            current.totalSamples += length
        }
        if !current.pieces.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 读出一块的全部音频（按分片顺序拼接），**并用真实解码长度修正块内偏移**。
    ///
    /// 这里的修正不是可有可无的洁癖，而是必须做的补偿：
    /// 分块时用的是清单里的 `sampleCount`（写入时的输入样本数），
    /// 但 AAC 编码器有**启动延迟**，解码出来的样本数会比它多约两千个样本。
    /// 若拿估算值当块内偏移，一个 10 分钟的块里累计误差可达**一秒以上** ——
    /// 表现为"说话人标签整体后移"，而且越靠后的片段偏得越多。
    ///
    /// 另一方面，会话时间仍以每片自己的 `startMs` 为锚点（它由样本计数推导，
    /// 见设计文档 4.11），因此每片的绝对位置是准的，只有片内是近似的。
    private func loadSamples(_ chunk: inout AudioChunk) -> [Float]? {
        var result: [Float] = []
        result.reserveCapacity(chunk.totalSamples)

        var actualPieces: [AudioChunk.Piece] = []
        var offset = 0

        for piece in chunk.pieces {
            let url = RecordingLibrary.shared.segmentURL(
                sessionId: inputs.sessionId,
                fileName: piece.fileName
            )
            do {
                let samples = try WhisperEngine.loadSamples(from: url)
                guard !samples.isEmpty else { continue }
                actualPieces.append(
                    AudioChunk.Piece(
                        fileName: piece.fileName,
                        sessionStartMs: piece.sessionStartMs,
                        chunkOffset: offset,
                        length: samples.count
                    )
                )
                offset += samples.count
                result.append(contentsOf: samples)
            } catch {
                // 单片损坏不应中断整块：跳过它并在时间轴上留出空缺，
                // 由"缺失片"造成的边界偏移只影响该片，不会扩散到全块
                Log.shared.warn(
                    .asr,
                    "音频分片读取失败｜\(piece.fileName)｜\(error.localizedDescription)"
                )
            }
        }

        chunk.pieces = actualPieces
        chunk.totalSamples = offset
        return result.isEmpty ? nil : result
    }

    // MARK: - 质心与对齐

    /// 每个局部说话人的质心：取该说话人最长的几段算平均。
    ///
    /// 为什么取最长的几段：短片段（一声"嗯"、一个"对"）的声纹本来就不稳，
    /// 用它们算质心会把噪声带进身份判断。
    private static func localCentroids(
        turns: [SherpaDiarizer.Turn],
        samples: [Float],
        embedder: SherpaSpeakerEmbedder,
        maxSegmentsPerSpeaker: Int = 3
    ) -> [Int: [Float]] {
        var grouped: [Int: [SherpaDiarizer.Turn]] = [:]
        for turn in turns {
            grouped[turn.speaker, default: []].append(turn)
        }

        var result: [Int: [Float]] = [:]
        for (speaker, speakerTurns) in grouped {
            let longest = speakerTurns
                .sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) }
                .prefix(maxSegmentsPerSpeaker)

            var vectors: [[Float]] = []
            for turn in longest {
                let startSample = turn.startMs * 16
                let endSample = min(turn.endMs * 16, samples.count)
                guard startSample >= 0, endSample > startSample else { continue }
                let slice = Array(samples[startSample..<endSample])
                if let vector = embedder.embedding(of: slice) {
                    vectors.append(vector)
                }
            }

            if let centroid = SherpaSpeakerEmbedder.centroid(of: vectors) {
                result[speaker] = centroid
            }
        }
        return result
    }

    /// 在已有全局说话人里找最相似的；低于跨块阈值返回 nil（表示"新的人"）。
    private static func bestGlobalIndex(for centroid: [Float], in centroids: [[Float]]) -> Int? {
        var bestIndex: Int?
        var bestScore: Float = -1
        for (index, existing) in centroids.enumerated() {
            let score = SherpaSpeakerEmbedder.cosine(existing, centroid)
            if score > bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        guard let bestIndex, bestScore >= SpeakerMatching.crossChunkThreshold else { return nil }
        return bestIndex
    }

    /// 标记可能的重叠说话：不同说话人的时间段有实质交叠（> 200 ms）。
    private static func markOverlaps(_ turns: inout [SpeakerTurn]) {
        guard turns.count > 1 else { return }
        let minimumOverlapMs = 200

        for i in 0..<(turns.count - 1) {
            for j in (i + 1)..<turns.count {
                guard turns[i].speakerIndex != turns[j].speakerIndex else { continue }
                let overlap = min(turns[i].endMs, turns[j].endMs) - max(turns[i].startMs, turns[j].startMs)
                if overlap >= minimumOverlapMs {
                    turns[i].mayOverlap = true
                    turns[j].mayOverlap = true
                }
            }
        }
    }

    // MARK: - 组装

    /// 组装时间轴，并把全局说话人比对到声纹库。
    ///
    /// 注意 `SpeakerProfileStore` 是 @MainActor，本方法在后台队列上 ——
    /// 因此这里**只读地**用它的纯函数（merge/matchThreshold），
    /// 真正的档案读写在 `applyProfiles` 里回到主线程做。
    private func buildTimeline(
        turns: [SpeakerTurn],
        centroids: [[Float]],
        isComplete: Bool
    ) -> SpeakerTimeline {
        let sorted = turns.sorted { $0.startMs < $1.startMs }
        return SpeakerTimeline(
            sessionId: inputs.sessionId,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            segmentationModel: URL(fileURLWithPath: inputs.segmentationModelPath).lastPathComponent,
            embeddingModel: URL(fileURLWithPath: inputs.embeddingModelPath).lastPathComponent,
            speakerCount: centroids.count,
            turns: sorted,
            centroids: centroids,
            note: isComplete ? nil : "本次未跑完，可再次运行"
        )
    }
}
