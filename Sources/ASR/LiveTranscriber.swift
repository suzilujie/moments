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
/// SenseVoice 是**批式模型**，没有"边听边出字"的流式能力 —— 所以实时字幕必然是
/// "攒一段、送一次、等结果"。真正的问题是**攒到什么程度送**。
///
/// 原先是固定时长滑窗（每 5 秒把最近 15 秒重解一遍），切点与说话节奏无关，
/// 于是句子被从中间切断、同一段音频被解 3 次、屏幕上出现重复与碎片。
/// **2026-09-24 起改为由 VAD 决定切点**：一句话说完（停顿够长）才送识别。
///
/// 因此行为承诺也变了：
///   · 原先：窗口内重写、窗口外冻结（文字会跳动，但会"自我修正"）
///   · 现在：**成句即定稿** —— 识别一段就是一段，文字不再变
/// 这是刻意的取舍：用户此前的反馈正是"重复与碎片"，而它们来自重解。
/// 用"不再跳动"换掉"自我修正"是划算的（详见可调参数处的说明）。
final class LiveTranscriptionEngine {

    static let shared = LiveTranscriptionEngine()

    // MARK: - 可调参数
    //
    // ## 切窗方式（2026-09-24 改动）：从「固定时长滑窗」改为「VAD 句子边界」
    //
    // 原先每 5 秒把最近 15 秒重新识别一遍。它的三个后果都真实发生过：
    //   · 句子被从中间切断（切点与说话节奏无关）
    //   · 同一段音频被解 3 次（窗口 15 秒 / 步长 5 秒），三次结果并不相同
    //     → 屏幕上出现重复与碎片（要靠拼接层打补丁）
    //   · 3 倍算力换来的只是"自我修正"，代价是文字在眼前跳动
    //
    // 现在改为**由 VAD 决定切点**：一句话说完（停顿够长）才送去识别。
    // 于是送进去的都是完整句子，同一段音频只解一次。
    //
    // 代价（必须知道，否则会当成 bug）：
    //   · 出字时机由说话节奏决定 —— 说完一句后约 0.4~1 秒显示，
    //     而不是固定的每 5 秒一次；连续不停顿说话时最长等 vadMaxSpeechSeconds
    //   · **不再有"窗口内重写"**：识别一段即定稿，文字不会再变
    //
    // 若真机上觉得出字太慢，v2 可以加回"临时预览"：把**尚未切出**的音频
    // 也每隔几秒识别一次、只作临时显示（标 isProvisional），切窗时被替换。
    // 本次刻意不做 —— 一次只改一个变量。

    /// 单段最长时长，直接传给 VAD 的 `max_speech_duration`。
    ///
    /// 说话不停顿时 VAD 会在到点处切开，所以**它也是最坏情况下一个字都不出的时长**。
    /// 取 12 秒：whisper 单窗上限是 30 秒，12 秒有充分余量；
    /// 同时对"一口气说很久"的人不至于等太久。觉得出字慢就调小它。
    private let vadMaxSpeechSeconds = 12

    /// 停顿多久算"这句说完了"。取 0.4 秒：比 0.5 更跟手，
    /// 又不会把句中的自然换气当成句尾（0.2 秒以下会切得过碎）。
    private let vadMinSilenceSeconds: Float = 0.4

    /// 静音期间保留的前导音频。
    ///
    /// 下一句开始时它已经在 tail 里，相当于自动给 whisper 一点前置上下文 ——
    /// 切在第一个音素上会削掉起音（"你好"听成"好"）。
    private let prerollSeconds = 0.3

    /// VAD 缺失时的兜底：固定切窗长度（退回 M2 的行为）。
    private let fallbackCutSeconds = 10

    /// 最少音频量：whisper 对极短输入无意义（且易产生幻觉）。
    /// 不足则**不清空** tail，让这几百毫秒并进下一句 —— 丢掉它等于丢掉一个词。
    private let minimumSeconds = 1

    private let sampleRate = 16_000

    private var prerollFrames: Int { Int(prerollSeconds * Double(sampleRate)) }

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.xfish.moments.asr.live", qos: .utility)

    /// 保护 `pending` / `pausedFlag` / `stopRequested`：它们跨队列访问
    /// （`feed` 来自采集管线队列，其余来自本引擎队列与主线程）。
    private let lock = NSLock()
    private var pending: [Float] = []
    private var pausedFlag = false
    private var stopRequested = false
    /// 入口处因超限而丢掉的帧数（**受 lock 保护**）。
    /// tick 取走后累加到 `totalEntryDroppedFrames`（仅队列内访问）。
    private var pendingDroppedFrames = 0

    /// `pending` 的入口上限（秒）。30 秒足够吸收任何正常的调度抖动，
    /// 同时把内存钉在约 1.9 MB —— 详见 `feed` 里的说明。
    private let pendingLimitSeconds = 30

    // 以下仅在 queue 上访问
    /// **尚未识别的音频**（自上一次切窗起累积）。
    ///
    /// 这是本类最核心的一块状态，与原先的 `window` 有两点本质区别：
    ///   1. 它**不会被重解** —— 切出去就出栈，所以长度有界（≤ vadMaxSpeechSeconds）
    ///   2. 它有明确的起点 `tailStartSample`，因此时间轴由**累计样本数**推出，
    ///      不依赖"当前喂了多少"减去"窗口长度"这类推算（那种算法会随裁剪漂移）
    ///
    /// 内存量级：12 秒 × 16000 × 4 字节 ≈ 768 KB，远小于原先 15 秒常驻窗口。
    private var tail: [Float] = []
    /// `tail[0]` 在整个会话样本流中的下标（用于把识别结果映射回会话时间轴）
    private var tailStartSample = 0
    private var engine: SenseVoiceEngine?
    private var timer: DispatchSourceTimer?
    private var display: [TranscriptSegment] = []
    /// 本场会话已产出的段序号起点（识别段 + 音乐段共同计数）。
    /// 实时稿 id 里的序号部分由它保证「本场会话内唯一」；切语言重启时门面把
    /// 重启前的累计段数传进来，避免新段 id 回到 0 与重启前碰撞
    ///（那会让 publish 的按 id 去重把新句静默丢弃）。
    private var segmentSeqBase = 0
    private var modelURL: URL?
    private var language = "auto"
    private var didFailLoading = false

