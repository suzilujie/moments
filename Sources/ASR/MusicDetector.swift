import Foundation

/// 音乐/音频事件检测（audio tagging），基于 sherpa-onnx 的 CED 模型
/// （CED = Conditional Event Detection，条件事件检测）。
///
/// ## 为什么需要它：whisper 对音乐只会产生幻觉
/// VAD 只能区分「语音 / 非语音」，分不清「音乐 / 人声」——带歌声的主题曲、BGM
/// 会被 VAD 误判为 speech，然后 whisper 对音乐**只会编造文本**（"普通话是
/// 普通话的简体中文句子"、"（词: …）"这类元描述）。`no_speech_prob` 对纯静音/噪声
/// 有效，但对"带歌声的音乐"无效（歌声被当成语音，概率低）。
///
/// 本类回答的是正确的问题：**这段到底是音乐还是人声**。Music 概率超过阈值时，
/// 调用方应直接标注「（音乐）」、不送 whisper —— 幻觉从源头消失。
///
/// ## 为什么选 CED tiny 而不是 Zipformer
/// Zipformer 音频标记模型约 90 MB，无法随包内置，只能运行时下载 —— 而交付环境
/// 实测 github.com 不可达，等于功能永久不可用。CED tiny 的 int8 模型仅约 5.85 MB，
/// 可随包内置（见 `SherpaBundledModel.ced`），永久可用、不依赖任何网络。
///
/// ## 线程约定
/// 与 `SherpaVad` 相同：本类持有 C 指针，**不是线程安全的**，必须在单一线程/队列上使用。
/// 刻意不做成单例，理由同 VAD（共享实例就必须加锁，加锁会拖慢音频路径）。
final class MusicDetector {

    /// 一次检测命中的音频事件（按概率降序）。
    struct AudioEvent {
        let name: String
        let prob: Float
    }

    /// 不透明句柄（tagger）。
    ///
    /// 同 `SherpaVad`：`SherpaOnnxAudioTagging` 在头文件里是**不完整类型**
    /// （只有 `typedef struct X X;`），Clang importer 一律映射为 `OpaquePointer`。
    private var tagger: OpaquePointer?

    /// 传给 C 的字符串（模型路径 / 标签路径 / provider）必须活到 tagger 销毁为止。
    /// 直接传 Swift String 的临时指针会在调用返回后失效 —— 那类 bug 表现为
    /// "随机崩溃或读到乱码路径"，因此显式持有并在 close 时释放。
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    private(set) var lastError: String?

    var isReady: Bool { tagger != nil }

    private let topK: Int32

    /// 音频标记模型的输入采样率固定为 16 kHz（sherpa-onnx 的 CED 约定）。
    private let sampleRate: Int32 = 16_000

    init?(
        modelPath: String,
        labelsPath: String,
        topK: Int32 = 5,
        numThreads: Int32 = 1
    ) {
        self.topK = topK

        guard let modelString = strdup(modelPath),
              let labelsString = strdup(labelsPath),
              let providerString = strdup("cpu") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [modelString, labelsString, providerString]

        // 只配置 CED 一个模型家族（zipformer 留空）。
        // 官方文档明确要求"只应配置一个家族"，两个都配时选哪个是实现定义的。
        var modelConfig = SherpaOnnxAudioTaggingModelConfig()
        modelConfig.ced = UnsafePointer(modelString)
        modelConfig.num_threads = numThreads
        modelConfig.debug = 0
        modelConfig.provider = UnsafePointer(providerString)

        var config = SherpaOnnxAudioTaggingConfig()
        config.model = modelConfig
        config.labels = UnsafePointer(labelsString)
        config.top_k = topK

        guard let created = SherpaOnnxCreateAudioTagging(&config) else {
            lastError = "音乐检测器创建失败（模型可能损坏或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        tagger = created
    }

    deinit {
        close()
    }

    // MARK: - 使用

    /// 对一段 PCM（16 kHz Float32，[-1, 1]）做音频事件检测，返回按概率降序的 top-K 事件。
    ///
    /// 每次调用走完整的 create stream → accept → compute → destroy stream 流程：
    /// stream 是一次性的（`SherpaOnnxAcceptWaveformOffline` 对每个 stream 至多调用一次），
    /// 而 tagger（模型）常驻，避免每段都重新加载模型。
    func classify(_ samples: [Float]) -> [AudioEvent] {
        guard let tagger, !samples.isEmpty else { return [] }

        guard let stream = SherpaOnnxAudioTaggingCreateOfflineStream(tagger) else {
            lastError = "创建离线流失败"
            return []
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, base, Int32(buffer.count))
        }

        // 返回值是 NULL 终止的指针数组，按概率降序；results[0] 即最可能的事件。
        guard let results = SherpaOnnxAudioTaggingCompute(tagger, stream, topK) else {
            lastError = "音频事件检测计算失败"
            return []
        }
        defer { SherpaOnnxAudioTaggingFreeResults(results) }

        var events: [AudioEvent] = []
        var index = 0
        while let eventPointer = results[index] {
            let event = eventPointer.pointee
            events.append(
                AudioEvent(
                    name: String(cString: event.name),
                    prob: event.prob
                )
            )
            index += 1
        }
        return events
    }

    /// 这段音频里 Music 事件的概率（0~1）。检测器不可用时返回 0（视作"不是音乐"，
    /// 宁可放行也不误杀真话）。
    func musicProbability(_ samples: [Float]) -> Float {
        guard let music = classify(samples).first(where: { $0.name == "Music" }) else {
            return 0
        }
        return music.prob
    }

    func close() {
        if let tagger {
            SherpaOnnxDestroyAudioTagging(tagger)
        }
        tagger = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }
}
