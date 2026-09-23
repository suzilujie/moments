import AVFoundation
import Foundation

/// 采集引擎：把麦克风音频搬进环形缓冲。
///
/// 职责边界（严格）：
///   · **实时音频线程回调内只做一次 memcpy**：不分配内存、不做 I/O、不写日志
///   · 一切重活（采样率转换、编码、落盘）交给后台消费者
///   · 本类不关心"录多久""存到哪"—— 那是 RecordingSession 与 SegmentWriter 的事
///
/// 之所以把边界划得这么死（设计文档 4.9）：违反的后果不是报错，而是
/// **偶发丢帧与爆音** —— 音频听起来还在，实际已经有空洞，且几乎无法事后定位。
@MainActor
final class AudioCaptureEngine {

    /// 每次重建引擎都新建实例，不复用旧对象。
    /// 原因：AVAudioEngineConfigurationChange 之后旧引擎可能处于不一致状态，
    /// 复用它是"改了却没生效"这类疑难问题的常见来源。
    private var engine = AVAudioEngine()

    /// 环形缓冲由**会话层**创建并持有，引擎只是写入方。
    /// 这样后台消费队列可以直接读它，不必为了取数据而跳回主线程 ——
    /// 否则"后台消费"就名存实亡（每次取数据都要切到主线程）。
    private var ringBuffer: AudioRingBuffer?

    private(set) var nativeFormat: AVAudioFormat?
    private(set) var isRunning = false
    private(set) var tapBufferFrames: AVAudioFrameCount = 0

    // MARK: - 启动 / 停止

    func start(ringBuffer: AudioRingBuffer) throws {
        guard !isRunning else { return }
        self.ringBuffer = ringBuffer

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw CaptureError.noInputAvailable
        }
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw CaptureError.engineStartFailed(
                "输入格式为 \(String(describing: format.commonFormat))，不是 Float32，无法用零拷贝快速路径读取"
            )
        }

        nativeFormat = format
        // 约 85 ms @48kHz：过小会增加实时线程调用频率，过大会增加延迟。
        // 该值属设计文档 4.9 的待实测项，先取保守中间值。
        tapBufferFrames = 4096

        let target = ringBuffer
        input.installTap(onBus: 0, bufferSize: tapBufferFrames, format: format) { pcmBuffer, _ in
            // ══════ 实时音频线程 ══════
            // 此处只允许：读指针、memcpy。
            // 禁止：内存分配、文件/网络 I/O、任何可能阻塞的调用、日志写入。
            guard let channel = pcmBuffer.floatChannelData?[0] else { return }
            target.write(channel, count: Int(pcmBuffer.frameLength))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }

        isRunning = true
        Log.shared.info(
            .capture,
            "采集引擎已启动｜原生格式 \(Int(format.sampleRate))Hz/\(format.channelCount)声道"
                + "｜tap 缓冲 \(tapBufferFrames) 帧"
        )
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false

        let pending = ringBuffer?.availableToRead ?? 0
        let dropped = ringBuffer?.droppedSamples ?? 0
        Log.shared.info(
            .capture,
            "采集引擎已停止｜环形缓冲剩余未读 \(pending) 帧｜累计丢弃 \(dropped) 帧"
        )
        if dropped > 0 {
            // 丢弃大于 0 说明消费者跟不上生产者，属严重信号，必须高亮
            Log.shared.error(
                .capture,
                "环形缓冲发生溢出，已丢弃 \(dropped) 帧音频（消费者跟不上采集，需检查落盘耗时）"
            )
        }
    }

    /// 完全重建（用于 AVAudioEngineConfigurationChange / 媒体服务重置）。
    /// 环形缓冲保留不清空 —— 已经采到的音频不能因为重建而丢掉。
    func rebuild() throws {
        guard let ringBuffer else {
            throw CaptureError.engineStartFailed("重建时缺少环形缓冲引用")
        }
        Log.shared.warn(.capture, "开始重建采集引擎（完全新建实例）")
        stop()
        engine = AVAudioEngine()
        try start(ringBuffer: ringBuffer)
    }
}