    /// 已**锁定**的语言（仅当设置为"自动判定"时使用）。
    ///
    /// SenseVoice 的语言在引擎创建时已固定（auto 或具体语言），识别时不能再改，
    /// 因此这个"锁定"**不再回传引擎** —— 它现在只做两件事：显示在界面（语言胶囊）、
    /// 作为实时翻译的源语言（见 pinLanguageIfNeeded 的 onLanguagePinned 回调）。
    private var pinnedLanguage: String?

    /// 语言投票箱（仅 auto 模式）。
    ///
    /// ## 为什么不再"第一段定生死"
    /// 原实现是**第一个出字段**判完就锁定、永不更正。而第一个出字段恰恰是最短的
    ///（静音边界切出的首句常只有 1~3 秒），而 SenseVoice 的语言识别（LID）在短音频上
    /// 方差极大；真机证据是普通话被稳定判成 `yue`，然后整场都显示粤语。
    /// 改为投票后，单个错判只会是一票，不会决定全场。
    private var languageVotes: [String: Int] = [:]
    /// 参与投票的音频总长（毫秒）
    private var languageSampleMs = 0

    /// 单段音频短于该值时不参与投票：短段判定不可信，投票只会放大噪声。
    private static let languageMinSampleMs = 3_000
    /// 达到该票数即锁定
    private static let languageVotesToPin = 3
    /// 或累计音频达到该值也锁定（说话少、句子长的场景，等价于 15 秒证据）
    private static let languageSampleMsToPin = 15_000

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
    private var utteranceCount = 0
    /// 其中**推断**为"说话不停顿、到长度上限"被切开的段数。
    ///
    /// 判据是"VAD 吐段的那一刻是否仍在说话" —— 这是**推断，不是确证**：
    /// 若一个人在停顿的同一拍里又开了口，会被误计进来，所以它只会偏高一点点。
    /// 因此它是**参考指标**；真正可靠的信号是 `maxUtteranceAudioMs`
    ///（最大识别音频时长：它贴近 12 秒就意味着上限确实在频繁触发）。
    private var cappedUtteranceCount = 0
    private var droppedSilenceCount = 0
    /// 本场被判为音乐、未送 whisper 的段数（只在检测器可用时才可能 > 0）。
    private var musicSegmentsCount = 0
    private var producedSegments = 0
    private var totalCostMs = 0
    private var maxCostMs = 0
    private var totalAudioMs = 0
    /// 单次识别过的**最长**音频时长。
    /// 它贴近 `vadMaxSpeechSeconds`（12 秒）就说明"长度上限"在频繁触发，
    /// 该把上限调大 —— 这个信号是确证的，不受上面那个推断的口径影响。
    private var maxUtteranceAudioMs = 0
    /// 统计事件的计数（识别一段、或丢弃一次长静音，各算一次）
    private var statsEventCount = 0
    /// 入口处累计丢弃的帧数（见 `feed` 的说明）。> 0 说明定时器被节流过。
    private var totalEntryDroppedFrames = 0
    /// 待补进时间轴的入口丢弃帧数（**在消费 tail 时统一补**，理由见 tick 中的说明）
    private var entryDroppedPending = 0
    /// 首次出字的日志只记一次
    private var hasReportedFirstSegments = false
    /// "暂停期间不保留缓冲"的日志只记一次（每次暂停记一次，不每拍都记）
    private var hasReportedPauseDrop = false
    /// "喂了音频但 VAD 从未判出语音"的提醒只记一次
    private var hasReportedNoSpeechDetected = false
    /// "首个音乐标注"日志只记一次（每个音乐段都记会刷屏）
    private var hasReportedFirstMusic = false

    /// 每多少个事件汇总一行统计
    private static let statsEveryEvents = 10

    /// 清空实时统计。**开始与停止都调它** —— 两处各写一遍必然会在新增字段时漏掉一处。
    private func resetLiveStats() {
        utteranceCount = 0
        cappedUtteranceCount = 0
        droppedSilenceCount = 0
        producedSegments = 0
        totalCostMs = 0
        maxCostMs = 0
        totalAudioMs = 0
        maxUtteranceAudioMs = 0
        statsEventCount = 0
        totalEntryDroppedFrames = 0
        entryDroppedPending = 0
        musicSegmentsCount = 0
        hasReportedFirstSegments = false
        hasReportedPauseDrop = false
        hasReportedNoSpeechDetected = false
        hasReportedFirstMusic = false
    }

    /// 结果回调。**在本引擎队列上触发**，调用方需自行切回主线程。
    var onSegments: (([TranscriptSegment]) -> Void)?
    /// 状态回调（模型加载中 / 运行中 / 已暂停 / 失败）。同样在引擎队列上触发。
    var onStatus: ((String) -> Void)?

    /// 语言锁定回调（仅"自动判定"模式、且首次锁定成功时触发一次）。
    /// 同样在引擎队列上触发，调用方自行切回主线程。
    var onLanguagePinned: ((String) -> Void)?

    private init() {}

    // MARK: - 生命周期

