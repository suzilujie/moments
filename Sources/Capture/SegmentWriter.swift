import AVFoundation
import Foundation

/// 分片写入器：把 16 kHz 单声道样本按固定时长切成 `.m4a` 文件（设计文档 4.11）。
///
/// 三条关键设计：
///   1. **时间轴由样本计数推导**，不用墙钟时间相减。AAC 编码器有启动延迟
///      （encoder priming delay），每个文件开头都有样本偏移；若用墙钟，
///      每 60 秒一个文件的偏移会逐片累积成数十毫秒的跨片偏差。
///   2. **先写临时文件、成功后原子重命名**。避免"半截文件"被当成有效分片。
///      注意临时名保留 `.m4a` 扩展名 —— AVAudioFile 靠扩展名推断容器格式，
///      若临时名写成 `.part` 会被当成未知格式而写失败。
///   3. **停止时必须 finalize 最后一片**。最后一片通常不足 60 秒，
///      忘记收尾就会丢掉最后那段录音 —— 这是同类项目最经典的 bug。
final class SegmentWriter {

    struct FinishedSegment {
        let seq: Int
        let fileName: String
        let startMs: Int
        let endMs: Int
        let sampleCount: Int
        let bytes: Int
        let writeCostMs: Int
    }

    let sessionDirectory: URL

    private let sessionId: String
    private let sampleRate: Double
    private let segmentSeconds: Int
    private let bitRate: Int

    private var file: AVAudioFile?
    private var tempURL: URL?
    private var writeBuffer: AVAudioPCMBuffer?

    private var seq = 0
    /// 当前分片已写入的帧数
    private var framesInCurrentSegment = 0
    /// 当前分片之前累计的帧数（用于推导 startMs）
    private var framesBeforeCurrentSegment = 0
    /// 全会话累计帧数
    private(set) var totalFrames = 0

    private var isClosed = false

    init(
        sessionId: String,
        directory: URL,
        sampleRate: Double = AudioFormatConverter.targetSampleRate,
        segmentSeconds: Int = 60,
        bitRate: Int = 32_000
    ) throws {
        self.sessionId = sessionId
        self.sampleRate = sampleRate
        self.segmentSeconds = segmentSeconds
        self.bitRate = bitRate

        let sessionDirectory = directory.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        self.sessionDirectory = sessionDirectory
    }

    // MARK: - 写入

    /// 追加样本。达到分片时长即自动收尾当前分片并开启下一片。
    /// - Returns: 本次调用中收尾完成的分片（通常为空，每 60 秒返回一条）
    func append(_ samples: [Float]) throws -> [FinishedSegment] {
        guard !isClosed, !samples.isEmpty else { return [] }

        var finished: [FinishedSegment] = []
        var offset = 0
        let framesPerSegment = Int(Double(segmentSeconds) * sampleRate)

        while offset < samples.count {
            if file == nil {
                try openNewSegment()
            }

            let remainingInSegment = framesPerSegment - framesInCurrentSegment
            let chunkCount = min(remainingInSegment, samples.count - offset)
            guard chunkCount > 0 else { break }

            let chunk = Array(samples[offset..<(offset + chunkCount)])
            try writeChunk(chunk)

            offset += chunkCount
            if framesInCurrentSegment >= framesPerSegment {
                if let segment = try finalizeCurrent() {
                    finished.append(segment)
                }
            }
        }

        return finished
    }

