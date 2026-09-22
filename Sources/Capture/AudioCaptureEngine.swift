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

    let ringBuffer = AudioRingBuffer()

    private(set) var nativeFormat: AVAudioFormat?
    private(set) var isRunning = false
    private(set) var tapBufferFrames: AVAudioFrameCount = 0

    // MARK: - 启动 / 停止

    func start() throws {
        guard !isRunning else { return }

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

        let buffer = ringBuffer
        input.installTap(onBus: 0, bufferSize: tapBufferFrames, format: format) { pcmBuffer, _ in
            // ══════ 实时音频线程 ══════
            // 此处只允许：读指针、memcpy。
            // 禁止：内存分配、文件/网络 I/O、任何可能阻塞的调用、日志写入。
            guard let channel = pcmBuffer.floatChannelData?[0] else { return }
            buffer.write(channel, count: Int(pcmBuffer.frameLength))
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
        Log.shared.info(
            .capture,
            "采集引擎已停止｜环形缓冲剩余未读 \(ringBuffer.availableToRead) 帧"
                + "｜累计丢弃 \(ringBuffer.droppedSamples) 帧"
        )
    }

    /// 完全重建（用于 AVAudioEngineConfigurationChange / 媒体服务重置）。
    /// 环形缓冲保留不清空 —— 已经采到的音频不能因为重建而丢掉。
    func rebuild() throws {
        Log.shared.warn(.capture, "开始重建采集引擎（完全新建实例）")
        stop()
        engine = AVAudioEngine()
        try start()
    }

    // MARK: - 消费

    /// 从环形缓冲取走样本（仅限后台消费队列调用）。
    func drain(maxFrames: Int) -> [Float] {
        ringBuffer.read(maxCount: maxFrames)
    }

    /// 丢弃未读数据（会话结束或判定数据陈旧时使用）。
    func discardPending() {
        ringBuffer.drainDiscard()
    }
}
