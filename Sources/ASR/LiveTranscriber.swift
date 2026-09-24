import Foundation

/// 实时字幕引擎（**非 MainActor**，自带串行队列）。
///
/// ## 为什么要独立成一个非隔离的单例，而不是把逻辑放进 `LiveTranscriber`
/// 音频帧由 `CapturePipeline` 在**后台队列**上推送（`feed`）。若这个类被标成
/// `@MainActor`，后台队列就无权调用它，只能每一帧都跳回主线程 ——
/// 那正好违背了"把重活留在后台"的初衷。因此拆成两层：
///   · 本类：非隔离，负责收音频、跑滑窗、组装文本（所有重活）
///   · `LiveTranscriber`：@MainActor，只把结果发布给界面
///
/// ## 实时字幕的本质（必须先接受，否则会以为有 bug）
/// whisper 是**批式模型**，没有"边听边出字"的流式能力。因此实时字幕靠
/// **滑窗重解**：每个窗口都把最近十几秒重新识别一遍，结果是
/// **先出一版、再被改对**（自我修正）。所以：
///   · 窗口内的话一律标 `isProvisional = true`（界面显示"识别中"）
///   · 已经离开窗口的句子才冻结为定稿（`isProvisional = false`）
/// 这条规则让"文字跳动"变成可理解的行为，而不是故障（设计文档 R15）。
final class LiveTranscriptionEngine {

    static let shared = LiveTranscriptionEngine()

    // MARK: - 可调参数（先给保守默认值，真机实测后再定）

    /// 滑窗长度：每次重解最近多少秒。
    /// 取 15 秒的理由：太短则句子被从中间切断、识别质量下降；
    /// 太长则每次重算的量变大，反馈也变慢。
    private let windowSeconds = 15

    /// 步长：每积累多少秒新音频触发一次重解。
    /// 取 5 秒是**能耗与体感的折中** —— 相当于约 3 倍实时算力占用；
    /// 若真机实测发热明显，把它调大即可（这是首要的调优点）。
    private let hopSeconds = 5

    /// 最少音频量：whisper 对极短输入无意义（且易产生幻觉）
    private let minimumSeconds = 1

    private let sampleRate = 16_000

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.xfish.moments.asr.live", qos: .utility)

    /// 保护 `pending` / `fedSamples` / `pausedFlag`：它们跨队列访问
    /// （`feed` 来自采集管线队列，其余来自本引擎队列与主线程）。
    private let lock = NSLock()
    private var pending: [Float] = []
    private var fedSamples = 0
    private var pausedFlag = false
    private var stopRequested = false

    // 以下仅在 queue 上访问
    private var window: [Float] = []
    private var engine: WhisperEngine?
    private var timer: DispatchSourceTimer?
    private var lastRunSampleIndex = 0
    private var display: [TranscriptSegment] = []
    private var modelURL: URL?
    private var language = "auto"
    private var didFailLoading = false

    // M3：真 VAD 与降噪器。都按需加载、且只在本引擎队列上使用 ——
    // 这两个类都持有 C 指针、不是线程安全的，因此一路一实例、不共享。
    private var denoiseEnabled = false
    private var vad: SherpaVad?
    private var denoiser: SherpaDenoiser?
    private var didAttemptLoadingHelpers = false
    /// 降噪失败只提示一次：滑窗每几秒跑一次，若每次都记日志会把日志刷爆，
    /// 而"降噪失败"这件事看一次就够了。
    private var hasReportedDenoiseFailure = false

    // MARK: - 实时统计（供日志汇总）
    //
    // 为什么要在这一侧自己统计：传给 whisper 的 `isQuiet = true` 会把它内部那句
    // 「转写完成｜耗时/实时倍率」一并压掉（那是为了避免日志被 5 秒一次的窗口重解淹掉）。
    // 结果是**实时路径上最关键的指标反而消失了** —— 引擎静音是对的，但不该连数据都没有。
    // 这里按窗口累计、每 N 个窗口汇总一行：既不刷屏，又能回答
    // 「实时字幕到底跟不跟得上采集」。
    private var windowCount = 0
    private var silentWindowCount = 0
    private var producedSegments = 0
    private var totalCostMs = 0
    private var maxCostMs = 0
    /// "窗口还太短"的提示只记一次，避免刚开录音那几秒每秒刷一行
    private var hasReportedShortWindow = false

    /// 每多少个窗口汇总一行统计
    private static let statsEveryWindows = 10

