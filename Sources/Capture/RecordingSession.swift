import AVFoundation
import Foundation

/// 录音会话：M1 的内核状态机（设计文档 4.7 – 4.13）。
///
/// ## 唯一权威
/// 所有状态变更**只经过 `setState`**，且只在主线程发生。UI 只作为观察者订阅 `snapshot`。
/// 既有项目曾因"回调线程直接改状态"出过线程安全问题，这里从结构上避免。
///
/// ## 失败不丢数据
/// 进入 failed 之前一定先把已录分片收尾。**已录到的音频永远不能因为状态机失败而丢失。**
///
/// ## 时间轴口径
/// 全部时间来自"实际写入的样本数"，中断则在恢复前把时间轴**前移**对应时长，
/// 使断口作为真实的空洞显现出来，而不是被静默掩盖（见 SegmentWriter.advanceTimeline）。
@MainActor
final class RecordingSession: ObservableObject {

    static let shared = RecordingSession()

    @Published private(set) var snapshot = CaptureSnapshot()

    private let engine = AudioCaptureEngine()
    private let ringBuffer = AudioRingBuffer()
    private let library = RecordingLibrary.shared
    private let audioSession = AudioSessionManager.shared
    private let settings = AppSettings.shared

    private var pipeline: CapturePipeline?
    private var manifest: SessionManifest?
    private var watchdog: CaptureWatchdog?

    /// 本次会话开始时环形缓冲的累计写入帧数。
    ///
    /// **必须有这个基准**：`ringBuffer` 是 `let` 属性、跨会话复用且计数只增不减
    ///（`AudioRingBuffer` 没有 reset，writeCount 一路单调上升）。
    /// 若直接拿 `totalWritten` 当"本次已录帧数"，第二次录音一开机就会
    /// 显示上一次录了多久 —— 而且这个错误会随使用次数越来越大。
    private var frameBaseAtSessionStart = 0

    /// 首帧探针：布防时刻（单调时钟）。nil 表示未布防。
    ///
    /// 存在的理由：`engine.start()` 成功只证明"引擎起来了"，**不证明 tap 真的在出数据**。
    /// 音频图被重建后旧引擎静默失效、麦克风被系统静音这类故障，所有回调都不触发，
    /// 日志里除了"采集引擎已启动"什么都没有 —— 这正是本项目最难查的一类问题。
    private var firstFrameArmUptime: Double?
    /// 首帧探针的帧数基准（布防那一刻的累计写入帧）。
    private var firstFrameBase = 0
    /// 是否已就首帧发过结论（"到达"或"无输出"都只报一次，避免每秒刷屏）。
    private var firstFrameReported = true
    /// 布防后多久必须见到帧
    private let firstFrameDeadlineSeconds: Double = 1.0

    /// 逻辑时间轴位置（毫秒）。它 = 最后一次收尾分片的 endMs + 已记录的断口时长。
    /// 用它而不是 `manifest.recordedMs` 来定位断口起点，是因为断口本身要占据时间轴位置。
    private var timelineMs = 0
    /// 中断开始时刻（单调时钟）。非 nil 表示当前处于中断中，断口尚未结算。
    private var outageStartUptime: Double?
    private var outageReason = ""
    private var recoveryAttempts = 0

    private init() {
        bindAudioEvents()
    }

    // MARK: - 状态变更（唯一入口）

    private func setState(_ new: CaptureState, reason: String) {
        let old = snapshot.state
        guard old != new else { return }
        snapshot.state = new
        Log.shared.transition(.session, from: old.rawValue, to: new.rawValue, reason: reason)
    }

    // MARK: - 实时指标刷新

