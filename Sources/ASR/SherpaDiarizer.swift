import Foundation

/// 说话人分离（diarization），基于 sherpa-onnx。
///
/// 链路：pyannote 分割（找出"可能换人了"的边界）→ 声纹嵌入 → 快速聚类
/// → 输出「某段时间 → 第几个说话人」。
///
/// ## 三条必须提前接受的边界
/// 1. **只能产出局部编号**（说话人 1 / 2 / 3），它**不认识人**。
///    要跨会话认人，必须另建声纹库（见 SpeakerProfileStore 与 DiarizationService）。
/// 2. **重叠说话（两人同时讲）准确率会明显下降** —— 这是全行业公认难题。
///    设计上选择如实标注"此段可能重叠"，而不是假装判断正确。
/// 3. **时间是秒**（float），而本项目内部时间轴统一用毫秒。
///    换算必须在这里一次性做掉 —— 散落到各处迟早会错，而且错了表现为
///    "说话人标签整体偏移"，极难发现。
///
/// ## 为什么用阈值聚类而不是指定人数
/// 本项目是"一键开始、一直录"的形态，**没人知道一次会话会有几个人说话**。
/// 指定 num_clusters 虽然更准，但要求提前知道人数，与产品形态冲突。
/// 因此用阈值聚类，接受它偶发的过分割/欠分割。
///
/// ## 线程约定
/// 持有 C 指针，**不是线程安全的**，必须在单一线程/队列上使用。
/// 且注意：一次 process 调用是**同步阻塞**的，长音频会跑很久。
final class SherpaDiarizer {

    /// 一段「谁在说」的结果（时间已换算为毫秒）
    struct Turn {
        let startMs: Int
        let endMs: Int
        let speaker: Int
        let confidence: Float
    }

    private var handle: OpaquePointer?
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    private(set) var lastError: String?

    var isReady: Bool { handle != nil }

    /// 模型要求的采样率
    private(set) var sampleRate: Int32 = 16_000

    init?(
        segmentationModelPath: String,
        embeddingModelPath: String,
        threshold: Float = 0.5,
        minDurationOn: Float = 0.3,
        minDurationOff: Float = 0.5,
        numThreads: Int32 = 1
    ) {
        guard let segmentationString = strdup(segmentationModelPath),
              let embeddingString = strdup(embeddingModelPath),
              let providerString = strdup("cpu") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [segmentationString, embeddingString, providerString]

        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()

        // 只配置 pyannote 一个分割模型家族（官方要求"只配置一个"，
        // 多配时选哪个是实现定义的 —— 这种不确定性必须避免）
        config.segmentation = SherpaOnnxOfflineSpeakerSegmentationModelConfig(
            pyannote: SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                model: UnsafePointer(segmentationString),
                // 0 表示使用官方默认的滑窗步进比 0.1
                window_shift_ratio: 0
            ),
            num_threads: numThreads,
            debug: 0,
            provider: UnsafePointer(providerString)
        )

        config.embedding = SherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: UnsafePointer(embeddingString),
            num_threads: numThreads,
            debug: 0,
            provider: UnsafePointer(providerString)
        )

        config.clustering = SherpaOnnxFastClusteringConfig(
            // -1 / 0 表示"人数未知，走阈值聚类"（与产品形态一致，见类注释）
            num_clusters: 0,
            threshold: threshold,
            compute_confidence: 1
        )

        config.min_duration_on = minDurationOn
        config.min_duration_off = minDurationOff

        guard let created = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
            lastError = "说话人分离器创建失败（模型可能损坏或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        handle = created

        let declared = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(created)
        if declared > 0 { sampleRate = declared }
    }

    deinit {
        close()
    }

    /// 对整段音频做说话人分离。**同步阻塞**，长音频必须放到后台队列。
    /// - Returns: 按开始时间排序的「谁在说」列表；失败返回空数组并写 lastError。
    func process(_ samples: [Float]) -> [Turn] {
        guard let handle, !samples.isEmpty else { return [] }

        var turns: [Turn] = []
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            guard let result = SherpaOnnxOfflineSpeakerDiarizationProcess(
                handle,
                base,
                Int32(buffer.count)
            ) else {
                lastError = "说话人分离返回空结果"
                return
            }
            defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

            let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
            guard count > 0 else { return }
            guard let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else {
                return
            }

            // ⚠️ 这个 API 的销毁语义容易写错，且写错会**直接崩溃**：
            // 头文件写的是 "Destroy a segment **array**"，
            // 即整块数组用基指针销毁**一次**。
            // 若照常规习惯对每个元素依次销毁，就是重复释放 → 崩溃。
            defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }

            for index in 0..<count {
                let segment = segments[index]
                // 秒 → 毫秒。换算收口在这里，外部只见毫秒（见类注释第 3 条）
                let startMs = Int((segment.start * 1000).rounded())
                let endMs = Int((segment.end * 1000).rounded())
                guard endMs > startMs else { continue }
                turns.append(
                    Turn(
                        startMs: startMs,
                        endMs: endMs,
                        speaker: Int(segment.speaker),
                        confidence: segment.confidence
                    )
                )
            }
        }

        if turns.isEmpty, lastError == nil {
            lastError = "未检测到任何说话人片段（音频可能全是静音或噪声）"
        }
        return turns
    }

    func close() {
        if let handle {
            SherpaOnnxDestroyOfflineSpeakerDiarization(handle)
        }
        handle = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }
}
