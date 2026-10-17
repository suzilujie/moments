import AVFoundation
import Foundation

/// 后台采集管线：把环形缓冲里的**原生格式**样本转成 16 kHz，编码成 m4a 分片。
///
/// ## 线程约定（必须严格遵守）
/// 本类所有成员**只在 `queue` 上访问**，不在主线程、也不在实时音频线程访问。
/// 这是"采集与转写解耦"原则在实现上的落点：
///   · 实时线程：只往环形缓冲写（memcpy）
///   · 主线程：只做状态机与界面
///   · 本管线：承担全部重活（采样率转换、编码、落盘）
///
/// 之所以单独成类而不是塞进 RecordingSession：RecordingSession 是 @MainActor，
/// 若把转换器与写入器放在它上面，后台就会被迫频繁跳回主线程，重活等于没解耦。
final class CapturePipeline {

    /// 消费线程。userInitiated 优先级的理由是：落盘若跟不上采集，
    /// 环形缓冲会溢出并丢帧 —— 这是必须避免的后果。
    let queue = DispatchQueue(label: "com.xfish.moments.capture.pipeline", qos: .userInitiated)

    private let ringBuffer: AudioRingBuffer
    private let converter: AudioFormatConverter?
    private var writer: SegmentWriter?
    private var needsConversion = true

    private var timer: DispatchSourceTimer?
    private var isRunning = false

    /// 每次消费的批次上限（按**原生**采样率计）。
    /// 取 1 秒量级：既不会让单次处理过久，也不会频繁唤醒。
    private let maxFramesPerTick = 48_000
    private let tickIntervalMs = 100

    /// 分片收尾回调。**在 queue 上调用**，取用方需自行切回主线程。
    var onSegments: (([SegmentWriter.FinishedSegment]) -> Void)?

    /// 已转成 16 kHz 的样本回调（实时字幕用）。**在 queue 上调用**。
    ///
    /// 纪律：这里只允许做「入队」级别的廉价操作（见 `LiveTranscriptionEngine.feed`），
    /// **绝不允许在此做识别**。本队列同时负责落盘，一旦被阻塞，
    /// 环形缓冲就会溢出丢帧 —— 那是不可逆的音频损失，而字幕晚几秒毫无影响。
    /// 为 nil 时（未开实时字幕）整条路径零开销。
    var onSamples: (([Float]) -> Void)?

    /// 输入电平回调（实时声波用，0…1）。**在 queue 上调用**，约每 100 ms 一次，
    /// 取值方需自行切回主线程。
    ///
    /// ## 为什么电平在这里算，而不是在实时音频回调里
    /// `AudioCaptureEngine` 的 installTap 里写死了一条纪律：**只允许读指针与 memcpy**，
    /// 禁止任何额外计算与可能阻塞的调用。而本类每 100 ms 本来就握着
    /// 一批已转成 16 kHz 的样本（`drainOnce` 里），顺手算一次均方根
    /// 只是几千次乘加，既不分配内存也不碰 I/O。
    /// 代价是波形比声音晚约 100 ms —— 对"它在听我说话"这件事毫无影响。
    var onLevel: ((Float) -> Void)?

    /// 最近一次消费耗时（供界面判断落盘是否吃紧）。
    private(set) var lastTickCostMs = 0

    // MARK: - 失败统计与心跳（只在 queue 上访问）

    /// 落盘失败累计次数（整场会话）。
    private(set) var appendFailureTotal = 0
    /// 距离上一条失败明细之后又失败了几次（用于"近 N 秒失败 M 次"）。
    private var appendFailureSinceLog = 0
    /// 上一条失败明细的时间。失败可能每 100ms 复现一次，不节流会刷爆日志。
    private var lastFailureLogAt = Date.distantPast
    /// 失败明细的最小间隔。
    private let failureLogInterval: TimeInterval = 10
    /// 是否处于"失败中"状态，用于在恢复时补一条恢复日志。
    private var isFailing = false

    /// 上一条心跳日志的时间。
    private var lastHeartbeatAt = Date()
    /// 心跳间隔：没有日志 ≠ 一切正常，所以要定期自证"消费线程还活着"。
    private let heartbeatInterval: TimeInterval = 60
    /// 累计转出的 16 kHz 帧数。
    private(set) var totalConvertedFrames = 0
    /// 累计收尾的分片数。
    private(set) var totalSegments = 0

    init(ringBuffer: AudioRingBuffer) {
        self.ringBuffer = ringBuffer
        self.converter = AudioFormatConverter()
    }