    /// 每秒刷新一次界面上的实时数字（由看门狗的心跳驱动）。
    ///
    /// **为什么必须单独做这件事**：`snapshot.recordedMs` 原本只在分片收尾时被赋值，
    /// 而值来自 `manifest.recordedMs`（= 最后一个**已收尾**分片的 `endMs`）。
    /// 分片是 60 秒一块 —— 于是录音的前 60 秒界面恒定显示 `00:00`，
    /// 第一片收尾时才跳到 `01:00`。真机上这被直接读成「时间不动，像没在录」。
    ///
    /// 判据因此改为**采样计数**：本次会话写入的帧数 ÷ 原生采样率。
    /// 它由实时线程推进，不受消费者是否跟得上、分片是否收尾的影响 ——
    /// 这正是 `CaptureSnapshot.recordedMs` 注释里写的设计意图
    ///（"按样本计数推导，不用墙钟"），此前只是没有落地。
    ///
    /// 顺带把「丢弃帧数」也改成实时刷新：它本是**判断录音是否健康的唯一依据**，
    /// 而等到 60 秒后才更新，等于在最需要它的头一分钟里看不到它。
    private func refreshLiveMetrics() {
        guard snapshot.state.isActive else { return }

        // 采样率取自本次会话的原生格式。拿不到就不更新 ——
        // 宁可显示上一次的值，也不要按错误的采样率算出一个假数字。
        guard let nativeRate = manifest?.nativeSampleRate, nativeRate > 0 else { return }

        let frames = ringBuffer.totalWritten - frameBaseAtSessionStart
        snapshot.recordedMs = Int(Double(max(0, frames)) / nativeRate * 1000)

        // 丢弃帧数同样要相对会话基准（它也是单调累加的）
        snapshot.droppedSamples = ringBuffer.droppedSamples

        // 说明：中断期间没有音频写入 → 上面的数字会**停住不动**，这是刻意的：
        // 已录时长就该等于"真正录到的音频长度"，断口由断口区单独如实显示，
        // 而不是把它摊进时长里假装连续（设计文档 11.2 第 2 条）。
    }

    // MARK: - 首帧探针

    /// 布下首帧探针：从此刻起 `firstFrameDeadlineSeconds` 内必须见到至少一帧音频。
    ///
    /// 基准取**当前**累计写入帧，而不是会话开始的基准 —— 恢复（重建引擎）之后
    /// 再布防时，历史帧会让判定立刻为真，"重建后仍然没有声音"就永远发现不了。
    private func armFirstFrameProbe() {
        firstFrameBase = ringBuffer.totalWritten
        firstFrameArmUptime = ProcessInfo.processInfo.systemUptime
        firstFrameReported = false
    }

