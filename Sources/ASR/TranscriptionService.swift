import Foundation

/// 转写任务的阶段（界面直接绑定）。
///
/// 放在顶层而不是嵌套在 `TranscriptionService` 里：worker 是非 MainActor 的普通类，
/// 若该枚举定义在 @MainActor 类内部，跨隔离域引用它会产生额外的隔离约束问题。
enum TranscriptionStage: Equatable {
    case idle
    case loadingModel
    case transcribing
    case saving
    case done
    case failed(String)
    case cancelled

    var text: String {
        switch self {
        case .idle: return "空闲"
        case .loadingModel: return "正在加载模型…"
        case .transcribing: return "正在转写…"
        case .saving: return "正在保存…"
        case .done: return "已完成"
        case .failed(let message): return "失败：\(message)"
        case .cancelled: return "已取消（已转部分保留）"
        }
    }

    /// 是否处于"占用引擎"的状态。实时字幕据此主动避让（见 LiveTranscriptionEngine.setPaused）。
    var isActive: Bool {
        switch self {
        case .loadingModel, .transcribing, .saving: return true
        default: return false
        }
    }
}

/// 终稿转写服务：把一次会话的全部分片依次转写成文字（设计文档 5.4 的第二遍）。
///
/// ## 为什么是「批处理」而不是「流式」
/// whisper 本质是「喂一段音频 → 吐一段文字」的批式模型。终稿的定位是**准确**，
/// 因此它跑在闲置时段（充电 / 息屏），一次处理若干分钟，而不是边录边算。
/// 这样既不与录音抢 CPU，也不占用用户使用时段。
///
/// ## 职责划分（为什么必须分两个类）
/// 本类是 `@MainActor`，只做**编排与状态发布**；真正的重活交给 `TranscriptionWorker`
/// （普通类，自带串行队列）。这不是为了"设计好看"，而是因为 whisper 上下文
/// 不是线程安全的、且转写必须离开主线程 —— 若把重活写在 @MainActor 类里，
/// 就会被迫在后台队列上调用主 actor 隔离的方法，那属于隔离违规。
/// 这与 M1 把重活放进 `CapturePipeline` 是同一个理由。
@MainActor
final class TranscriptionService: ObservableObject {

    static let shared = TranscriptionService()

    @Published private(set) var stage: TranscriptionStage = .idle
    @Published private(set) var runningSessionId: String?
    @Published private(set) var processedSegments = 0
    @Published private(set) var totalSegments = 0
    @Published private(set) var lastMessage: String?

    /// 最近一次转写的实时倍率（耗时 / 音频时长）。< 1.0 表示快于实时。
    /// 这是判断"这台设备能不能做实时字幕"的唯一硬指标，必须留下实测值。
    @Published private(set) var lastRealtimeRatio: Double = 0

    private var worker: TranscriptionWorker?

    var isBusy: Bool { stage.isActive }

    var progress: Double {
        guard totalSegments > 0 else { return 0 }
        return min(1.0, Double(processedSegments) / Double(totalSegments))
    }

    private init() {}

    // MARK: - 对外入口

