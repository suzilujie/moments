import Foundation

/// 声纹嵌入提取器（M3c）。
///
/// 把一段语音压成一个固定维度的向量（本项目用 CAM++ 中英通用模型，192 维）。
/// 这个向量的价值在于：**同一个人的两段语音，向量余弦相似度显著高于不同人**。
/// 声纹库、跨块身份对齐都建立在它之上。
///
/// ## 与 diarization 的关系（容易混淆，先说清楚）
/// `SherpaDiarizer` 内部**也**会建一个嵌入提取器用于聚类，但它只输出
/// 「第几段属于第几个说话人」这种**局部编号**，不把向量交出来。
/// 我们额外需要向量，是为了两件事：
///   1. 跨块对齐（一次会话分多块处理时，把各块的"说话人1"接续起来）
///   2. 声纹库比对（认出这是张三还是李四）
/// 因此本类是独立存在、而不是从 diarizer 里抠向量。
///
/// ## 线程约定
/// 持有 C 指针，**不是线程安全的**，必须在单一线程/队列上使用。
final class SherpaSpeakerEmbedder {

    private var handle: OpaquePointer?
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    private(set) var lastError: String?
    /// 向量维度（由模型决定；取不到时为 0）
    private(set) var dimension: Int = 0

    var isReady: Bool { handle != nil }

    init?(modelPath: String, numThreads: Int32 = 1) {
        guard let modelString = strdup(modelPath),
              let providerString = strdup("cpu") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [modelString, providerString]

        var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: UnsafePointer(modelString),
            num_threads: numThreads,
            debug: 0,
            provider: UnsafePointer(providerString)
        )

        guard let created = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config) else {
            lastError = "声纹提取器创建失败（模型可能损坏或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        handle = created

        let dim = SherpaOnnxSpeakerEmbeddingExtractorDim(created)
        dimension = max(0, Int(dim))
    }

    deinit {
        close()
    }

    /// 计算一段音频的声纹向量。
    ///
    /// - Returns: 归一化后的向量；音频过短或模型未就绪时返回 nil。
    ///   **调用方必须处理 nil** —— 太短的片段（如一声"嗯"）本来就无法提取声纹，
    ///   这是模型的固有限制，不是错误。
    func embedding(of samples: [Float], sampleRate: Int32 = 16_000) -> [Float]? {
        guard let handle, !samples.isEmpty else { return nil }
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(handle) else {
            return nil
        }
        defer { SherpaOnnxDestroyOnlineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, base, Int32(buffer.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)

        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(handle, stream) != 0 else { return nil }
        guard let pointer = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(handle, stream) else {
            return nil
        }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(pointer) }

        let dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(handle))
        guard dim > 0 else { return nil }
        let raw = Array(UnsafeBufferPointer(start: pointer, count: dim))
        return Self.normalized(raw)
    }

    func close() {
        if let handle {
            SherpaOnnxDestroySpeakerEmbeddingExtractor(handle)
        }
        handle = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }

    // MARK: - 向量代数（纯函数，便于在自检页直接验证）

    /// 归一化。**提取后立刻归一化是刻意的**：
    /// 归一化后余弦相似度退化为点积，计算更快；
    /// 更重要的是把"向量模长"这个与说话人身份无关的量消掉，
    /// 否则音量大的片段会因为模长大而在质心里占更大权重。
    static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        let norm = sum.squareRoot()
        guard norm > 1e-9 else { return vector }
        return vector.map { $0 / norm }
    }

    /// 余弦相似度。输入应为归一化向量；未归一化也能算（内部会算模长）。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in 0..<a.count {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        guard denominator > 1e-9 else { return -1 }
        return dot / denominator
    }

    /// 一组向量的质心（**加权前先归一化**，见 normalized 的说明）。
    static func centroid(of vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        var used = 0
        for vector in vectors where vector.count == first.count {
            for index in 0..<first.count { sum[index] += vector[index] }
            used += 1
        }
        guard used > 0 else { return nil }
        return normalized(sum.map { $0 / Float(used) })
    }
}