    // MARK: - 生命周期

    /// 开始消费。
    /// - Parameter sourceFormat: 采集引擎给出的原生格式（决定是否需要重采样）
    func start(
        sourceFormat: AVAudioFormat,
        sessionId: String,
        directory: URL,
        segmentSeconds: Int,
        bitRate: Int
    ) throws {
        guard !isRunning else { return }

        let needsResample = Int(sourceFormat.sampleRate) != Int(AudioFormatConverter.targetSampleRate)
        needsConversion = needsResample

        if needsResample {
            guard let converter, converter.configure(inputFormat: sourceFormat) else {
                throw CaptureError.engineStartFailed("采样率转换器建立失败")
            }
        } else {
            converter?.configure(inputFormat: sourceFormat)
        }

        writer = try SegmentWriter(
            sessionId: sessionId,
            directory: directory,
            segmentSeconds: segmentSeconds,
            bitRate: bitRate
        )

        startTimer()
        isRunning = true

        Log.shared.info(
            .capture,
            "消费管线已启动｜源格式 \(Int(sourceFormat.sampleRate))Hz"
                + "｜重采样=\(needsResample ? "需要" : "不需要")"
                + "｜分片时长 \(segmentSeconds)s｜码率 \(bitRate / 1000)kbps"
                + "｜消费间隔 \(tickIntervalMs)ms"
        )
    }

    /// 停止消费并收尾。
    /// - Parameter completion: **在 queue 上调用**，携带最后收尾的分片
    func stop(completion: @escaping ([SegmentWriter.FinishedSegment]) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion([])
                return
            }

            // 1) 先停定时器，避免停止过程中还在往里写
            self.stopTimer()
            self.isRunning = false

            var finished: [SegmentWriter.FinishedSegment] = []

            // 2) 把环形缓冲里剩余的数据全部消费掉 —— 不丢最后这一段
            self.drainOnce(into: &finished)

            // 3) 取出转换器内部残留（转换器有内部延迟线）
            if self.needsConversion, let converter = self.converter {
                let tail = converter.flush()
                if !tail.isEmpty, let writer = self.writer {
                    // 这里原来是 try?：收尾阶段的失败会被彻底吞掉，
                    // 结果就是"最后一段音频没了，日志里一条都没有"。必须显式记录。
                    do {
                        finished.append(contentsOf: try writer.append(tail))
                    } catch {
                        Log.shared.error(
                            .storage,
                            "收尾残留写入失败｜\(tail.count) 帧｜\(error.diagnosticText)"
                        )
                    }
                }
            }

            // 4) 收尾最后一片（不足 60 秒的那片，最容易漏掉）
            if let writer = self.writer {
                do {
                    if let last = try writer.close() {
                        finished.append(last)
                    }
                } catch {
                    Log.shared.error(
                        .storage,
                        "最后一片收尾失败｜分片序号 \(writer.nextSeq)｜\(error.diagnosticText)"
                    )
                }

                let stats = "失败统计 创建 \(writer.failedOpenCount)"
                    + " / 写入 \(writer.failedWriteCount)"
                    + " / 收尾 \(writer.failedFinalizeCount)"
                    + "｜断口 \(writer.skippedMs)ms"
                if self.appendFailureTotal > 0 || writer.failedFinalizeCount > 0 {
                    Log.shared.warn(.capture, "落盘失败汇总｜\(stats)｜管线侧累计 \(self.appendFailureTotal) 次")
                } else {
                    Log.shared.info(.capture, "落盘失败汇总｜\(stats)")
                }
            }
            self.writer = nil