    /// 转写一次会话。
    /// - Parameters:
    ///   - pass: 实时稿或终稿（本服务的典型用法是终稿）
    ///   - modelId: 使用的模型；nil 时取该稿的默认模型
    ///   - language: 语言代码，"auto" 表示自动判定
    func transcribe(
        sessionId: String,
        pass: TranscriptPass = .final,
        modelId: String? = nil,
        language: String = "auto",
        denoise: Bool = false
    ) {
        guard !isBusy else {
            Log.shared.warn(.asr, "已有转写任务在跑，忽略本次请求｜\(sessionId)")
            lastMessage = "已有转写任务在进行中"
            return
        }

        let resolvedId = modelId ?? (pass == .final
            ? WhisperModelCatalog.finalDefaultId
            : WhisperModelCatalog.realtimeDefaultId)

        guard let descriptor = WhisperModelCatalog.model(id: resolvedId) else {
            stage = .failed("未知模型 \(resolvedId)")
            return
        }

        // 明确区分"模型没下载"与"转写失败"：界面据此给出不同引导（去下载，而不是重试）
        guard let modelURL = ModelManager.shared.installedURL(for: resolvedId) else {
            stage = .failed(TranscriptionError.modelNotInstalled(descriptor.displayName).localizedDescription)
            Log.shared.warn(.asr, "转写被拒：模型未下载｜\(descriptor.displayName)")
            return
        }

        guard var manifest = RecordingLibrary.shared.loadManifest(sessionId: sessionId) else {
            stage = .failed(TranscriptionError.sessionNotFound(sessionId).localizedDescription)
            return
        }

        // 音频可能已被保留期策略清理（设计文档 4.5：文本永久、音频有限）。
        // 这时要明确说"音频已清理"，而不是报一个含糊的失败让用户反复重试。
        manifest.segments = manifest.segments.filter { entry in
            FileManager.default.fileExists(
                atPath: RecordingLibrary.shared
                    .segmentURL(sessionId: sessionId, fileName: entry.fileName).path
            )
        }

        guard !manifest.segments.isEmpty else {
            stage = .failed(TranscriptionError.noAudioAvailable("音频已按保留期清理，或分片尚未落盘").localizedDescription)
            Log.shared.warn(.asr, "转写被拒：无可用音频｜\(sessionId)")
            return
        }

        let inputs = TranscriptionWorker.Inputs(
            manifest: manifest,
            pass: pass,
            descriptor: descriptor,
            modelURL: modelURL,
            language: language,
            existing: TranscriptStore.shared.load(sessionId: sessionId, pass: pass),
            applyDenoise: denoise
        )

        runningSessionId = sessionId
        processedSegments = 0
        totalSegments = manifest.segments.count
        stage = .loadingModel
        lastMessage = "开始\(pass.title)｜\(manifest.segments.count) 个分片"
            + "｜模型 \(descriptor.displayName)"
            + (denoise ? "｜音频已降噪" : "｜音频为原始轨")

        // 让实时字幕避让：两者同时跑会互相抢 CPU，结果是录音被拖累（设计文档 5.4）
        LiveTranscriber.shared.setPaused(true)

        let worker = TranscriptionWorker(inputs: inputs)

        worker.onStage = { [weak self] newStage in
            Task { @MainActor in self?.stage = newStage }
        }
        worker.onProgress = { [weak self] processed, total in
            Task { @MainActor in
                self?.processedSegments = processed
                self?.totalSegments = total
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
        Log.shared.info(.asr, "转写取消请求已发出｜已转部分会保留")
    }

    // MARK: - 结果处理

    private func handle(_ outcome: TranscriptionWorker.Outcome) {
        worker = nil
        runningSessionId = nil
        LiveTranscriber.shared.setPaused(false)

        switch outcome {
        case .finished(let document, let elapsedMs):
            lastRealtimeRatio = TranscriptMath.realtimeRatio(
                elapsedMs: elapsedMs,
                audioMs: document.coveredMs
            )
            stage = .done
            lastMessage = "\(document.pass.title)完成｜\(document.segments.count) 句"
                + "｜\(document.characterCount) 字"
                + "｜实时倍率 \(String(format: "%.2f", lastRealtimeRatio))"
            Log.shared.info(.asr, lastMessage ?? "")

        case .cancelled(let document):
            stage = .cancelled
            lastMessage = document.map { "已取消｜已保留 \($0.segments.count) 句" } ?? "已取消"
            Log.shared.info(.asr, lastMessage ?? "")

        case .failed(let message):
            stage = .failed(message)
            lastMessage = message
            Log.shared.error(.asr, "转写失败｜\(message)")
        }
    }
}

/// 转写执行体（**非 MainActor**，自带串行队列）。
///
/// 所有对 `WhisperEngine` 的调用都落在这条队列上 —— whisper 上下文不是线程安全的。
/// 回调在**本条队列上**触发，由调用方自行切回主线程（本项目统一用 `Task { @MainActor in }`）。
final class TranscriptionWorker {

    struct Inputs {
        let manifest: SessionManifest
        let pass: TranscriptPass
        let descriptor: WhisperModelDescriptor
        let modelURL: URL
        let language: String
        let existing: TranscriptDocument?
        /// M3：是否在识别前对音频降噪。
        /// 只有「对照稿」会置为 true —— 终稿按设计**始终使用原始音频**，
        /// 以免降噪伪影影响留档质量（见 SherpaDenoiser）。
        let applyDenoise: Bool
    }

    enum Outcome {
        case finished(TranscriptDocument, elapsedMs: Int)
        case cancelled(TranscriptDocument?)
        case failed(String)
    }

    private let inputs: Inputs
    private let queue = DispatchQueue(label: "com.xfish.moments.asr.worker", qos: .utility)

    /// 取消标志。用锁而不是"往队列里塞一个任务"来设置 ——
    /// 后者会排在正在运行的转写任务之后，等于取消要等它跑完才生效，那就没有意义了。
    private let cancelLock = NSLock()
    private var cancelled = false

    var onStage: ((TranscriptionStage) -> Void)?
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
        let manifest = inputs.manifest
        let total = manifest.segments.count

        let engine = WhisperEngine(modelPath: inputs.modelURL.path)
        let startedAt = Date()

        onStage?(.loadingModel)
        guard engine.load() else {
            onFinished?(.failed(engine.lastError ?? "模型加载失败"))
            return
        }

        // M3：真 VAD 与（可选的）降噪。同样**允许失败并降级** ——
        // 模型缺失时回退到 M2 的能量门限与原始音频：
        // 少一个增强能力，好过整次转写失败。
        let vad: SherpaVad? = SherpaBundledModel.sileroVad.url.flatMap {
            SherpaVad(modelPath: $0.path)
        }
        if vad == nil {
            Log.shared.warn(.asr, "VAD 不可用，本次转写回退到能量门限判定寂静")
        }

        var denoiser: SherpaDenoiser?
        if inputs.applyDenoise {
            denoiser = SherpaBundledModel.gtcrn.url.flatMap {
                SherpaDenoiser(modelPath: $0.path)
            }
            if denoiser == nil {
                // 明确说出来：否则"对照稿"会静默地等同于终稿，用户会得出错误结论
                Log.shared.warn(.asr, "降噪不可用，本次对照稿将等同终稿（请检查内置模型是否齐备）")
            }
        }

        // 续跑：已有未完成的稿时，从已覆盖时间点之后接着做。
        // 避免"跑了两小时被系统杀掉、重启又要从头再来"。
        var segments: [TranscriptSegment] = []
        var startIndex = 0
        if let existing = inputs.existing, !existing.isComplete, !existing.segments.isEmpty {
            segments = existing.segments
            let covered = existing.coveredMs
            startIndex = manifest.segments.firstIndex { $0.endMs > covered } ?? total
            Log.shared.info(.asr, "续跑\(inputs.pass.title)｜已覆盖 \(covered)ms｜从第 \(startIndex + 1) 片继续")
        }

        onStage?(.transcribing)
        onProgress?(startIndex, total)

        var failedSegments = 0

        if startIndex < total {
            for index in startIndex..<total {
                // 取消只在这些边界上生效：whisper 单次调用无法中途打断，
                // 但一片只有几十秒音频，所以取消延迟是可接受的（秒级）。
                if isCancelled {
                    Log.shared.info(.asr, "转写在第 \(index + 1) 片处取消")
                    break
                }

                let entry = manifest.segments[index]
                let url = RecordingLibrary.shared.segmentURL(sessionId: manifest.id, fileName: entry.fileName)

                do {
                    let samples = try WhisperEngine.loadSamples(from: url)

                    // 语音判定：优先真 VAD，缺失时回退 M2 的能量门限
                    let hasSpeech = vad?.containsSpeech(in: samples)
                        ?? TranscriptMath.hasSpeech(samples)

                    if hasSpeech {
                        // 降噪只在对照稿里施加；失败时回退原始音频（见 SherpaDenoiser）
                        let audio = denoiser?.denoise(samples) ?? samples
                        let local = engine.transcribe(
                            samples: audio,
                            language: inputs.language == "auto" ? nil : inputs.language,
                            translateToEnglish: false
                        )
                        // 相对分片 → 相对会话。做错的后果是点句回听定位偏移（见 TranscriptMath）
                        segments.append(contentsOf: TranscriptMath.mapToSessionTimeline(
                            local: local,
                            sessionStartMs: entry.startMs,
                            seqBase: segments.count,
                            isProvisional: false
                        ))
                    } else {
                        Log.shared.info(.asr, "分片 \(entry.fileName) 判定为静音，跳过")
                    }
                } catch {
                    // 单片失败不中断整次转写：记下来继续，最后如实报告损失。
                    // 理由：一次 8 小时会话有几百片，因一片坏文件整次作废是不可接受的。
                    failedSegments += 1
                    Log.shared.error(
                        .asr,
                        "分片转写失败｜\(entry.fileName)｜\(error.localizedDescription)｜继续下一片"
                    )
                }

                onProgress?(index + 1, total)

                // 每片落盘一次：中途被杀也能保住已完成的部分（可续跑的前提）
                TranscriptStore.shared.saveAsync(makeDocument(
                    segments: segments,
                    isComplete: false,
                    note: "转写进行中（\(index + 1)/\(total)）"
                ))
            }
        }

        engine.unload()
        // M3 的两个模型也显式释放：各自持有 ONNX 会话，占内存；
        // 一次转写可能跑几百个分片，跑完必须还回去
        vad?.close()
        denoiser?.close()

        if isCancelled {
            onFinished?(.cancelled(makeDocument(segments: segments, isComplete: false, note: "已取消，可再次点击继续")))
            return
        }

        let completedAll = failedSegments == 0
        let note = completedAll ? nil : "本次有 \(failedSegments) 片未能转写，可再次点击继续"
        let document = makeDocument(segments: segments, isComplete: completedAll, note: note)

        onStage?(.saving)
        do {
            try TranscriptStore.shared.save(document)
            onFinished?(.finished(document, elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000)))
        } catch {
            onFinished?(.failed("保存转写稿失败：\(error.localizedDescription)"))
        }
    }