    /// 由看门狗 1 秒 tick 驱动（不另起定时器：同一个探针两个定时器迟早读数不一致）。
    private func checkFirstFrame() {
        guard !firstFrameReported, let armUptime = firstFrameArmUptime else { return }

        let frames = ringBuffer.totalWritten - firstFrameBase
        if frames > 0 {
            firstFrameReported = true
            firstFrameArmUptime = nil
            Log.shared.info(
                .capture,
                "首帧到达｜\(frames) 帧进入环形缓冲"
                    + "｜原生格式 \(Int(manifest?.nativeSampleRate ?? 0))Hz"
                    + "｜会话 \(snapshot.sessionId ?? "-")"
            )
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - armUptime
        guard elapsed >= firstFrameDeadlineSeconds else { return }

        firstFrameReported = true
        firstFrameArmUptime = nil
        Log.shared.warn(
            .capture,
            "采样无输出｜已 \(String(format: "%.1f", elapsed))s 未收到任何音频帧"
                + "（阈值 \(String(format: "%.0f", firstFrameDeadlineSeconds))s）"
                + "｜引擎运行中=\(engine.isRunning)｜tap 缓冲 \(engine.tapBufferFrames) 帧"
                + "｜会话 \(snapshot.sessionId ?? "-")"
                + "｜提示：此状态下波形与已录时长都会停住，需检查麦克风/音频图"
        )
    }

    // MARK: - 开始

    func start() async {
        guard !snapshot.state.isActive else {
            Log.shared.warn(.session, "忽略重复的开始请求｜当前状态 \(snapshot.state.rawValue)")
            return
        }

        snapshot = CaptureSnapshot()
        snapshot.source = settings.captureSource
        setState(.preparing, reason: "用户点击开始")

        do {
            try await preflight()
            try beginSession()
            setState(.recording, reason: "采集与落盘均已就绪")
            Log.shared.info(.session, "开始录制｜会话 \(snapshot.sessionId ?? "-")｜\(settings.summary())")
        } catch {
            snapshot.lastError = error.localizedDescription
            tearDownAfterFailure()
            setState(.failed, reason: "准备阶段失败：\(error.localizedDescription)")
            Log.shared.error(.session, "开始录音失败｜\(error.localizedDescription)")
        }
    }

    private func preflight() async throws {
        // 1) 磁盘余量（过低时宁可不开始，也不要录到一半失败）
        if let free = SystemStateMonitor.freeDiskGB(), free < settings.minFreeDiskGB {
            SystemStateMonitor.shared.checkDisk(reason: "开始录音前检查")
            throw CaptureError.diskSpaceTooLow(remainingGB: free)
        }

        // 2) 麦克风权限
        if AVAudioApplication.shared.recordPermission != .granted {
            let granted = await audioSession.requestPermission()
            guard granted else { throw CaptureError.microphonePermissionDenied }
        }

        // 3) 音频会话激活
        guard audioSession.activate(settings.sessionMode) else {
            throw CaptureError.audioSessionActivationFailed(audioSession.lastResult)
        }

        // 4) 先把上次异常终止的会话收尾，避免清单里堆积"永远在录"的记录
        closeUnfinishedSessions()

        Log.shared.info(.session, "开始前检查通过")
    }

    private func beginSession() throws {
        let sessionId = library.makeSessionId()
        var fresh = SessionManifest(
            id: sessionId,
            title: Self.defaultTitle(),
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            endedAtMs: nil,
            state: .recording,
            source: settings.captureSource.rawValue,
            nativeSampleRate: 0,
            segmentSeconds: settings.segmentSeconds,
            bitRate: settings.bitRate,
            segments: [],
            gaps: [],
            note: nil
        )

        // 先落清单：即使下一步就崩溃，"这次录音存在过"也已被记录 ——
        // 这正是后续能识别出"异常终止"的前提（设计文档 4.12）。
        try library.save(fresh)

        // 记录本次会话的帧数基准。必须在 engine.start 之前取 ——
        // 环形缓冲跨会话复用且计数只增不减，不减去基准就会把上一次的时长算进来
        //（见 frameBaseAtSessionStart 的说明）。
        frameBaseAtSessionStart = ringBuffer.totalWritten

        try engine.start(ringBuffer: ringBuffer)
        // 引擎起来了不等于有数据：布下首帧探针，1 秒内没有任何帧进入缓冲就告警
        armFirstFrameProbe()
        guard let nativeFormat = engine.nativeFormat else {
            throw CaptureError.noInputAvailable
        }
        fresh.nativeSampleRate = nativeFormat.sampleRate
        manifest = fresh

        let pipeline = CapturePipeline(ringBuffer: ringBuffer)
        pipeline.onSegments = { [weak self] segments in
            Task { @MainActor in
                self?.handleSegments(segments, reason: "分片写满自动收尾")
            }
        }

        // 实时字幕：把管线已转成 16 kHz 的样本喂给实时转写引擎。
        //
        // 这里接的是**非隔离**的 LiveTranscriptionEngine，而不是 LiveTranscriber（@MainActor）——
        // 本闭包运行在管线队列上，无权调用主 actor 隔离的方法（那会导致编译期隔离错误）。
        // 接上之后并不意味着字幕真的在跑：是否启动由录音页按用户设置决定，
        // 未启动时引擎内部不持有窗口、也不加载模型，开销为零。
        pipeline.onSamples = { samples in
            LiveTranscriptionEngine.shared.feed(samples)
        }

        // 输入电平（录音页的实时声波）。同样在管线队列上回调，切回主线程再写 ——
        // 写进独立的 AudioLevelMonitor 而不是 snapshot：后者每变一次就整页重绘，
        // 而真正需要跟着动的只有那 32 根柱子（见该类的说明）。
        pipeline.onLevel = { level in
            Task { @MainActor in
                AudioLevelMonitor.shared.update(level)
            }
        }
        try pipeline.start(
            sourceFormat: nativeFormat,
            sessionId: sessionId,
            directory: library.rootDirectory,
            segmentSeconds: settings.segmentSeconds,
            bitRate: settings.bitRate
        )
        self.pipeline = pipeline

        let watchdog = CaptureWatchdog()
        watchdog.progressProvider = { [ringBuffer] in ringBuffer.totalWritten }
        watchdog.onStall = { [weak self] seconds in
            self?.handleStall(stalledSeconds: seconds)
        }
        // 复用看门狗的 1 秒心跳刷新界面指标。
        // 不另起定时器的理由：这里的探针本来就在读同一个 totalWritten，
        // 两个定时器各刷一份，迟早会出现界面数字与看门狗判定不一致。
        watchdog.onTick = { [weak self] in
            self?.refreshLiveMetrics()
            // 首帧探针挂在同一个 tick 上：它判定的就是"帧有没有进来"，
            // 与 refreshLiveMetrics 读的是同一个 totalWritten，不需要第二个定时器。
            self?.checkFirstFrame()
        }
        watchdog.start()
        self.watchdog = watchdog

        snapshot.sessionId = sessionId
        snapshot.startedAt = Date()
        snapshot.source = settings.captureSource
        timelineMs = 0
        outageStartUptime = nil
        recoveryAttempts = 0

        library.saveAsync(fresh)
    }

    // MARK: - 停止

    func stop() {
        guard snapshot.state.isActive else { return }
        setState(.stopping, reason: "用户点击停止")

        watchdog?.stop()
        watchdog = nil
        engine.stop()

        let sessionId = snapshot.sessionId
        pipeline?.stop { [weak self] tail in
            Task { @MainActor in
                self?.finishStop(sessionId: sessionId, tailSegments: tail)
            }
        }
    }

    private func finishStop(sessionId: String?, tailSegments: [SegmentWriter.FinishedSegment]) {
        setState(.finalizing, reason: "收尾分片与清单")
        handleSegments(tailSegments, reason: "停止时收尾")

        if var current = manifest {
            current.state = .done
            current.endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            manifest = current
            do {
                try library.save(current)
            } catch {
                Log.shared.error(.storage, "清单收尾写入失败｜\(error.localizedDescription)")
            }
            Log.shared.info(
                .session,
                "会话结束｜\(current.id)｜已录 \(current.durationText())"
                    + "｜分片 \(current.segments.count)｜断口 \(current.gaps.count) 处 \(current.totalGapMs)ms"
                    + "｜体积 \(current.sizeText)"
            )

            // ══ 零落盘强告警 ══
            // 真机踩过：16 kHz + 64 kbps 的 AAC 参数被编码器拒绝，
            // 整场录音 0 分片、0 帧落盘，而日志只有一行 WARN、界面显示"已录 00:00" ——
            // 用户以为录到了，事后才发现没有任何音频。
            // 判据用**采集帧数**而不是时长：时长依赖 nativeSampleRate，取不到时为 0，
            // 会把"确实采到了但没写下去"误判成"什么都没录"。
            let capturedFrames = ringBuffer.totalWritten - frameBaseAtSessionStart
            if current.segments.isEmpty, capturedFrames > 0 {
                let seconds = Int(Double(capturedFrames) / max(1, current.nativeSampleRate))
                snapshot.lastError = "录音已结束，但音频未能保存（共采集约 \(seconds) 秒，0 个分片）。"
                    + "文字稿已单独保留。常见原因：编码参数不被支持或存储目录不可写。"
                Log.shared.error(
                    .storage,
                    "录音零落盘｜会话 \(current.id)｜采集 \(capturedFrames) 帧（约 \(seconds) 秒）"
                        + "｜分片 0｜文字稿已单独保留"
                )
            }
        }

        pipeline = nil
        audioSession.deactivate()

        tearDownRealtime()

        setState(.idle, reason: "会话已结束")

        // 顺带按保留期清理过期音频（文本永久、音频有限）
        library.purgeExpiredAudio(retentionDays: settings.retentionDays)
    }

    /// 收掉实时链路（字幕 + 翻译 + 波形），并**顺带把当场内容落盘**。
    ///
    /// ## 为什么必须抽成独立方法，而不是写在 `finishStop` 里
    /// 会话有**两条**退出路径：
    ///   · 正常停止（用户点停止 / 时长上限 / 磁盘告警）走 `finishStop`
    ///   · 异常结束（准备阶段失败 / 恢复次数超限 / 自愈连续失败）走 `tearDownAfterFailure`
    ///
    /// 这两个 `stop()` 不只是"清内存"—— 它们同时承担
    /// `transcript-live.json` 与 `translations.json`（`pass: .live`）的落盘。
    /// 原先只挂在正常路径上，于是**异常结束那一场会丢掉已经识别出来的全部文字与译文**，
    /// 而界面上的摘要卡仍会显示「已保存 · 0 句」—— 把"丢了"伪装成"没识别到"，
    /// 这是比丢失本身更糟的一种失败方式。
    ///
    /// 幂等性：两个 `stop()` 各自在首行判断"是否真的在跑"，重复调用是空操作；
    /// 准备阶段失败时字幕与翻译从未启动，这里也不会产生任何副作用
    ///（`persistLiveTranscript` 在 `sessionId == nil` 时直接返回）。
    private func tearDownRealtime() {
        LiveTranscriber.shared.stop()
        TranslationService.shared.stopLive()
        // 波形归零：否则页面会定格在最后一次的高度上，看起来像还在收音
        AudioLevelMonitor.shared.reset()
    }

    private func tearDownAfterFailure() {
        watchdog?.stop()
        watchdog = nil
        engine.stop()
        pipeline = nil
        audioSession.deactivate()
        // 与正常停止走同一条收尾：把当场已识别的实时稿与实时译文落盘。
        // 缺这一句时，恢复超限 / 自愈连续失败这两条路径会把内容丢光（见 tearDownRealtime）。
        tearDownRealtime()
        if var current = manifest {
            current.state = .failed
            current.endedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            manifest = current
            try? library.save(current)
        }
    }

    // MARK: - 分片登记

    private func handleSegments(_ segments: [SegmentWriter.FinishedSegment], reason: String) {
        guard var current = manifest else { return }

        for segment in segments {
            current.segments.append(
                SessionManifest.SegmentEntry(
                    seq: segment.seq,
                    fileName: segment.fileName,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    sampleCount: segment.sampleCount,
                    bytes: segment.bytes
                )
            )
            timelineMs = max(timelineMs, segment.endMs)
        }
        manifest = current
        library.saveAsync(current)

        snapshot.segmentCount = current.segments.count
        // **不要把已录时长往回拉**：它现在由采样计数每秒推进（见 refreshLiveMetrics），
        // 而分片只到整数块（每 60 秒一块）—— 直接赋值会让界面每 60 秒
        // 往回跳一秒，看起来像"进度倒退"。取较大者：录制中由心跳领先；
        // 收尾时 manifest 的合计（含最后不足一片的尾巴）更大，自然接管。
        snapshot.recordedMs = max(snapshot.recordedMs, current.recordedMs)
        snapshot.gapCount = current.gaps.count
        snapshot.totalGapMs = current.totalGapMs
        snapshot.lastWriteCostMs = segments.last?.writeCostMs ?? snapshot.lastWriteCostMs
        snapshot.droppedSamples = ringBuffer.droppedSamples

        if !segments.isEmpty {
            // 每片一行（约 60 秒一条，频率可接受）。
            // **把样本数 / 字节 / 落盘耗时一起记**：这三项是"落盘是否跟得上采集"的
            // 直接证据 —— 只看"分片数在涨"看不出问题；而落盘耗时一旦逼近分片时长，
            // 下一步就是环形缓冲溢出丢帧，那才是不可逆的音频损失。
            let detail = segments.map {
                "#\($0.seq) \($0.sampleCount)帧/\($0.bytes / 1024)KB/\($0.writeCostMs)ms"
            }.joined(separator: "、")

            Log.shared.info(
                .session,
                "分片已登记（\(reason)）｜共 \(current.segments.count) 片"
                    + "｜逻辑时间轴 \(timelineMs)ms｜已录 \(current.durationText())"
                    + "｜本批 \(detail)"
            )

            // 落盘耗时跨档告警。阈值 5 秒的来历：单片时长 60 秒，
            // 也就是"写盘占了采集时长的 8%"已经很不健康；跨档才记，避免每片都刷。
            if let worst = segments.map({ $0.writeCostMs }).max(), worst >= 5_000 {
                Log.shared.warn(
                    .disk,
                    "落盘耗时偏高｜最慢一片 \(worst)ms（分片时长 \(settings.segmentSeconds)s）"
                        + "｜若持续上升会导致环形缓冲溢出、音频出现空洞"
                )
            }
        }
        enforceLimits()
    }

    /// 会话上限与磁盘守卫（设计文档 4.13）。
    private func enforceLimits() {
        // 1) 单次时长上限
        if settings.maxSessionHours > 0,
           timelineMs > settings.maxSessionHours * 3_600_000 {
            Log.shared.warn(.session, "已达单次录音时长上限 \(settings.maxSessionHours) 小时，自动停止")
            snapshot.lastError = "已达单次录音时长上限（\(settings.maxSessionHours) 小时），已自动停止"
            stop()
            return
        }

        // 2) 磁盘余量
        SystemStateMonitor.shared.checkDisk(reason: "录音中")
        if let free = SystemStateMonitor.freeDiskGB(), free < settings.minFreeDiskGB {
            Log.shared.error(.disk, "剩余磁盘 \(String(format: "%.2f", free))GB 低于阈值，自动停止录音")
            snapshot.lastError = "剩余存储不足，已自动停止（已录内容保留）"
            stop()
        }
    }

    // MARK: - 音频事件绑定

    private func bindAudioEvents() {
        let observer = AudioEventObserver.shared

        observer.onInterruption = { [weak self] began, shouldResume, detail in
            guard let self else { return }
            if began {
                self.beginOutage(reason: "音频会话被中断（\(detail)）")
            } else {
                guard self.snapshot.state == .interrupted || self.snapshot.state == .recovering else { return }
                guard shouldResume else {
                    self.snapshot.lastError = "系统未允许自动恢复录音"
                    self.setState(.failed, reason: "中断结束但系统不允许恢复")
                    return
                }
                self.attemptRecovery(reason: "会话中断结束")
            }
        }

        observer.onRouteChange = { [weak self] detail in
            self?.handleRouteChange(detail: detail)
        }

        observer.onEngineConfigurationChange = { [weak self] in
            guard let self, self.snapshot.state == .recording else { return }
            // 引擎已被系统停掉 —— 这是静默停录最常见的原因，必须重建
            self.beginOutage(reason: "音频图配置变更")
            self.recoveryAttempts = 0
            self.attemptRecovery(reason: "音频图配置变更")
        }

        observer.onMediaServicesReset = { [weak self] in
            guard let self, self.snapshot.state.isActive else { return }
            self.beginOutage(reason: "媒体服务重置")
            self.recoveryAttempts = 0
            // 媒体服务重置后转换器内部状态已不可信，整体重建由 attemptRecovery 完成
            self.attemptRecovery(reason: "媒体服务重置")
        }
    }

    private func handleRouteChange(detail: String) {
        guard snapshot.state == .recording else {
            Log.shared.info(.session, "路由变更（未在录制，仅记录）｜\(detail)")
            return
        }
        // 原生格式可能随路由改变，同步给转换器（设计文档 4.10）
        if let format = engine.nativeFormat {
            pipeline?.updateSourceFormat(format)
        }
        Log.shared.info(.session, "路由变更已处理｜\(detail)")
    }

    // MARK: - 中断与恢复

    /// 进入中断态：停引擎、把已采音频全部落盘并收尾当前分片。
    /// 断口的**结算**延后到恢复成功时进行（因为恢复可能失败并持续中断）。
    private func beginOutage(reason: String) {
        guard snapshot.state == .recording else { return }

        if outageStartUptime == nil {
            outageStartUptime = ProcessInfo.processInfo.systemUptime
            outageReason = reason
        }
        setState(.interrupted, reason: reason)
        engine.stop()

        // 收尾当前分片，保证没有任何分片跨越断口（否则时间戳定位会偏）
        if let tail = pipeline?.beginOutage(), !tail.isEmpty {
            handleSegments(tail, reason: "中断前收尾")
        }
    }

    /// 恢复成功：结算断口并把时间轴前移，使断口在时间轴上真实可见。
    private func endOutage() {
        guard let start = outageStartUptime else { return }
        let gapMs = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        outageStartUptime = nil

        guard gapMs > 200 else { return }

        if var current = manifest {
            let gapStart = timelineMs
            let gapEnd = gapStart + gapMs
            current.gaps.append(
                SessionManifest.GapEntry(startMs: gapStart, endMs: gapEnd, reason: outageReason)
            )
            manifest = current
            timelineMs = gapEnd
            library.saveAsync(current)

            snapshot.gapCount = current.gaps.count
            snapshot.totalGapMs = current.totalGapMs
            Log.shared.warn(
                .session,
                "记录断口｜\(gapStart)~\(gapEnd)ms（\(gapMs)ms）｜原因：\(outageReason)"
                    + "｜已把时间轴前移，断口在时间轴上真实存在"
            )
        }

        // 关键：必须在新音频写入之前前移时间轴（skipGap 内部用 sync 保证顺序）
        pipeline?.skipGap(ms: gapMs)
    }

    private func attemptRecovery(reason: String) {
        recoveryAttempts += 1
        setState(.recovering, reason: "\(reason)｜第 \(recoveryAttempts) 次尝试")

        if recoveryAttempts > 10 {
            snapshot.lastError = "连续多次恢复失败，已停止尝试（已录内容保留）"
            Log.shared.error(.session, "恢复尝试超过上限，判定失败")
            tearDownAfterFailure()
            setState(.failed, reason: "恢复次数超限")
            return
        }

        do {
            guard audioSession.activate(settings.sessionMode) else {
                throw CaptureError.audioSessionActivationFailed(audioSession.lastResult)
            }
            try engine.rebuild()
            if let format = engine.nativeFormat {
                pipeline?.updateSourceFormat(format)
                manifest?.nativeSampleRate = format.sampleRate
            }

            // 重建后重新布防：这是最需要证据的时刻 —— "重建成功但依然没有声音"
            // 若不重布防，就只能等 3 秒后的看门狗停滞判定，且分不清是没帧还是消费卡住。
            armFirstFrameProbe()
            endOutage()
            watchdog?.markRecovered()
            recoveryAttempts = 0
            setState(.recording, reason: "恢复成功（\(reason)）")
            Log.shared.info(.session, "恢复成功｜\(reason)")
        } catch {
            Log.shared.error(
                .session,
                "第 \(recoveryAttempts) 次恢复失败｜\(error.localizedDescription)"
            )
            let delay = min(10.0, pow(2.0, Double(recoveryAttempts - 1)))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.snapshot.state == .recovering || self.snapshot.state == .interrupted else { return }
                self.attemptRecovery(reason: reason + "（退避重试）")
            }
        }
    }