    /// 结果回调。**在本引擎队列上触发**，调用方需自行切回主线程。
    var onSegments: (([TranscriptSegment]) -> Void)?
    /// 状态回调（模型加载中 / 运行中 / 已暂停 / 失败）。同样在引擎队列上触发。
    var onStatus: ((String) -> Void)?

    private init() {}

    // MARK: - 生命周期

    /// 开始实时字幕。可在录音开始时调用。
    /// - Parameter denoiseEnabled: 是否先把窗口音频降噪再识别（M3）。
    ///   默认关 —— 降噪会引入失真伪影，可能反而更差（见 SherpaDenoiser）。
    func start(modelURL: URL, language: String, denoiseEnabled: Bool = false) {
        lock.lock()
        pending.removeAll()
        fedSamples = 0
        pausedFlag = false
        stopRequested = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.modelURL = modelURL
            self.language = language
            self.denoiseEnabled = denoiseEnabled
            self.window = []
            self.display = []
            self.lastRunSampleIndex = 0
            self.didFailLoading = false
            self.prepareHelpersIfNeeded()

            guard self.engine == nil else {
                self.startTimer()
                self.onStatus?(self.runningStatusText)
                return
            }

            self.onStatus?("正在加载实时字幕模型…")
            let engine = WhisperEngine(modelPath: modelURL.path)
            engine.isQuiet = true   // 见 WhisperEngine.isQuiet：否则会把日志淹掉
            if engine.load() {
                self.engine = engine
                self.startTimer()
                self.onStatus?(self.runningStatusText)
            } else {
                self.didFailLoading = true
                self.onStatus?("实时字幕模型加载失败：\(engine.lastError ?? "未知原因")")
                Log.shared.error(.asr, "实时字幕模型加载失败｜\(engine.lastError ?? "未知原因")")
            }
        }
    }

    /// 状态文案要把「实际生效的能力」写出来。
    /// 用户开了降噪却发现没效果、或 VAD 模型缺失导致行为变化，
    /// 都应该能从界面上看出来，而不是靠猜。
    private var runningStatusText: String {
        var parts = ["实时字幕已启动"]
        if vad != nil { parts.append("VAD 已启用") }
        if denoiseEnabled {
            parts.append(denoiser != nil ? "降噪已启用" : "降噪不可用（模型缺失）")
        }
        return parts.joined(separator: "｜")
    }

    /// 按需加载 VAD 与降噪模型。
    ///
    /// VAD 与降噪都是 M3 才引入的，且都内置在 App 包里（见 SherpaBundledModel）。
    /// 这里刻意**允许失败并降级**：模型缺失时回退到 M2 的行为
    /// （能量门限 / 原始音频），而不是让整个实时字幕不可用 ——
    /// 少一个增强能力，好过少一个主功能。
    private func prepareHelpersIfNeeded() {
        if !didAttemptLoadingHelpers {
            didAttemptLoadingHelpers = true

            if let vadURL = SherpaBundledModel.sileroVad.url {
                vad = SherpaVad(modelPath: vadURL.path)
                if vad == nil {
                    Log.shared.warn(.asr, "VAD 模型加载失败，回退到能量门限判定")
                }
            } else {
                Log.shared.warn(.asr, "未找到内置 VAD 模型，回退到能量门限判定")
            }
        }

        guard denoiseEnabled else { return }
        guard denoiser == nil else { return }

        guard let denoiserURL = SherpaBundledModel.gtcrn.url else {
            Log.shared.warn(.asr, "未找到内置降噪模型，将使用原始音频")
            return
        }
        denoiser = SherpaDenoiser(modelPath: denoiserURL.path)
        if denoiser == nil {
            Log.shared.warn(.asr, "降噪器加载失败，将使用原始音频")
        }
    }

    /// 窗口内是否有人声：优先用真 VAD，模型缺失时回退到 M2 的能量门限。
    private func windowContainsSpeech(_ samples: [Float]) -> Bool {
        if let vad {
            return vad.containsSpeech(in: samples)
        }
        return TranscriptMath.hasSpeech(samples)
    }

    /// 按设置可选地对窗口降噪。
    ///
    /// **失败必须回退到原始音频**：为了一次降噪失败而丢掉整窗字幕是不可接受的
    /// （降噪是增强项，字幕是主功能）。
    private func maybeDenoise(_ samples: [Float]) -> [Float] {
        guard denoiseEnabled, let denoiser else { return samples }
        guard let enhanced = denoiser.denoise(samples), !enhanced.isEmpty else {
            if !hasReportedDenoiseFailure {
                hasReportedDenoiseFailure = true
                Log.shared.warn(.asr, "降噪失败，已回退到原始音频（后续不再重复提示）")
            }
            return samples
        }
        return enhanced
    }

    func stop() {
        lock.lock()
        stopRequested = true
        pending.removeAll()
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.engine?.unload()
            self.engine = nil
            // M3 的两个模型也要显式释放：它们各自持有 ONNX 会话，
            // 不释放会一直占内存（本项目的会话可能连续录 8 小时，内存必须能回收）
            self.vad?.close()
            self.vad = nil
            self.denoiser?.close()
            self.denoiser = nil
            self.didAttemptLoadingHelpers = false
            self.hasReportedDenoiseFailure = false
            self.window = []
            self.display = []
            self.lastRunSampleIndex = 0
            self.onStatus?("实时字幕已停止")
            Log.shared.info(.asr, "实时字幕已停止")
        }
    }

    /// 暂停 / 恢复（终稿转写期间必须暂停，两者同时跑会互相抢 CPU 并拖累录音）。
    func setPaused(_ paused: Bool) {
        lock.lock()
        pausedFlag = paused
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            if self.engine != nil {
                self.onStatus?(paused ? "实时字幕已暂停（正在跑终稿转写）" : "实时字幕已恢复")
            }
        }
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedFlag
    }

    // MARK: - 音频入口（由采集管线在后台队列调用，必须线程安全且足够便宜）

    /// 推入 16 kHz 单声道样本。
    ///
    /// **这里只做入队**：真正的识别在本引擎的队列上异步进行。
    /// 采集管线所在的队列还要负责落盘，绝不能在这里阻塞。
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: samples)
        fedSamples += samples.count
        lock.unlock()
    }

    // MARK: - 定时驱动

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        drainPending()

        lock.lock()
        let fed = fedSamples
        let paused = pausedFlag
        let stopped = stopRequested
        lock.unlock()

        guard !stopped, !paused, !didFailLoading else { return }
        guard let engine else { return }

        // 步长未到，不必重算
        let newSamples = fed - lastRunSampleIndex
        guard newSamples >= hopSeconds * sampleRate else { return }

        let neededFrames = Int(minimumSeconds * sampleRate)
        guard window.count >= neededFrames else {
            // 窗口还太短 —— 这是"刚开录音后几秒没有字幕"的正常原因，
            // 但**必须说一次**：否则界面没字、日志没记、也不报错，
            // 看起来就像实时字幕整个坏了。
            if !hasReportedShortWindow {
                hasReportedShortWindow = true
                Log.shared.info(
                    .asr,
                    "实时字幕在等首个完整窗口｜当前 \(window.count) 帧 / 需要 \(neededFrames) 帧"
                )
            }
            return
        }

        lastRunSampleIndex = fed

        // 窗口之前的部分已经定稿，重算没有意义；无语音时直接跳过，
        // 避免 whisper 对静音"编造"文本。
        //
        // M3 起这里优先用真 VAD（Silero）判定 —— 能量门限分不清"人声"与
        // "稳定的噪声"，空调声/风扇声都能越过它，幻觉文本照样出现。
        guard windowContainsSpeech(window) else {
            // 跳过静音也要计数：它是"连续几分钟没出字幕"最可能的解释，
            // 汇总行里必须能看到，否则只能往"识别坏了"的方向去怀疑。
            silentWindowCount += 1
            reportLiveStatsIfNeeded(windowFrames: window.count)
            return
        }

        let windowStartMs = Int(Double(fed - window.count) / Double(sampleRate) * 1000.0)
        // 降噪在这里临时施加（原始音频始终没有被动过）
        let audio = maybeDenoise(window)

        // 计时用**单调时钟**而不是墙钟：窗口耗时是性能指标，
        // 系统对时会让墙钟跳变，而单调时钟不会（与看门狗同一取舍）
        let started = ProcessInfo.processInfo.systemUptime
        let local = engine.transcribe(
            samples: audio,
            language: language == "auto" ? nil : language,
            translateToEnglish: false
        )
        let costMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)

        windowCount += 1
        producedSegments += local.count
        totalCostMs += costMs
        maxCostMs = max(maxCostMs, costMs)

        let mapped = TranscriptMath.mapToSessionTimeline(
            local: local,
            sessionStartMs: windowStartMs,
            seqBase: 0,
            isProvisional: true
        )
        assemble(windowSegments: mapped, windowStartMs: windowStartMs)
        reportLiveStatsIfNeeded(windowFrames: window.count)
    }

    /// 每 N 个窗口汇总一行实时统计（含**实时倍率**）。
    ///
    /// 实时倍率 = 平均耗时 ÷ 窗口音频时长。**≥ 1.0 就意味着识别慢于采集**，
    /// 表现为字幕越落越远 —— 这正是概念文档 P23 缺的那项数据，
    /// 也是判断"实时字幕这台设备上到底可不可行"的唯一依据。
    private func reportLiveStatsIfNeeded(windowFrames: Int) {
        let total = windowCount + silentWindowCount
        guard total > 0, total % Self.statsEveryWindows == 0 else { return }

        let windowMs = windowFrames * 1000 / max(1, Int(sampleRate))
        let avgCost = windowCount > 0 ? totalCostMs / windowCount : 0
        let ratio = windowMs > 0 ? Double(avgCost) / Double(windowMs) : 0

        let summary = "实时字幕统计｜窗口 \(windowCount) 个（跳过静音 \(silentWindowCount) 个）"
            + "｜平均耗时 \(avgCost)ms｜最慢 \(maxCostMs)ms｜窗口音频 \(windowMs)ms"
            + "｜实时倍率 \(String(format: "%.2f", ratio))｜累计出句 \(producedSegments)"

        if windowCount > 0, ratio >= 1.0 {
            Log.shared.warn(.asr, summary + "｜【倍率 ≥ 1.0：识别慢于采集，字幕会越落越远】")
        } else {
            Log.shared.info(.asr, summary)
        }
    }

    /// 把待处理样本并入滑窗，并把窗口裁剪到设定长度。
    private func drainPending() {
        lock.lock()
        let incoming = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !incoming.isEmpty else { return }
        window.append(contentsOf: incoming)

        // 裁剪：只保留最近 windowSeconds 秒。
        // 不裁剪的话，8 小时录音会把整段音频都留在内存里 —— 那是必然的崩溃。
        let maximum = windowSeconds * sampleRate
        if window.count > maximum {
            window.removeFirst(window.count - maximum)
        }
    }

    /// 组装显示列表：**窗口内重写、窗口外冻结**。
    ///
    /// 这一步是"自我修正"体验的落点：用户在屏幕上看到的最新几句可能变，
    /// 但更早的内容不会再变 —— 这正是承诺给他人的行为。
    private func assemble(windowSegments: [TranscriptSegment], windowStartMs: Int) {
        let frozen = display.filter { $0.endMs <= windowStartMs }
        let combined = frozen + windowSegments

        // 重新编号，保证顺序稳定（界面用 seq 排序，而不是依赖时间戳相等性）
        display = combined.enumerated().map { index, segment in
            var copy = segment
            copy.seq = index
            return copy
        }

        onSegments?(display)
    }
}