    /// 开始实时字幕。可在录音开始时调用。
    /// - Parameters:
    ///   - denoiseEnabled: 是否先把窗口音频降噪再识别（M3）。
    ///     默认关 —— 降噪会引入失真伪影，可能反而更差（见 SherpaDenoiser）。
    ///   - segmentSeqBase: 本场会话已产出的段数。**切语言重启时传「重启前累计段数」**，
    ///     让新段 id 的序号部分继续递增、不回到 0 —— 否则新句 id 会与重启前早段
    ///     碰撞，被 publish 的按 id 去重静默丢弃（切语言后实时稿丢失的根因）。
    func start(
        modelURL: URL,
        language: String,
        denoiseEnabled: Bool = false,
        segmentSeqBase: Int = 0
    ) {
        lock.lock()
        pending.removeAll()
        pendingDroppedFrames = 0
        pausedFlag = false
        stopRequested = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.modelURL = modelURL
            self.language = language
            self.denoiseEnabled = denoiseEnabled
            // 每次开始都重新判定：上一次会话锁定的语言不该带到这一次
            self.pinnedLanguage = nil
            // 投票箱同理：跨会话累积会让旧会话的语言影响新会话
            self.languageVotes = [:]
            self.languageSampleMs = 0
            self.tail = []
            self.tailStartSample = 0
            self.display = []
            self.segmentSeqBase = segmentSeqBase
            self.didFailLoading = false
            self.resetLiveStats()
            self.prepareHelpersIfNeeded()
            // VAD 是**流式**的：上一场会话残留的静音判定状态必须清掉，
            // 否则新会话的第一个切点会受上一场尾部影响
            //（与"语言锁定要重来"同一个道理：状态不跨会话）。
            self.vad?.reset()

            guard self.engine == nil else {
                self.startTimer()
                self.onStatus?(self.runningStatusText)
                return
            }

            self.onStatus?("正在加载实时字幕模型…")
            // SenseVoice 需要两个文件：tokens（随包内置）+ 模型（运行时下载）。
            // 任一缺失都算加载失败；失败后 didFailLoading 会让 tick 持续裁剪 tail、不攒内存。
            if let tokensURL = SenseVoiceModel.bundledTokensURL,
               let engine = SenseVoiceEngine(
                   modelPath: modelURL.path,
                   tokensPath: tokensURL.path,
                   language: language
               ) {
                self.engine = engine
                self.startTimer()
                self.onStatus?(self.runningStatusText)
            } else {
                self.didFailLoading = true
                self.onStatus?("实时字幕模型加载失败（模型未下载或内置 tokens 缺失）")
                Log.shared.error(.asr, "实时字幕模型加载失败（模型未下载或内置 tokens 缺失）")
            }
        }
    }

    /// 状态文案要把「实际生效的能力」写出来。
    /// 用户开了降噪却发现没效果、或 VAD 模型缺失导致行为变化，
    /// 都应该能从界面上看出来，而不是靠猜。
    private var runningStatusText: String {
        var parts = ["实时字幕已启动"]
        if vad != nil {
            // 把切窗参数写出来：出字节奏完全由它决定，
            // 真机上"出字慢"时要能一眼看到是哪个参数在起作用，而不是只能猜。
            parts.append("VAD 切窗（停顿 \(vadMinSilenceSeconds)s / 单段上限 \(vadMaxSpeechSeconds)s）")
        } else {
            parts.append("固定切窗（VAD 不可用）")
        }
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
                // 实时路径的两个参数与终稿不同（终稿用默认值，只做"这段有没有人声"）：
                //   · minSilence → 切点灵敏度（停顿多久算句尾）
                //   · maxSpeech  → 单段长度上限，**也就是最坏情况下一个字都不出的时长**
                // 理由见文件顶部的可调参数说明。
                vad = SherpaVad(
                    modelPath: vadURL.path,
                    minSilenceSeconds: vadMinSilenceSeconds,
                    maxSpeechSeconds: Float(vadMaxSpeechSeconds)
                )
                if vad == nil {
                    Log.shared.warn(.asr, "VAD 模型加载失败，回退到固定切窗 + 能量门限")
                }
            } else {
                Log.shared.warn(.asr, "未找到内置 VAD 模型，回退到固定切窗 + 能量门限")
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

    // 原先这里有一个 `windowContainsSpeech`（用 VAD 回答"这段要不要跳过"），
    // **已删除** —— 因为 VAD 的用法变了：从"是/否的门"变成"切点"。
    //
    // 它现在持续接收音频（见 tick），在句尾吐出**完整语音段**，切窗由它决定。
    // 静音因此不再需要"判定后跳过"：静音根本不会被切出来送去识别。
    //
    // 注意：**不能**再用 `vad.containsSpeech(in:)` 来做任何事 —— 它内部有 reset()，
    // 每调一次都会把流式状态清掉，于是永远判不出句尾（这是本次改动最关键的一处坑）。

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
        pendingDroppedFrames = 0
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.engine?.close()
            self.engine = nil
            // M3 的两个模型也要显式释放：它们各自持有 ONNX 会话，
            // 不释放会一直占内存（本项目的会话可能连续录 8 小时，内存必须能回收）
            self.vad?.close()
            self.vad = nil
            self.denoiser?.close()
            self.denoiser = nil
            self.didAttemptLoadingHelpers = false
            self.hasReportedDenoiseFailure = false
            // 停止时把**尚未识别**的尾部如实报出来：这段音频不会出现在实时字幕里
            //（它会被终稿覆盖）。不说的话，用户看到"最后一句没出来"会以为是丢了录音 ——
            // 而实际上音频一直在盘上，只是还没到句子边界。
            let undecodedMs = self.tail.count * 1000 / self.sampleRate
            if undecodedMs > 0 {
                Log.shared.info(
                    .asr,
                    "实时字幕停止｜未识别的尾部 \(undecodedMs)ms（不足一个句子边界，将由终稿覆盖）"
                )
            }
            self.tail = []
            self.tailStartSample = 0
            self.display = []
            // 强制输出一次汇总再清零：否则最后不足一批的统计永远看不到
            self.logLiveStats()
            self.resetLiveStats()
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

        // **在入口处就封顶**。理由：`pending` 的消费完全依赖那个 250 毫秒定时器，
        // 而"后台状态下定时器是否照常触发"在本项目里**仍是未验证项**（概念文档 P22）。
        // 若它被系统节流，`pending` 会一路涨：按 16 kHz Float32 算约 115 MB/小时，
        // 8 小时接近 1 GB —— 录音本身是好的，却会因为实时字幕这一侧而 OOM。
        //
        // 丢掉的是**实时字幕的原料**，而音频一直在盘上、终稿不受影响，
        // 所以这里的降级是安全的：宁可字幕落后，不可整机被杀。
        // 丢弃量会被计入统计并在日志里显式报出来（见 tick 与 logLiveStats）——
        // 否则它会变成一个"字幕莫名其妙不跟了"的无头悬案。
        let limit = pendingLimitSeconds * sampleRate
        if pending.count > limit {
            let dropped = pending.count - limit
            pending.removeFirst(dropped)
            pendingDroppedFrames += dropped
        }
        lock.unlock()
    }

    // MARK: - 定时驱动

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        // 250 毫秒一拍，而不是 1 秒 —— **切点精度就取决于这个间隔**。
        // VAD 判定"这句说完了"之后，我们要等到下一拍才切；间隔若是 1 秒，
        // 快速对话里"上一句刚停、下一句已经开始"的那部分就会被切进上一段，
        // 于是下一段从半个词开始。
        // 缩短间隔**不会增加识别次数**（只有切窗才识别），VAD 的 accept 也很便宜。
        source.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .milliseconds(250),
            leeway: .milliseconds(50)
        )
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

    /// 切窗原因。**用枚举而不是字符串比较** —— 字符串比较在改文案时会静默失效
    /// （比错了不报错，只是统计从此永远是 0）。
    private enum CutReason {
        /// VAD 判定"停顿够长、这句说完了" —— 最常见的切点
        case silenceBoundary
        /// 说话一直不停顿，到长度上限被切开
        case lengthCap
        /// VAD 不可用时的固定长度切窗（退回 M2 行为）
        case fallbackFixed

        var text: String {
            switch self {
            case .silenceBoundary: return "静音边界"
            case .lengthCap: return "长度上限"
            case .fallbackFixed: return "兜底固定切（VAD 不可用）"
            }
        }

        var isSilenceBoundary: Bool { self == .silenceBoundary }
    }

    private func tick() {
        lock.lock()
        let incoming = pending
        pending.removeAll(keepingCapacity: true)
        let droppedAtEntry = pendingDroppedFrames
        pendingDroppedFrames = 0
        let paused = pausedFlag
        let stopped = stopRequested
        lock.unlock()

        // 入口丢掉的帧要计入时间轴，但**绝不能立刻加**：它们一定排在当前 tail **之后**
        //（上一次 tick 已把 pending 取空，所以 pending 里的都是更新的音频）。
        // 立刻加会把当前 tail 的起点一起推后 —— 那一段的时间戳就全错了，
        // 而时间戳是"点句回听"的定位依据。
        // 正确做法：累积起来，**到消费 tail 时一次性补上**（见下面的出栈处）。
        if droppedAtEntry > 0 {
            entryDroppedPending += droppedAtEntry
            totalEntryDroppedFrames += droppedAtEntry
        }

        // 1) 新音频并入 tail，并**持续喂给 VAD**。
        //    必须持续喂：VAD 是流式的，靠连续接收才能判定"停顿够了、这句说完了"。
        //    这也是本次改动的关键 —— 换成句子边界切点，而不是固定时长。
        var finishedVADSegments = 0
        var speaking = false
        if !incoming.isEmpty {
            tail.append(contentsOf: incoming)
            if let vad {
                finishedVADSegments = vad.accept(incoming).count
            }
        }
        // **`speaking` 必须在 `if` 外面查**：它是 VAD 的当前流式状态，
        // 与"这一拍有没有新音频"无关。若只在有新音频时才查，那么某一拍恰好
        // 没收到音频时 `speaking` 会默认成 false，于是下面的"长时间静音"分支
        // 会把**正在说的那句话**当成静音丢掉（真会丢掉几十秒已说的话）。
        if let vad {
            speaking = vad.isSpeechDetected
        }

        guard !stopped else { return }

        // 引擎不可用（模型加载失败、或尚未就绪）时**同样必须裁剪 tail**。
        // 这与下面的"暂停"分支是同一类问题：`tail` 只增不减，而消费它的识别
        // 在这条路径上永远不会发生。模型加载失败后若不裁剪，8 小时录音会一路攒到
        // GB 级然后被系统杀掉 —— 而日志里只看得到"模型加载失败"，
        // 真正的死因（内存）根本不会出现，属于最难查的那种。
        guard !didFailLoading, let engine else {
            _ = dropLeadingSilence()
            return
        }

        // 暂停期间（终稿转写在跑）不识别，但**必须继续裁剪 tail**。
        // 原先的滑窗会顺手把窗口裁到 15 秒，这个兜底在改用 tail 之后就没了 ——
        // 不补这一条，暂停几分钟就攒下几分钟音频，8 小时会到 GB 级。
        // 丢掉它是安全的：音频一直在盘上，暂停的那一段由终稿覆盖。
        if paused {
            if !hasReportedPauseDrop {
                hasReportedPauseDrop = true
                Log.shared.info(
                    .asr,
                    "实时字幕暂停中｜不保留识别缓冲（避免攒内存）｜暂停期间的音频由终稿覆盖"
                )
            }
            _ = dropLeadingSilence()
            return
        }
        hasReportedPauseDrop = false

        // VAD 一旦判定不出语音，实时字幕会**一个字都不出**。
        // 这是本次改动的代价之一（旧版至少会输出幻觉文本，看上去"在动"），
        // 所以必须有一个"我什么都没听到"的一次性提醒 —— 否则用户面对空白界面只能猜。
        // 判据用**累计喂入时长**（tailStartSample + tail 就是全部喂入的音频，
        // 裁剪不会让它失真），而不是墙钟：暂停与静音丢弃都不影响它的正确性。
        let fedMs = (tailStartSample + tail.count + entryDroppedPending) * 1000 / sampleRate
        if utteranceCount == 0, !hasReportedNoSpeechDetected, fedMs >= 120_000 {
            hasReportedNoSpeechDetected = true
            Log.shared.warn(
                .asr,
                "实时字幕｜已喂入 \(fedMs / 1000) 秒音频，但 VAD 一次都没判定出语音 ——"
                    + "若你确实在说话，可能是输入电平过低或麦克风不合适"
                    + "（可对照：录音本身是否正常）"
            )
        }

        // 2) 判定"现在该切了吗"。切点只有两个来源：VAD 给的句子边界，
        //    或长度上限兜底（为"说话一直不停顿"准备）。
        var cutReason: CutReason?
        if vad != nil {
            if finishedVADSegments > 0 {
                // VAD 吐出了一段完整语音，其边界由两件事之一决定：
                //   · 停顿 ≥ vadMinSilenceSeconds  → 正常句尾
                //   · 说话超过 vadMaxSpeechSeconds → 长度上限强切
                // 两者都适合当切点。下面这句只是**为日志推断**原因，不影响行为：
                // 还在说话 ⇒ 是长度上限切的。
                cutReason = speaking ? .lengthCap : .silenceBoundary
            } else if speaking, tail.count >= vadMaxSpeechSeconds * sampleRate {
                // 兜底：VAD 因故没吐段（例如句尾停顿一直不够），但音频已到上限。
                // **不能无限攒** —— 内存与延迟都会失控。
                cutReason = .lengthCap
            } else if !incoming.isEmpty, !speaking, tail.count > prerollFrames {
                // 长时间没人说话：不切、不识别，只保留一点前导音频。
                // 这一条必须有：否则纯静音也会把 tail 撑到上限，
                // 白让 whisper 跑一遍（还容易编出幻觉文本）。
                //
                // 条件的 `!incoming.isEmpty` 不能省：没有新音频时 tail 也不会变长，
                // 这里就无事可做；而少了它，上面 `speaking` 判断一旦失效就会误丢音频。
                noteDroppedSilence(dropLeadingSilence())
            }
        } else if !incoming.isEmpty, tail.count >= fallbackCutSeconds * sampleRate {
            // VAD 缺失：退回 M2 的行为 —— 固定长度切 + 能量门限挡静音。
            // 注意能量门限分不清"人声"与"稳定噪声"，所以这只是降级路径。
            if TranscriptMath.hasSpeech(tail) {
                cutReason = .fallbackFixed
            } else {
                noteDroppedSilence(dropLeadingSilence())
            }
        }

        guard let reason = cutReason else { return }

        // 太短不识别：whisper 对极短输入的判定最不可信（且易出幻觉）。
        // **刻意不清空 tail** —— 让这几百毫秒并进下一句；丢掉它等于丢掉一个词。
        guard tail.count >= minimumSeconds * sampleRate else { return }

        // 3) 识别这一段。
        let audioMs = tail.count * 1000 / sampleRate
        // 时间轴起点由**累计样本数**推出，不由"喂了多少减去窗口长度"推算 ——
        // 后者会随裁剪产生漂移（与分片时间轴的取舍一致）。
        let startMs = tailStartSample * 1000 / sampleRate

        // 降噪在这里临时施加（原始音频始终没有被动过）
        let audio = maybeDenoise(tail)

        // 计时用**单调时钟**而不是墙钟：耗时是性能指标，
        // 系统对时会让墙钟跳变，而单调时钟不会（与看门狗同一取舍）
        let started = ProcessInfo.processInfo.systemUptime
        // SenseVoice 的语言在引擎创建时已固定（auto 或具体语言），识别时不再传；
        // auto 模式下每段独立判语言、结果由 recognition.language 给出（见 pinLanguageIfNeeded）。
        let recognition = engine.transcribe(audio)

        // 音乐事件（SenseVoice 内建，替代原 CED 独立检测）：这段被判为音乐/背景音乐、
        // 且没有听出任何话时，标注「（音乐）」、不产出文本 —— 音乐幻觉从源头消失。
        // 有语音内容时以语音为准（即使同时有背景音乐）。
        if recognition.isMusic && recognition.segments.isEmpty {
            appendMusicSegment(startMs: startMs, audioMs: audioMs)
            finishSegment()
            return
        }

        let local = recognition.segments
        // **只在真的出了字之后才锁定**：对一段"VAD 认为有人声、但一个词都没听出来"
        // 的音频给出的语言判定，可信度最低，而锁定是一次性的（见 pinLanguageIfNeeded）。
        if !local.isEmpty {
            pinLanguageIfNeeded(afterDetecting: recognition.language, audioMs: audioMs)
        }
        let costMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)

        utteranceCount += 1
        if !reason.isSilenceBoundary { cappedUtteranceCount += 1 }
        producedSegments += local.count
        totalCostMs += costMs
        maxCostMs = max(maxCostMs, costMs)
        totalAudioMs += audioMs
        maxUtteranceAudioMs = max(maxUtteranceAudioMs, audioMs)

        // 首次出字必须记一次：出字变慢是本改动最可能被误读成故障的地方，
        // 所以把"这段音频多长、因为什么切的、花了多久"写清楚。
        if !hasReportedFirstSegments {
            hasReportedFirstSegments = true
            Log.shared.info(
                .asr,
                "实时字幕首个识别段｜音频 \(audioMs)ms｜切窗原因 \(reason.text)"
                    + "｜耗时 \(costMs)ms｜出句 \(local.count)｜时间轴起点 \(startMs)ms"
            )
        }

        // 这一段音频到此为止**不再重算**，因此一律定稿（isProvisional = false）。
        // 行为变化就体现在这一行：不再是"窗口内重写、窗口外冻结"。
        let mapped = TranscriptMath.mapToSessionTimeline(
            local: local,
            sessionStartMs: startMs,
            seqBase: segmentSeqBase,
            isProvisional: false
        )
        // 推进段序号：本场会话内 id 的序号部分单调递增，切语言重启也不回到 0
        segmentSeqBase += local.count
        assemble(newSegments: mapped)
        finishSegment()
    }

    /// 丢掉 tail 开头的长静音，只留下 `prerollSeconds` 作为下一句的前导。
    /// - Returns: 丢掉的帧数（调用方据此决定是否值得计数）
    private func dropLeadingSilence() -> Int {
        let dropped = max(0, tail.count - prerollFrames)
        guard dropped > 0 else { return 0 }
        tail.removeFirst(dropped)
        tailStartSample += dropped
        return dropped
    }

    /// 已处理音频出栈 + 触发统计。音乐段与识别段共用（见 tick），
    /// 避免两条路径各自写一遍出栈逻辑、日后新增字段时漏改一处。
    private func finishSegment() {
        // 入口丢弃的帧在这里一并补进时间轴：它们排在刚消费掉的这段**之后**、
        // 下一段**之前**，补在这里正好对齐（补早了会把这一段本身推后）。
        tailStartSample += tail.count + entryDroppedPending
        entryDroppedPending = 0
        tail.removeAll(keepingCapacity: true)
        reportLiveStatsIfNeeded()
    }

    /// 产出一个「（音乐）」标注段，**不送识别引擎**。
    ///
    /// 为什么是"标注段"而不是"直接跳过"：音乐不是没有内容 —— 它占据了一段
    /// 时间轴。产出「（音乐）」后，字幕与留档都能如实反映"这段时间是音乐"，
    /// 用户回听时也知道这里发生了什么；若直接跳过，屏幕上就是一段空白，
    /// 看起来像识别坏了。
    private func appendMusicSegment(startMs: Int, audioMs: Int) {
        musicSegmentsCount += 1
        if !hasReportedFirstMusic {
            hasReportedFirstMusic = true
            Log.shared.info(
                .asr,
                "实时字幕首个音乐标注｜音频 \(audioMs)ms｜时间轴起点 \(startMs)ms"
                    + "（SenseVoice 事件判定为音乐，跳过识别，避免幻觉文本）"
            )
        }
        // id 用 "music-" 前缀 + 本场段序号：与识别段 "seg-" 前缀错开，且序号部分
        // 也随 segmentSeqBase 递增 —— 切语言重启后新音乐段 id 不回到 0 碰撞
        //（与识别段同一条规则，见 start 的 segmentSeqBase 说明）。
        let segment = TranscriptSegment(
            id: TranscriptSegment.musicMarkerIDPrefix + "\(segmentSeqBase)-\(startMs)",
            seq: display.count,
            startMs: startMs,
            endMs: startMs + audioMs,
            text: "（音乐）",
            speakerId: nil,
            isProvisional: false
        )
        segmentSeqBase += 1
        display.append(segment)
        onSegments?(display)
    }

    /// 静音丢弃的计数：只在**丢掉 1 秒以上**时才算一次事件。
    /// 否则 250 毫秒一拍的 tick 会让"丢了 5 分钟静音"变成上千次事件，把统计冲垮。
    private func noteDroppedSilence(_ droppedFrames: Int) {
        guard droppedFrames >= sampleRate else { return }
        droppedSilenceCount += 1
        reportLiveStatsIfNeeded()
    }

    /// 语言投票：累计足够证据后再锁定（语言胶囊显示 + 实时翻译源语言）。
    ///
    /// ## 与旧实现的差别（为什么要改）
    /// 旧实现"第一个出字段判完即锁"，而首段往往只有 1~3 秒。SenseVoice 的 LID
    /// 在短音频上极不稳定，中文普通话被稳定判成 `yue`，接着整场都显示粤语 ——
    /// 用户看到的是"总是识别成粤语"，根因就是**只采样一次且永不更正**。
    ///
    /// 现规则：
    ///   · 只采信 ≥ 3 秒且真出了字的段（短段不投票）；
    ///   · 累计 3 票、或累计 15 秒音频后开票；
    ///   · 平票时**优先中文**：zh 与 yue 是模型最容易混淆的一对，
    ///     在中文优先的产品里把平票判给 zh 比随机更合理。
    private func pinLanguageIfNeeded(afterDetecting detected: String?, audioMs: Int) {
        guard language == "auto", pinnedLanguage == nil, let detected else { return }

        // 短段判定不可信，直接跳过（但仍记录，便于判断"为什么一直没锁定"）
        guard audioMs >= Self.languageMinSampleMs else {
            Log.shared.info(
                .asr,
                "语言投票跳过｜本段 \(audioMs)ms 短于 \(Self.languageMinSampleMs)ms｜检测 \(detected)"
            )
            return
        }

        languageVotes[detected, default: 0] += 1
        languageSampleMs += audioMs

        let totalVotes = languageVotes.values.reduce(0, +)
        let summary = languageVotes
            .sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        guard totalVotes >= Self.languageVotesToPin || languageSampleMs >= Self.languageSampleMsToPin else {
            Log.shared.info(
                .asr,
                "语言投票｜本段 \(detected)（\(audioMs)ms）｜当前 \(summary)"
                    + "｜累计 \(languageSampleMs)ms"
            )
            return
        }

        // 平票优先中文：zh / yue 是模型最易混淆的一对，把平票判给 zh 比随机更稳
        let top = languageVotes.values.max() ?? 0
        let tied = languageVotes.filter { $0.value == top }.map { $0.key }
        let winner = tied.contains("zh") ? "zh" : (tied.first ?? detected)

        pinnedLanguage = winner
        Log.shared.info(
            .asr,
            "实时字幕锁定语言｜\(winner)｜票数 \(summary)"
                + "｜样本 \(totalVotes) 段/\(languageSampleMs)ms"
        )
        onLanguagePinned?(winner)
    }

    /// 每 N 个事件汇总一行实时统计（含**实时倍率**）。
    ///
    /// 实时倍率 = 平均识别耗时 ÷ 平均**被识别的音频时长**。
    ///
    /// 判据从"窗口音频"换成了"实际识别的音频"：现在每次识别的长度是可变的
    /// （由句子边界决定），固定窗口长度已经不存在 —— 拿一个不存在的量做分母，
    /// 会得到一个看起来合理、实际无意义的数字。
    ///
    /// **≥ 1.0 就意味着识别慢于采集**，表现为字幕越落越远。这是概念文档 P23
    /// 的那项数据，也是判断"实时字幕在这台设备上到底可不可行"的唯一依据。
    private func reportLiveStatsIfNeeded() {
        statsEventCount += 1
        guard statsEventCount % Self.statsEveryEvents == 0 else { return }
        logLiveStats()
    }

    /// 输出一行实时统计。**停止时会强制调一次** ——
    /// 否则最后不足一批（最多 9 个事件）的数字永远不会出现，
    /// 而"停止前那几分钟字幕跟不跟得上"恰恰是最该看的数据。
    private func logLiveStats() {
        let avgCost = utteranceCount > 0 ? totalCostMs / utteranceCount : 0
        let avgAudioMs = utteranceCount > 0 ? totalAudioMs / utteranceCount : 0
        let ratio = avgAudioMs > 0 ? Double(avgCost) / Double(avgAudioMs) : 0

        var summary = "实时字幕统计｜识别段 \(utteranceCount) 个"
            + "（其中切于长度上限 \(cappedUtteranceCount) 个）"
            + "｜音乐标注 \(musicSegmentsCount) 段"
            + "｜丢弃长静音 \(droppedSilenceCount) 次"
            + "｜平均音频 \(avgAudioMs)ms｜最长音频 \(maxUtteranceAudioMs)ms"
            + "（上限 \(vadMaxSpeechSeconds * 1000)ms）"
            + "｜平均耗时 \(avgCost)ms｜最慢 \(maxCostMs)ms"
            + "｜实时倍率 \(String(format: "%.2f", ratio))｜累计出句 \(producedSegments)"

        // 入口丢弃只在真的发生时出现，并给出**原因方向**：
        // 它意味着定时器没能按 250 毫秒消费，属于 P22（后台定时器是否正常）那一类问题。
        // 不报的话，它会表现成"字幕莫名其妙漏了几段"，而日志里毫无线索。
        let entryDroppedSeconds = totalEntryDroppedFrames / sampleRate
        if entryDroppedSeconds > 0 {
            summary += "｜⚠️ 入口丢弃 \(entryDroppedSeconds) 秒"
                + "（定时器未能及时消费，实时字幕会漏内容；音频本身不受影响）"
        }

        if utteranceCount > 0, ratio >= 1.0 {
            summary += "｜【倍率 ≥ 1.0：识别慢于采集，字幕会越落越远】"
            Log.shared.warn(.asr, summary)
        } else {
            Log.shared.info(.asr, summary)
        }
    }

    /// 组装显示列表：**成句即定稿**，并做一次合并与一道"同批内"重复守卫。
    ///
    /// ## 与上一版的关系（2026-09-24 切窗方式改变后）
    /// 上一版这里是"窗口内重写、窗口外冻结"，两道守卫都是为了补**滑窗重解**造成的
    /// 重复与碎片（同一段音频被解 3 次，两次的分段边界还不一样）。
    /// 现在每段音频**只解一次**，那类重复的根源已经消失 —— 因此两道守卫
    /// 都按"根源已消失"重新审视过，结果是一删一改：
    ///
    ///   · **时间重叠过滤：已删除**。它原本用来挡"新窗口重解出的旧内容"，
    ///     而现在新片段永远不会与已显示的片段重叠（解码区间互不相交）。
    ///     留着它只会有害：一旦 whisper 给的最后一段时戳略微超出音频长度
    ///     （`endMs > boundary`），那一段就会被判为"落在已定稿范围内"而丢掉 ——
    ///     表现为**文字凭空消失**。用"可能丢字"去防一个已不存在的问题，是坏买卖。
    ///   · **文本相同的重复：保留，但只比较同一批内**。
    ///     跨批比较会在真人**停顿后复述同一句**时吃掉一遍（"好的。"…"好的。"），
    ///     而那是正常的说话方式。同一批内的相邻重复才几乎必然是 whisper 的复读。
    ///   · **极短片段合并：保留**。"三个字占一行"来自模型的分段粒度，
    ///     与切窗方式无关，不会因为换了切窗就消失。
    private func assemble(newSegments: [TranscriptSegment]) {
        var kept: [TranscriptSegment] = []
        var droppedDuplicate = 0
        for segment in newSegments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // **只与同一批内的上一段比较，不跨批**（理由见函数说明）
            let previousText = kept.last?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if previousText == text {
                droppedDuplicate += 1
                continue
            }

            // 合并极短且紧邻的片段：这是"三个字占一行"的来源。
            // **只在本次识别结果内部合并，不跨到已显示的内容** ——
            // 跨过去就改到了"已经给用户看过"的文字（成句即定稿是本功能对用户的承诺）。
            if let last = kept.last, Self.shouldMerge(last, segment) {
                var merged = last
                merged.text += segment.text          // 中文之间不加空格
                merged.endMs = segment.endMs
                kept[kept.count - 1] = merged
                continue
            }

            kept.append(segment)
        }

        if droppedDuplicate > 0 {
            Log.shared.info(.asr, "实时拼接｜丢弃 \(droppedDuplicate) 个重复片段（同一次识别内的复读）")
        }

        // 重新编号，保证顺序稳定（界面用 seq 排序，而不是依赖时间戳相等性）
        display = (display + kept).enumerated().map { index, segment in
            var copy = segment
            copy.seq = index
            return copy
        }

        onSegments?(display)
    }

    /// 是否把 `next` 并进 `previous`。**刻意保守**：三个条件同时满足才并。
    ///
    ///   1. 上一段很短（< 10 字）—— 长句本来就不该并
    ///   2. 两段挨得很近（间隔 < 300ms）—— 隔得远说明是两句独立的话
    ///   3. 上一段结尾没有句末标点 —— 有标点说明它自己就是一句完整的话
    ///
    /// 合并后取两者的时间跨度，因此"点句回听"仍然定得到位置。
    private static func shouldMerge(_ previous: TranscriptSegment, _ next: TranscriptSegment) -> Bool {
        let gap = next.startMs - previous.endMs
        return previous.text.count < 10
            && gap >= 0 && gap < 300
            && !endsWithSentencePunctuation(previous.text)
    }

    private static func endsWithSentencePunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "。！？!?…".contains(last)
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
    /// "自动判定"模式下已被锁定的语言（空表示尚未锁定，或本来就不是自动判定）。
    ///
    /// **必须在界面上显示出来**：锁错了若看不见，用户只会觉得"识别结果很扯"，
    /// 而不会想到"把它改成中文就好了"。看得见才可能被纠正。
    @Published private(set) var pinnedLanguage = ""

    /// 上一场会话一共出了多少句实时字幕。
    ///
    /// **为什么必须单独留一个数字**：`segments` 在 `stop()` 时会被清空，
    /// 而界面要在停止之后告诉用户"识别了 N 句、已保存" ——
    /// 直接读 `segments.count` 会在停止那一刻变成 0，看起来像什么都没留下。
    @Published private(set) var lastSessionSegmentCount = 0

    // MARK: - 落盘所需的会话信息
    //
    // 这三项都由调用方（录音页）在 start 时给出：本类不知道自己在给哪一次录音出字幕，
    // 而落盘必须写进 `Audio/{sessionId}/transcript-live.json`。

    /// 本次实时字幕所属的会话 id
    private var sessionId: String?
    /// 实际使用的模型 id 与识别语言（写进实时稿元信息，供事后判断"这份稿是怎么来的"）
    private var modelId = ""
    private var usedLanguage = "auto"
    /// 本场会话中途是否改过识别语言。
    ///
    /// **必须显式记下来**：改过之后 `usedLanguage` 只剩"最后一次"的值，
    /// 而留档里其实是多种语言设置生成的内容混在一起 ——
    /// 不写这一句，后人（或下一版实现）会以为整份稿都出自同一个语言设置。
    private var didSwitchLanguage = false

    /// 本场会话**累计**的实时句（跨引擎重启累加）。
    ///
    /// 与 `segments` 的区别必须分清，两者缺一不可：
    ///   · `segments` 是**当前这次引擎运行**的显示内容 —— 切换识别语言会重启引擎、
    ///     它被清空重来（这是既有行为，界面侧就是"切了就重新开始显示"）；
    ///   · 本数组是**整场会话**的累计，只用于落盘留档 ——
    ///     因为切过一次语言就把之前识别的内容从留档里抹掉，是不能接受的。
    private var accumulated: [TranscriptSegment] = []

    private init() {
        let engine = LiveTranscriptionEngine.shared
        engine.onSegments = { [weak self] segments in
            Task { @MainActor in self?.publish(segments) }
        }
        engine.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.statusText = status
                self?.isActive = !status.contains("停止") && !status.contains("失败")
            }
        }
        engine.onLanguagePinned = { [weak self] language in
            Task { @MainActor in self?.pinnedLanguage = language }
        }
    }

    /// 更新界面显示，并把这批句子并进"本场会话累计"（落盘用）。
    ///
    /// 累计方式为**按 id 去重后追加**，而不是整体替换：引擎每次给的是
    /// "当前这次运行的全部句子"，切语言重启后它从空开始 ——
    /// 整体替换会把切换之前的内容从留档里抹掉。
    private func publish(_ display: [TranscriptSegment]) {
        segments = display

        var known = Set(accumulated.map { $0.id })
        for segment in display where !known.contains(segment.id) {
            accumulated.append(segment)
            known.insert(segment.id)
        }
    }

    /// LLM 纠错结果回写（由 `CorrectionService` 在纠正完成后调用，主线程）。
    ///
    /// 同时更新显示列表与落盘累计：
    ///   · `segments` 用整体重建赋值，触发 `@Published` 通知，界面立刻刷新为纠正文本；
    ///   · `accumulated` 下标更新，保证 `persistLiveTranscript()` 落盘时带上 `correctedText`
    ///     —— 原文 `text` 始终保留，与纠正文本并存供复盘对照（用户 2026-10-17 确认）。
    func applyCorrection(id: String, correctedText: String) {
        segments = segments.map { segment in
            guard segment.id == id else { return segment }
            var copy = segment
            copy.correctedText = correctedText
            return copy
        }
        if let index = accumulated.firstIndex(where: { $0.id == id }) {
            accumulated[index].correctedText = correctedText
        }
    }

    /// 开始实时字幕。需要调用方（录音页）先确认模型已下载。
    /// - Parameters:
    ///   - sessionId: 本次录音的会话 id。停止时据此把实时稿落盘。
    func start(
        sessionId: String,
        modelURL: URL,
        language: String,
        denoiseEnabled: Bool = false
    ) {
        // 换会话就清空累计；**同一会话内因切语言而重启时要保留** ——
        // 这正是"切识别语言不该丢掉已识别内容"的落点。
        let isSameSession = self.sessionId == sessionId
        if isSameSession {
            // 同一场会话再次 start ⇒ 用户在录音中改了识别语言（见 restartLiveTranscription）
            didSwitchLanguage = true
        } else {
            accumulated = []
            didSwitchLanguage = false
        }
        self.sessionId = sessionId
        self.modelId = SenseVoiceModel.id
        self.usedLanguage = language

        segments = []
        // 上一次会话锁定的语言不该带到这一次（换个语言/重开录音都要重判）
        pinnedLanguage = ""
        statusText = "正在启动…"
        // 段序号偏移：同一场会话切语言重启时，把「重启前累计段数」传给引擎，
        // 让新段 id 的序号部分继续递增 —— 否则新句 id 与重启前早段碰撞、
        // 被 publish 按 id 去重静默丢弃（切语言后实时稿丢失的根因）。
        LiveTranscriptionEngine.shared.start(
            modelURL: modelURL,
            language: language,
            denoiseEnabled: denoiseEnabled,
            segmentSeqBase: isSameSession ? accumulated.count : 0
        )
    }

    func stop() {
        // **先落盘再清空**，这两步的顺序不能反：清完 `segments` 与累计之后，
        // 整场会话的识别结果就没有任何地方留存了（这正是本次要修的缺口）。
        persistLiveTranscript()
        lastSessionSegmentCount = accumulated.count
        LiveTranscriptionEngine.shared.stop()
        segments = []
        isActive = false
    }

    /// 把本场会话的实时稿落盘（`transcript-live.json`，`pass: .live`）。
    ///
    /// ## 为什么必须有这一步（这是一个功能缺口，不是增强）
    /// 在此之前实时字幕只活在内存里：`stop()` 一清 `segments`，整场录音的识别结果
    /// 就没有任何地方留存。用户停止录音后回到记录页，看到的是
    /// 「还没有文字稿，请先点『转写为文字』」—— 想拿回自己刚说过的话，
    /// 必须先花一次终稿模型的算力。而用户的预期是"结束时会自动保留识别内容"。
    ///
    /// 落 `pass: .live`，与终稿（`.final`）**分文件**存，两者互不覆盖：
    /// 事后在详情页仍可点「转写为文字」得到更准的一稿，两稿可对照
    ///（会话详情页本来就会"有终稿优先用终稿、否则用实时稿"）。
    ///
    /// - Note: 会话被系统强杀 / 崩溃的路径拿不到这里的内容（那需要周期性落盘，
    ///   属后续增强）。音频不受影响 —— 它一直是分片实时写盘的。
    private func persistLiveTranscript() {
        guard let sessionId, !accumulated.isEmpty else { return }

        // 顺序号重排：切识别语言会让引擎重启并从 0 重新编号，
        // 不重排的话留档里会出现两个 `#0`（同一场会话却有两段同号）。
        // `id` **不动** —— 它是译文的对应键（见 TranslationService 的 liveTranslations），
        // 改了会让已翻好的句子对不上原文。
        let segments = accumulated.enumerated().map { index, segment -> TranscriptSegment in
            var copy = segment
            copy.seq = index
            return copy
        }

        let document = TranscriptDocument(
            sessionId: sessionId,
            pass: .live,
            modelId: modelId,
            language: usedLanguage,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            isComplete: true,
            segments: segments,
            note: "录音过程中实时生成（停止录音时自动保存）；最准确的文本仍以终稿为准"
                + (didSwitchLanguage ? "。中途改过识别语言，本稿由多种语言设置生成，语言字段为最后一次的值" : "")
        )
        TranscriptStore.shared.saveAsync(document)
        Log.shared.info(
            .storage,
            "实时稿已落盘｜\(sessionId)｜\(segments.count) 句｜语言 \(usedLanguage)｜模型 \(modelId)"
        )
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        LiveTranscriptionEngine.shared.setPaused(paused)
    }

    /// 清空界面上的字幕（开始新会话时用）。
    /// 注意这里**不动引擎内部状态** —— 引擎的 tail 是"当前这一句"的载体，
    /// 清空它会让正在说的那句话从头断掉。
    func clearDisplay() {
        segments = []
    }

    var previewText: String {
        segments.suffix(3).map { $0.text }.joined(separator: " ")
    }
}
