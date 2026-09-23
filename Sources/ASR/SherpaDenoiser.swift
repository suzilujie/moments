import Foundation

/// 语音增强（降噪），基于 sherpa-onnx 的 GTCRN。
///
/// ## 必须先说清楚的一件事：降噪不等于更准
/// 降噪算法在处理时会引入**失真伪影（artifact / musical noise）**，
/// 而 whisper 这类大模型本身对噪声已相当鲁棒。所以「为了听起来干净去降噪」
/// 有可能**反而抹掉模型需要的语音细节，让字错误率（WER）上升**。
///
/// 这不是可以靠调参消除的问题。因此本项目对降噪的做法是：
/// **不做成默认开启的"增强"，而做成可对照、可验证的选项** ——
/// 原始音频永远保存，降噪在转写时临时施加，用户可以在同一段音频上跑两次
/// （原始 vs 降噪），用产出的文字直接比较。
///
/// ## 为什么用离线接口而不是流式接口
/// 本项目施加降噪的位置是「一段完整音频送入识别之前」（实时字幕的滑窗、
/// 或终稿的单个分片），此时整段音频已经在手上，离线接口更简单也更准确
/// （流式接口为低延迟牺牲了质量）。
///
/// ## 线程约定
/// 持有 C 指针，**不是线程安全的**，必须在单一线程/队列上使用。
final class SherpaDenoiser {

    /// 不透明句柄。
    ///
    /// 与 SherpaVad 同理，**必须用 `OpaquePointer`**：头文件里的
    /// `SherpaOnnxOfflineSpeechDenoiser` 是不完整类型（只有 typedef，结构体从不定义），
    /// Clang importer 对不完整结构体的指针不生成 Swift 类型名。
    private var handle: OpaquePointer?
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    private(set) var lastError: String?

    var isReady: Bool { handle != nil }

    /// 模型要求的输入采样率（GTCRN 为 16000）
    private(set) var sampleRate: Int32 = 16_000

    init?(modelPath: String, numThreads: Int32 = 1) {
        guard let modelString = strdup(modelPath),
              let providerString = strdup("cpu") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [modelString, providerString]

        var config = SherpaOnnxOfflineSpeechDenoiserConfig()
        config.model = SherpaOnnxOfflineSpeechDenoiserModelConfig(
            gtcrn: SherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig(model: UnsafePointer(modelString)),
            num_threads: numThreads,
            debug: 0,
            provider: UnsafePointer(providerString),
            // 与 VAD 同理：只配置一个模型家族，避免"选哪个是实现定义的"
            dpdfnet: SherpaOnnxOfflineSpeechDenoiserDpdfNetModelConfig(
                model: nil,
                attenuation_limit_db: 0
            )
        )

        guard let created = SherpaOnnxCreateOfflineSpeechDenoiser(&config) else {
            lastError = "降噪器创建失败（模型可能损坏或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        handle = created

        let declared = SherpaOnnxOfflineSpeechDenoiserGetSampleRate(created)
        if declared > 0 { sampleRate = declared }
    }

    deinit {
        close()
    }

    /// 对整段音频降噪。
    /// - Returns: 降噪后的样本；失败返回 nil（**调用方应回退到原始音频**，
    ///   而不是因为降噪失败就放弃这段音频的转写）
    func denoise(_ samples: [Float]) -> [Float]? {
        guard let handle, !samples.isEmpty else { return nil }

        var output: [Float] = []
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            guard let denoised = SherpaOnnxOfflineSpeechDenoiserRun(
                handle,
                base,
                Int32(buffer.count),
                sampleRate
            ) else { return }
            defer { SherpaOnnxDestroyDenoisedAudio(denoised) }

            let count = Int(denoised.pointee.n)
            guard count > 0, let pointer = denoised.pointee.samples else { return }
            output = Array(UnsafeBufferPointer(start: pointer, count: count))
        }
        return output.isEmpty ? nil : output
    }

    func close() {
        if let handle {
            SherpaOnnxDestroyOfflineSpeechDenoiser(handle)
        }
        handle = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }
}
