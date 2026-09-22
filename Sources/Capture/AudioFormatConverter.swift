import AVFoundation
import Foundation

/// 采样率转换器：把设备原生格式（通常 48 kHz）转成识别与落盘统一使用的 16 kHz 单声道。
///
/// 为什么选"原生格式采集 + 显式转换"而不是"直接以 16 kHz 采集"（设计文档 4.10）：
/// 本项目要在同一路音频上做降噪、VAD、落盘、转写四件事，对格式与采样率的**可控性**
/// 比省几行代码重要得多；直接让系统在音频线程内做隐式转换，出问题时无法观测。
///
/// 使用**流式**接口（withInputFrom）而不是简单的整块转换，是因为后者不保留
/// 转换器内部状态，会在每个数据块边界产生不连续，累积成可听的爆音，
/// 并可能轻微拉高识别错误率。
///
/// 本类只在后台消费队列上使用，不涉及实时线程。
final class AudioFormatConverter {

    static let targetSampleRate: Double = 16_000

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    /// 最近一次转换错误，供日志与自检展示。
    private(set) var lastError: String?
    /// 累计输出的帧数（供与输入帧数比对，验证转换比例是否符合预期）。
    private(set) var totalOutputFrames = 0

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        targetFormat = format
    }

    var isConfigured: Bool { converter != nil }

    /// 依据当前输入格式（重新）建立转换器。
    /// 路由变更后原生格式可能改变，必须重新调用。
    @discardableResult
    func configure(inputFormat: AVAudioFormat) -> Bool {
        if let sourceFormat, sourceFormat.isEqual(inputFormat), converter != nil {
            return true
        }

        guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            lastError = "无法建立转换器：\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)声道 → 16000Hz/1声道"
            converter = nil
            return false
        }

        // 只处理语音，中等质量足够，且比最高质量省 CPU（长时间录音要在意功耗）
        newConverter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        converter = newConverter
        sourceFormat = inputFormat
        lastError = nil
        totalOutputFrames = 0

        Log.shared.info(
            .capture,
            "采样率转换器已建立｜\(Int(inputFormat.sampleRate))Hz/\(inputFormat.channelCount)声道 → "
                + "16000Hz/1声道｜比例 \(String(format: "%.3f", targetFormat.sampleRate / inputFormat.sampleRate))"
        )
        return true
    }

    /// 转换一段样本。
    /// - Parameter samples: 源格式的单声道 Float32 样本
    /// - Returns: 16 kHz 单声道样本
    func convert(_ samples: UnsafePointer<Float>, frameCount: Int) -> [Float] {
        guard frameCount > 0, let converter, let sourceFormat else { return [] }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            lastError = "无法创建输入缓冲"
            return []
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        if let channel = inputBuffer.floatChannelData?[0] {
            memcpy(channel, samples, frameCount * MemoryLayout<Float>.size)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            lastError = "无法创建输出缓冲"
            return []
        }

        return drain(converter: converter, inputBuffer: inputBuffer, outputBuffer: outputBuffer)
    }

    /// 结束流：把转换器内部残留的样本取出（停止录音时调用，避免丢掉末尾几个采样点）。
    ///
    /// 用法：回调里直接返回 `.endOfStream` 且不给数据，转换器会把内部
    /// 延迟线中的残留全部吐出来。不调用这一步，每次停止录音都会丢末尾一小段。
    func flush() -> [Float] {
        guard let converter else { return [] }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: 8192
        ) else { return [] }

        var result: [Float] = []
        for _ in 0..<4 {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if error != nil || status == .error { break }
            result.append(contentsOf: extract(outputBuffer))
            if outputBuffer.frameLength == 0 { break }
        }
        return result
    }

    // MARK: - 内部

    private func drain(
        converter: AVAudioConverter,
        inputBuffer: AVAudioPCMBuffer,
        outputBuffer: AVAudioPCMBuffer
    ) -> [Float] {
        var result: [Float] = []
        var didFeedInput = false

        // 上限 4 轮：第一轮喂数据，后续轮用于把转换器内部残留取干净。
        // 设上限是为了避免任何情况下陷入死循环（真机排错成本很高）。
        for _ in 0..<4 {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if didFeedInput {
                    // 不再喂新数据，但保留转换器内部状态（流式语义）
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didFeedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let error {
                lastError = error.localizedDescription
                Log.shared.error(.capture, "采样率转换失败｜\(error.localizedDescription)")
                break
            }
            if status == .error {
                lastError = "转换器返回 error 状态"
                Log.shared.error(.capture, "采样率转换返回 error 状态")
                break
            }

            result.append(contentsOf: extract(outputBuffer))

            // 没有更多产出即结束
            if outputBuffer.frameLength == 0 { break }
            if status == .inputRanDry { break }
        }

        totalOutputFrames += result.count
        return result
    }

    private func extract(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