    /// 收尾当前分片（停止录音、或分片写满时调用）。
    @discardableResult
    func finalizeCurrent() throws -> FinishedSegment? {
        guard let tempURL else {
            file = nil
            return nil
        }
        // 没有写入任何样本时不产出空分片
        guard framesInCurrentSegment > 0 else {
            file = nil
            try? FileManager.default.removeItem(at: tempURL)
            self.tempURL = nil
            return nil
        }

        let startedAt = Date()
        let sampleCount = framesInCurrentSegment

        // ══ 关键且易错 ══
        // 必须让 AVAudioFile 的**最后一个强引用**释放，m4a 容器才会被写入尾部索引。
        // 因此这里刻意**不**把它绑定到局部变量（`guard let file` 会延长其生命周期，
        // 导致 self.file = nil 之后对象仍然存活，重命名出去的就是未收尾的文件）。
        file = nil
        self.tempURL = nil

        let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        let finalName = String(format: "%06d.m4a", seq)
        let finalURL = sessionDirectory.appendingPathComponent(finalName)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try? FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        let startMs = Int(Double(framesBeforeCurrentSegment) / sampleRate * 1000.0)
        let endMs = Int(Double(framesBeforeCurrentSegment + sampleCount) / sampleRate * 1000.0)

        let segment = FinishedSegment(
            seq: seq,
            fileName: finalName,
            startMs: startMs,
            endMs: endMs,
            sampleCount: sampleCount,
            bytes: byteCount,
            writeCostMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )

        framesBeforeCurrentSegment += sampleCount
        framesInCurrentSegment = 0
        seq += 1

        Log.shared.info(
            .storage,
            "分片收尾｜seq=\(segment.seq)｜\(startMs)~\(endMs)ms"
                + "｜样本 \(segment.sampleCount)｜\(byteCount / 1024) KB"
                + "｜收尾耗时 \(segment.writeCostMs)ms"
        )
        return segment
    }

    /// 因中断跳过一段时间：把**时间轴前移**，使断口在时间轴上真实存在。
    ///
    /// 为什么必须显式做这一步（设计文档 4.3 / 4.12 的关键实现细节）：
    /// 时间轴由"实际写入的样本数"推导。中断期间没有任何样本写入，
    /// 所以恢复后新分片的 startMs 会**恰好等于**上一片的 endMs ——
    /// 时间轴看起来完全连续，**断口根本不会出现**，漏录被静默掩盖。
    /// 必须按中断时长把时间轴前移，断口才会作为"时间轴上的空洞"显现出来。
    ///
    /// 注意：前移的这段不计入 totalFrames（它没有真实音频），也不计入任何分片。
    func advanceTimeline(byMs ms: Int) {
        let safeMs = max(0, ms)
        guard safeMs > 0 else { return }
        let frames = Int(Double(safeMs) / 1000.0 * sampleRate)
        framesBeforeCurrentSegment += frames
        skippedMs += safeMs
        Log.shared.warn(
            .storage,
            "时间轴前移 \(safeMs)ms（对应 \(frames) 帧）以记录断口｜累计跳过 \(skippedMs)ms"
        )
    }

    /// 累计因中断跳过的时间（即总断口时长，按样本率换算口径一致）。
    private(set) var skippedMs = 0

    /// 关闭写入器（会话结束）。返回最后一次收尾的分片。
    @discardableResult
    func close() throws -> FinishedSegment? {
        guard !isClosed else { return nil }
        let last = try finalizeCurrent()
        isClosed = true
        Log.shared.info(
            .storage,
            "写入器已关闭｜会话 \(sessionId)｜分片数 \(seq)｜累计样本 \(totalFrames)"
                + "｜对应时长 \(Int(Double(totalFrames) / sampleRate * 1000))ms"
        )
        return last
    }

    // MARK: - 内部

    private func openNewSegment() throws {
        let temp = sessionDirectory.appendingPathComponent(String(format: "%06d.partial.m4a", seq))
        if FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate
        ]

        file = try AVAudioFile(
            forWriting: temp,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        tempURL = temp
        framesInCurrentSegment = 0
    }

    private func writeChunk(_ samples: [Float]) throws {
        guard let file else { return }
        let format = file.processingFormat

        if writeBuffer == nil || Int(writeBuffer!.frameCapacity) < samples.count {
            let capacity = max(samples.count, 16_384)
            writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity))
        }
        guard let buffer = writeBuffer, let channel = buffer.floatChannelData?[0] else {
            throw CaptureError.recordingFailed("无法准备写入缓冲")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress {
                memcpy(channel, base, samples.count * MemoryLayout<Float>.size)
            }
        }

        try file.write(from: buffer)

        framesInCurrentSegment += samples.count
        totalFrames += samples.count
    }
}