            Log.shared.info(
                .capture,
                "消费管线已停止｜累计转出 \(self.totalConvertedFrames) 帧"
                    + "｜分片 \(self.totalSegments) 个｜本次收尾 \(finished.count) 个"
                    + "｜环形缓冲丢弃 \(self.ringBuffer.droppedSamples) 帧"
                    + "｜落盘失败 \(self.appendFailureTotal) 次"
            )
            completion(finished)
        }
    }

    /// 丢弃尚未消费的数据（用于判定数据陈旧时）。
    func discardPending() {
        queue.async { [weak self] in
            self?.ringBuffer.drainDiscard()
        }
    }

    /// 立即收尾当前分片并返回（中断发生、看门狗判定停滞时调用）。
    ///
    /// 为什么中断时必须收尾：若让一个分片文件跨过断口，该文件内部就同时包含
    /// 断口前后的音频，而它的 [startMs, endMs] 区间会把断口算进去 ——
    /// 后续「点句回听」按时间戳定位到这片的偏移量就会偏。
    /// 收尾后每个分片都保证"自身无断口"，断口只存在于分片之间，与清单模型一致。
    func finalizeSegmentNow() -> [SegmentWriter.FinishedSegment] {
        queue.sync {
            guard let writer else { return [] }
            // 原来是 try?：这里失败会静默返回空数组，外部完全看不出"该收尾却没收到"。
            do {
                guard let segment = try writer.finalizeCurrent() else { return [] }
                return [segment]
            } catch {
                Log.shared.error(
                    .storage,
                    "立即收尾失败｜分片序号 \(writer.nextSeq)｜\(error.diagnosticText)"
                )
                return []
            }
        }
    }

    /// 进入中断：把环形缓冲里剩余数据**全部消费掉**并收尾当前分片。
    ///
    /// 用 sync 而非 async 是刻意的：返回时必须保证"已采集的音频全部落盘、
    /// 且当前分片已收尾"，这样随后调用 skipGap 的时间轴前移才发生在正确的边界上。
    /// 若这里用 async，前移就可能夹在未落盘的数据中间，导致断口位置错乱。
    func beginOutage() -> [SegmentWriter.FinishedSegment] {
        queue.sync {
            var finished: [SegmentWriter.FinishedSegment] = []
            drainOnce(into: &finished)
            if let writer {
                do {
                    if let segment = try writer.finalizeCurrent() {
                        finished.append(segment)
                    }
                } catch {
                    Log.shared.error(
                        .storage,
                        "中断收尾失败｜分片序号 \(writer.nextSeq)｜\(error.diagnosticText)"
                    )
                }
            }
            return finished
        }
    }

    /// 因中断跳过一段时间：把时间轴前移，使断口在清单里可见。
    /// 用 sync 保证这次前移**一定发生在下一个分片写入之前**。
    func skipGap(ms: Int) {
        queue.sync {
            writer?.advanceTimeline(byMs: ms)
        }
    }

    /// 采样率变化后重建转换器（路由变更会改变原生格式，设计文档 4.10 / 4.12）。
    func updateSourceFormat(_ format: AVAudioFormat) {
        queue.async { [weak self] in
            guard let self, let converter = self.converter else { return }
            let needsResample = Int(format.sampleRate) != Int(AudioFormatConverter.targetSampleRate)
            self.needsConversion = needsResample
            if needsResample {
                _ = converter.configure(inputFormat: format)
            }
        }
    }

    // MARK: - 定时消费

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + .milliseconds(tickIntervalMs),
            repeating: .milliseconds(tickIntervalMs),
            leeway: .milliseconds(20)
        )
        source.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            var finished: [SegmentWriter.FinishedSegment] = []
            self.drainOnce(into: &finished)
            if !finished.isEmpty {
                self.onSegments?(finished)
            }
            self.logHeartbeatIfNeeded()
        }
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// 单次消费（仅在 queue 上调用）。
    private func drainOnce(into finished: inout [SegmentWriter.FinishedSegment]) {
        guard let writer else { return }

        let started = Date()
        let raw = ringBuffer.read(maxCount: maxFramesPerTick)
        guard !raw.isEmpty else { return }

        let samples: [Float]
        if needsConversion, let converter {
            samples = raw.withUnsafeBufferPointer { pointer -> [Float] in
                guard let base = pointer.baseAddress else { return [] }
                return converter.convert(base, frameCount: raw.count)
            }
        } else {
            samples = raw
        }

        guard !samples.isEmpty else {
            lastTickCostMs = Int(Date().timeIntervalSince(started) * 1000)
            return
        }

        // 实时字幕：把已转到 16 kHz 的样本顺手分发出去（仅入队，不做识别）。
        // 放在落盘之前是有意的 —— 即使这一次 writer.append 失败，
        // 字幕侧也已经拿到这段音频，不会因为落盘异常而整段没有字幕。
        onSamples?(samples)

        // 电平：同一批样本顺手算一次均方根（纯算术，不分配、不阻塞）
        onLevel?(Self.rmsLevel(samples))

        do {
            let segments = try writer.append(samples)
            finished.append(contentsOf: segments)
            totalConvertedFrames += samples.count
            totalSegments += segments.count
            noteAppendSuccess()
        } catch {
            // 落盘失败属严重问题：音频在环形缓冲里，不写就会溢出丢弃。
            // 这里只记录并继续，避免因一次失败把整条链路拖垮。
            noteAppendFailure(error, samples: samples.count)
        }

        lastTickCostMs = Int(Date().timeIntervalSince(started) * 1000)

        // 单次消费耗时接近或超过定时周期，说明落盘开始吃紧，必须提前预警
        if lastTickCostMs > tickIntervalMs {
            Log.shared.warn(
                .storage,
                "单次消费耗时 \(lastTickCostMs)ms 已超过消费间隔 \(tickIntervalMs)ms，落盘可能跟不上采集"
            )
        }
    }

    // MARK: - 失败与心跳日志

    /// 记录一次落盘失败。
    ///
    /// ## 为什么要节流
    /// 定时器每 100ms 消费一次。若失败是持续性的（例如分片目录被删、磁盘满），
    /// 每秒会刷 10 条同构错误 —— 一小时的日志就有 36000 条，
    /// **真正有用的其他错误会被彻底淹没**，而且落盘写日志本身也在消耗空间。
    /// 因此：明细最多每 10 秒一条，其余只累计计数；计数会随下一条明细与心跳一起输出。
    private func noteAppendFailure(_ error: Error, samples: Int) {
        appendFailureTotal += 1
        appendFailureSinceLog += 1
        isFailing = true

        let now = Date()
        guard now.timeIntervalSince(lastFailureLogAt) >= failureLogInterval else { return }
        lastFailureLogAt = now

        Log.shared.error(
            .storage,
            "分片写入失败｜\(error.diagnosticText)"
                + "｜本批 \(samples) 帧"
                + "｜近 \(Int(failureLogInterval)) 秒失败 \(appendFailureSinceLog) 次"
                + "｜累计失败 \(appendFailureTotal) 次"
                + "｜环形缓冲剩余 \(ringBuffer.availableToRead) 帧"
                + "｜丢弃 \(ringBuffer.droppedSamples) 帧"
                + "｜已转出 \(totalConvertedFrames) 帧｜分片 \(totalSegments) 个"
        )
        appendFailureSinceLog = 0
    }

    /// 记录一次成功（只在"刚从失败中恢复"时输出一条，避免每 100ms 一行正常日志）。
    private func noteAppendSuccess() {
        guard isFailing else { return }
        isFailing = false
        Log.shared.info(
            .storage,
            "分片写入恢复｜期间累计失败 \(appendFailureTotal) 次"
                + "｜已转出 \(totalConvertedFrames) 帧｜分片 \(totalSegments) 个"
                + "｜环形缓冲剩余 \(ringBuffer.availableToRead) 帧"
        )
        appendFailureSinceLog = 0
    }

    /// 每分钟一条落盘心跳。
    ///
    /// 为什么必须有：本项目最需要诊断的故障是"锁屏后停止录音"——那种情况下
    /// **没有任何错误日志**，只有"日志不再增长"这一条线索。有了心跳，就能一眼看出
    /// 消费线程是停在哪个时刻、当时环形缓冲里积压了多少帧。
    private func logHeartbeatIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval else { return }
        lastHeartbeatAt = now

        let segmentFrames = writer?.currentSegmentFrames ?? 0
        let nextSeq = writer?.nextSeq ?? 0
        Log.shared.info(
            .storage,
            "落盘心跳｜分片 \(totalSegments) 个（当前 seq=\(nextSeq)，已写 \(segmentFrames) 帧）"
                + "｜已转出 \(totalConvertedFrames) 帧"
                + "｜环形缓冲待消费 \(ringBuffer.availableToRead) 帧"
                + "｜累计丢弃 \(ringBuffer.droppedSamples) 帧"
                + "｜本次消费 \(lastTickCostMs)ms"
                + "｜失败累计 \(appendFailureTotal) 次"
        )
    }

    // MARK: - 电平

    /// 均方根电平 → 0…1 的显示区间。
    ///
    /// ## 为什么不能直接把 RMS 乘个系数
    /// 人对响度的感知是对数的，而线性 RMS 在"对方小声说话"时几乎贴地 ——
    /// 波形会看起来像根本没在收音，用户就会以为麦克风坏了。
    /// 这里先转成 dB，再按 **60 dB 动态范围**线性映射到 0…1：
    /// -60 dB（约 0.001，安静房间底噪）→ 0，0 dB（满量程）→ 1。
    /// 低于 -60 dB 一律压在 0，避免静音时柱子抖动。
    private static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        // 1e-7 兜底：log10(0) 是 -inf，会把整条波形变成 NaN
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = (db + 60) / 60
        return min(max(normalized, 0), 1)
    }
}
