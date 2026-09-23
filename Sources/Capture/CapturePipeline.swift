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

    /// 最近一次消费耗时（供界面判断落盘是否吃紧）。
    private(set) var lastTickCostMs = 0
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
                    if let segment = try? writer.append(tail) {
                        finished.append(contentsOf: segment)
                    }
                }
            }

            // 4) 收尾最后一片（不足 60 秒的那片，最容易漏掉）
            if let writer = self.writer, let last = try? writer.close() {
                finished.append(last)
            }
            self.writer = nil

            Log.shared.info(
                .capture,
                "消费管线已停止｜累计转出 \(self.totalConvertedFrames) 帧"
                    + "｜分片 \(self.totalSegments) 个｜本次收尾 \(finished.count) 个"
                    + "｜环形缓冲丢弃 \(self.ringBuffer.droppedSamples) 帧"
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
            guard let segment = try? writer.finalizeCurrent() else { return [] }
            return [segment]
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
            if let writer, let segment = try? writer.finalizeCurrent() {
                finished.append(segment)
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

        do {
            let segments = try writer.append(samples)
            finished.append(contentsOf: segments)
            totalConvertedFrames += samples.count
            totalSegments += segments.count
        } catch {
            // 落盘失败属严重问题：音频在环形缓冲里，不写就会溢出丢弃。
            // 这里只记录并继续，避免因一次失败把整条链路拖垮。
            Log.shared.error(
                .storage,
                "分片写入失败｜\(error.localizedDescription)｜环形缓冲剩余 \(ringBuffer.availableToRead) 帧"
            )
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
}