    private func makeDocument(segments: [TranscriptSegment], isComplete: Bool, note: String?) -> TranscriptDocument {
        TranscriptDocument(
            sessionId: inputs.manifest.id,
            pass: inputs.pass,
            modelId: inputs.descriptor.id,
            language: inputs.language,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            isComplete: isComplete,
            segments: segments,
            note: note
        )
    }
}

/// 转写相关的纯计算。
///
/// 单独抽出来是因为这两件事**都容易算错、且错了不会报错**：
/// 时间轴算错表现为"回听位置偏一点"，能量门限算错表现为"多几句幻觉文字"。
/// 独立成纯函数便于在自检页直接验证，不必依赖真机长录。
enum TranscriptMath {

    /// 把「相对分片」的毫秒映射为「相对会话」的毫秒。
    static func mapToSessionTimeline(
        local: [WhisperEngine.Segment],
        sessionStartMs: Int,
        seqBase: Int,
        isProvisional: Bool
    ) -> [TranscriptSegment] {
        local.enumerated().compactMap { offset, item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                id: "seg-\(seqBase + offset)-\(sessionStartMs + item.startMs)",
                seq: seqBase + offset,
                startMs: sessionStartMs + item.startMs,
                endMs: sessionStartMs + item.endMs,
                text: text,
                speakerId: nil,
                isProvisional: isProvisional
            )
        }
    }

    /// 极简能量门限（VAD-lite）。
    ///
    /// 为什么需要它：whisper 面对纯噪声或音乐时会**编造出文本**（典型的"字幕幻觉"），
    /// 而且编得很像真的，用户会以为识别出了问题。用均方根幅度做一个下限判断，
    /// 代价几乎为零，却能挡掉大部分幻觉。
    ///
    /// 注意这**不是**设计文档 4.6 里说的 Silero VAD（那是 M3 用 sherpa-onnx 做的事），
    /// 这里只要"这段到底有没有人声"这一位信息。
    static func hasSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }

        // 分段采样：长音频全量求和没有必要，取若干窗口已足以代表整体能量
        let windowSize = 1600  // 0.1 秒 @16kHz
        var maximumRMS: Float = 0
        var index = 0
        while index + windowSize <= samples.count {
            var sum: Float = 0
            for offset in index..<(index + windowSize) {
                sum += samples[offset] * samples[offset]
            }
            let rms = (sum / Float(windowSize)).squareRoot()
            maximumRMS = max(maximumRMS, rms)
            index += windowSize
        }

        // 阈值 0.004 是经验值，约对应"很轻的说话声"。
        // 取向是**宁可放进一点噪声，也不要漏掉轻声说话** ——
        // 漏掉是"录音没录上"，放进噪声只是"多一句可忽略的错字"，两者后果不对等。
        return maximumRMS > 0.004
    }

    /// 实时倍率 = 转写耗时 / 音频时长。< 1.0 表示快于实时。
    static func realtimeRatio(elapsedMs: Int, audioMs: Int) -> Double {
        guard audioMs > 0 else { return 0 }
        return Double(elapsedMs) / Double(audioMs)
    }
}