/// 实时字幕的界面侧封装（`@MainActor`）。
///
/// 只做两件事：把 `LiveTranscriptionEngine` 的回调切回主线程并发布；
/// 以及给界面提供"当前是否在跑"的状态。这些状态必须由主线程发布，
/// 因此本类是 `@MainActor`，而引擎不是 —— 见 `LiveTranscriptionEngine` 的说明。
@MainActor
final class LiveTranscriber: ObservableObject {

    static let shared = LiveTranscriber()

    /// 当前显示的字幕（含"识别中"的临时句）
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var statusText = "未启动"
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false

    private init() {
        let engine = LiveTranscriptionEngine.shared
        engine.onSegments = { [weak self] segments in
            Task { @MainActor in self?.segments = segments }
        }
        engine.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
                self?.isActive = !status.contains("停止") && !status.contains("失败")
            }
        }
    }

    /// 开始实时字幕。需要调用方（录音页）先确认模型已下载。
    func start(modelURL: URL, language: String, denoiseEnabled: Bool = false) {
        segments = []
        statusText = "正在启动…"
        LiveTranscriptionEngine.shared.start(
            modelURL: modelURL,
            language: language,
            denoiseEnabled: denoiseEnabled
        )
    }

    func stop() {
        LiveTranscriptionEngine.shared.stop()
        segments = []
        isActive = false
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        LiveTranscriptionEngine.shared.setPaused(paused)
    }

    /// 清空界面上的字幕（开始新会话时用）。
    /// 注意这里**不动引擎内部状态** —— 引擎的滑窗是连续音频的载体，
    /// 清空它会让后续识别丢掉上下文。
    func clearDisplay() {
        segments = []
    }

    var previewText: String {
        segments.suffix(3).map { $0.text }.joined(separator: " ")
    }
}
