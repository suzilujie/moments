import Foundation

/// 语音活动检测（VAD），基于 sherpa-onnx 的 Silero VAD。
///
/// ## 为什么必须换成真 VAD，而不是继续用能量门限
/// M2 为了挡 whisper 的「静音幻觉」，用了一个均方根幅度的门限
/// （`TranscriptMath.hasSpeech`）。它几乎不要成本，但**分不清"人声"与"稳定的噪声"**：
/// 空调声、风扇声、路噪都能越过门限，于是幻觉文本照样出现。
///
/// Silero VAD 是一个只有 0.6 MB 的真模型，它回答的是正确的问题：
/// **"这段到底是不是人在说话"**。因此 M3 用它替代能量门限，
/// 能量门限降级为"模型缺失时的兜底"。
///
/// ## 线程约定
/// 本类持有 C 指针，**不是线程安全的**，必须在单一线程/队列上使用。
/// 目前有两处独立使用者（实时字幕引擎、终稿转写 worker），各自持有一个实例 ——
/// 这也是刻意不做成单例的原因：共享一个实例就必须加锁，而加锁会拖慢音频路径。
final class SherpaVad {

    /// VAD 切出的一段语音
    struct SpeechSegment {
        /// 该段在输入样本流中的起始样本下标（用于回溯到时间轴）
        let startSample: Int
        let samples: [Float]
    }

    /// 不透明句柄。
    ///
    /// **必须用 `OpaquePointer` 而不是 `UnsafePointer<SherpaOnnxVoiceActivityDetector>`**：
    /// 头文件里这个类型是**不完整类型**（只有
    /// `typedef struct X X;`，结构体本身从不定义，属刻意的信息隐藏）。
    /// Clang importer 对不完整结构体的指针不会生成 Swift 类型名，
    /// 一律映射为 `OpaquePointer`（与 Swift 里用 SQLite 必须写 `OpaquePointer` 同理）。
    /// 写成 `UnsafePointer<SherpaOnnxVoiceActivityDetector>` 会编译失败：
    /// `cannot find type 'SherpaOnnxVoiceActivityDetector' in scope`。
    private var handle: OpaquePointer?
    /// 传给 C 的字符串必须活到 detector 销毁为止。
    /// 直接传 Swift String 的临时指针会在调用返回后失效 —— 那类 bug 表现为
    /// "随机崩溃或读到乱码路径"，极难定位，因此这里显式持有并在 close 时释放。
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    private(set) var lastError: String?

    var isReady: Bool { handle != nil }

    init?(
        modelPath: String,
        threshold: Float = 0.5,
        minSilenceSeconds: Float = 0.5,
        minSpeechSeconds: Float = 0.25,
        maxSpeechSeconds: Float = 20,
        windowSize: Int32 = 512,
        sampleRate: Int32 = 16_000
    ) {
        guard let modelString = strdup(modelPath),
              let providerString = strdup("cpu") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [modelString, providerString]

        var config = SherpaOnnxVadModelConfig()
        config.silero_vad = SherpaOnnxSileroVadModelConfig(
            model: UnsafePointer(modelString),
            threshold: threshold,
            min_silence_duration: minSilenceSeconds,
            min_speech_duration: minSpeechSeconds,
            window_size: windowSize,
            max_speech_duration: maxSpeechSeconds
        )
        config.sample_rate = sampleRate
        config.num_threads = 1
        config.provider = UnsafePointer(providerString)
        config.debug = 0

        // 只配置 Silero 一家。官方文档明确要求"只应配置一个 VAD 家族"，
        // 两个都配时**选哪个是实现定义的** —— 这种不确定性必须避免。
        config.ten_vad = SherpaOnnxTenVadModelConfig(
            model: nil,
            threshold: 0,
            min_silence_duration: 0,
            min_speech_duration: 0,
            window_size: 0,
            max_speech_duration: 0
        )

        guard let created = SherpaOnnxCreateVoiceActivityDetector(&config, 30.0) else {
            lastError = "VAD 创建失败（模型可能损坏或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        handle = created
    }

    deinit {
        close()
    }

    // MARK: - 使用

    /// 喂入音频并取出**已判定完成**的语音段。
    /// 段边界由 min_silence_duration 决定，因此最后一段通常要等 flush 才出来。
    @discardableResult
    func accept(_ samples: [Float]) -> [SpeechSegment] {
        guard let handle, !samples.isEmpty else { return [] }
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(handle, base, Int32(buffer.count))
        }
        return drain()
    }

    /// 结束流，取出剩余的语音段。
    @discardableResult
    func flush() -> [SpeechSegment] {
        guard let handle else { return [] }
        SherpaOnnxVoiceActivityDetectorFlush(handle)
        return drain()
    }

    func reset() {
        guard let handle else { return }
        SherpaOnnxVoiceActivityDetectorReset(handle)
    }

    /// 一次性判断「这段音频里有没有人声」。
    ///
    /// 实现上走完整的 accept → flush → reset 流程，而不是只看 Detected 标志：
    /// Detected 反映的是**喂完数据之后的那一瞬间**是否处于语音中，
    /// 对于"整段有没有语音"这个问题并不可靠（例如语音在开头、现在已静音）。
    func containsSpeech(in samples: [Float]) -> Bool {
        guard isReady, !samples.isEmpty else { return false }
        reset()
        let duringStream = accept(samples)
        let tail = flush()
        reset()
        return !duringStream.isEmpty || !tail.isEmpty
    }

    func close() {
        if let handle {
            SherpaOnnxDestroyVoiceActivityDetector(handle)
        }
        handle = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }

    // MARK: - 内部

    private func drain() -> [SpeechSegment] {
        guard let handle else { return [] }
        var result: [SpeechSegment] = []

        while SherpaOnnxVoiceActivityDetectorEmpty(handle) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(handle) else {
                // 非空却拿不到指针：为防死循环直接退出。
                // 这里宁可丢一段，也不能让音频线程卡住 —— 卡住等于整条链路停摆。
                Log.shared.warn(.asr, "VAD 队列非空但取不到段，已跳过（防死循环）")
                break
            }
            defer {
                SherpaOnnxDestroySpeechSegment(segment)
                SherpaOnnxVoiceActivityDetectorPop(handle)
            }

            let count = Int(segment.pointee.n)
            guard count > 0, let pointer = segment.pointee.samples else { continue }
            result.append(
                SpeechSegment(
                    startSample: Int(segment.pointee.start),
                    samples: Array(UnsafeBufferPointer(start: pointer, count: count))
                )
            )
        }
        return result
    }
}
