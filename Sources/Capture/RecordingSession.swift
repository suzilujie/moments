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

        try engine.start(ringBuffer: ringBuffer)
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
        }

        pipeline = nil
        audioSession.deactivate()

        // 顺带收掉实时字幕：会话结束后引擎再持有滑窗与模型上下文纯属浪费。
        // 放在这里而不是只交给界面，是因为会话也可能因失败/磁盘告警而自行结束，
        // 那种路径下界面不一定有机会做清理。
        LiveTranscriber.shared.stop()

        setState(.idle, reason: "会话已结束")

        // 顺带按保留期清理过期音频（文本永久、音频有限）
        library.purgeExpiredAudio(retentionDays: settings.retentionDays)
    }

    private func tearDownAfterFailure() {
        watchdog?.stop()
        watchdog = nil
        engine.stop()
        pipeline = nil
        audioSession.deactivate()
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
        snapshot.recordedMs = current.recordedMs
        snapshot.gapCount = current.gaps.count
        snapshot.totalGapMs = current.totalGapMs
        snapshot.lastWriteCostMs = segments.last?.writeCostMs ?? snapshot.lastWriteCostMs
        snapshot.droppedSamples = ringBuffer.droppedSamples

        if !segments.isEmpty {
            Log.shared.info(
                .session,
                "分片已登记（\(reason)）｜共 \(current.segments.count) 片"
                    + "｜逻辑时间轴 \(timelineMs)ms｜已录 \(current.durationText())"
            )
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