    // MARK: - 停滞自愈

    private func handleStall(stalledSeconds: Double) {
        guard snapshot.state == .recording else { return }
        Log.shared.error(
            .capture,
            "看门狗触发自愈｜停滞 \(String(format: "%.1f", stalledSeconds))s"
        )
        beginOutage(reason: "停滞 \(Int(stalledSeconds))s")

        if recoveryAttempts < 2 {
            recoveryAttempts += 1
            attemptRecovery(reason: "停滞自愈")
        } else {
            // 连续自愈无效：不能再无休止重建，但已录内容必须保住
            snapshot.lastError = "连续多次自愈无效，已停止录音（已录内容保留）"
            Log.shared.error(.capture, "停滞自愈连续无效，判定会话失败")
            tearDownAfterFailure()
            setState(.failed, reason: "停滞自愈连续失败")
        }
    }

    // MARK: - 异常终止恢复（设计文档 4.12）

    /// 把上次异常终止（App 被系统杀死或崩溃）的会话自动收尾。
    ///
    /// 这是无调试器环境下**唯一**能让用户把问题反馈清楚的入口：
    /// 被系统直接杀掉时不会触发 applicationWillTerminate，没有任何回调可依赖，
    /// 只能靠"清单里还写着 recording"这一个事实来反推。
    @discardableResult
    func closeUnfinishedSessions() -> [SessionManifest] {
        let unfinished = library.unfinishedSessions()
        guard !unfinished.isEmpty else { return [] }

        var closed: [SessionManifest] = []
        for item in unfinished {
            // 先补登孤儿分片：有音频文件但清单里没记录的情况（设计文档 4.11）
            let repaired = library.repairOrphanSegments(sessionId: item.id)
            var current = library.loadManifest(sessionId: item.id) ?? item

            current.state = .failed
            current.endedAtMs = current.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
            let stamp = "上次录音异常终止（App 被系统终止或崩溃），已自动收尾，已录内容保留"
            current.note = (current.note.map { $0 + "｜" } ?? "") + stamp
            try? library.save(current)
            closed.append(current)

            Log.shared.warn(
                .session,
                "发现异常终止的会话｜\(current.id)｜已录 \(current.recordedMs)ms"
                    + "｜分片 \(current.segments.count)｜补登孤儿 \(repaired) 片｜已自动收尾"
            )
        }
        return closed
    }

    // MARK: - 工具

    private static func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return "录音 " + formatter.string(from: Date())
    }
}
