import AVFoundation
import Foundation

/// SenseVoice 离线识别引擎（sherpa-onnx 的 offline recognizer，M6）。
///
/// ## 为什么用它替换 whisper.cpp
/// 项目此前的识别引擎是 whisper.cpp（`WhisperEngine`）。真机暴露的两类问题都指向 whisper：
///   · 中文**同音字**（是/时/事/实、在/再、的/得/地）靠换大模型 + beam 只能缓解，不能根治；
///   · whisper 对「带歌声的音乐」只会编造文本（元描述式幻觉），需要外挂 CED 音乐检测来挡，
///     而 CED 在真机上把语音误判成音乐、把实时字幕切成断点。
/// SenseVoice 是专为中文优化的端到端模型，同音字明显更准，且**事件检测内建**（<|MUSIC|> 等），
/// 一个模型同时解决「同音字」与「音乐幻觉」两件事 —— 因此 CED 与 whisper 一并移除。
///
/// ## 与 whisper 相同的批式（batch）语义
/// SenseVoice 同样是「喂一段 → 吐一段」，没有流式。因此实时字幕的「VAD 切句 + 逐段识别」
/// 架构原样保留，只把识别这一步换成它（见 `LiveTranscriptionEngine`）。
///
/// ## 线程约定
/// 持有 C 指针（recognizer），**不是线程安全的**，必须在单一线程/队列上使用。
/// 与 `SherpaVad` / `SherpaDenoiser` 同一约定：不共享实例，一路一实例。
final class SenseVoiceEngine {

    /// 一段识别结果（相对**本段音频起点**的毫秒）。SenseVoice 一次给出整段文本，
    /// 因此通常只有一个元素；保留数组形状是为了与时间轴映射层（`TranscriptMath`）兼容。
    struct Segment {
        let startMs: Int
        let endMs: Int
        let text: String
    }

    /// 一次识别的完整结果。
    struct Recognition {
        /// 有效文本段（空 = 没有听出任何话，可能是纯音乐/静音）。
        let segments: [Segment]
        /// 检测到的语言（仅 `language == "auto"` 时才有意义），如 "zh" / "en"。
        /// 供实时/终稿的「语言锁定」使用。
        let language: String?
        /// 该段是否被模型判定为音乐/背景音乐（含 <|MUSIC|> 或 <|BGM|> 事件）。
        let isMusic: Bool
    }

    /// 不透明句柄。`SherpaOnnxOfflineRecognizer` 在头文件里是不完整类型，
    /// Clang importer 一律映射为 `OpaquePointer`（与 SherpaVad / MusicDetector 同理）。
    private var recognizer: OpaquePointer?

    /// 传给 C 的字符串必须活到 recognizer 销毁为止（模型路径 / tokens 路径 / 语言 /
    /// provider / 解码方法）。直接传 Swift String 的临时指针会在调用返回后失效，
    /// 表现为「随机崩溃或读到乱码路径」，因此显式持有并在 close 时释放。
    private var retainedStrings: [UnsafeMutablePointer<CChar>] = []

    /// 诊断用：每个引擎实例只打一次原始识别结果。
    ///
    /// ## 为什么需要它
    /// sherpa-onnx 的结果文本是**逐 token 查表拼接**的（`ConvertSenseVoiceResult`），
    /// C++ 侧没有任何标点过滤；标点是否存在，完全取决于模型有没有吐出标点 token。
    /// 只改 `use_itn` 后若仍无标点，就必须看两件事才能定性：
    ///   · token 前缀里有没有 `，` `。` 这类符号（判断模型输出）
    ///   · 前缀 4 个结构化 token 长什么样（判断 ITN / 语言张量是否被接收）
    /// 没有这条日志，只能反复发版试参数。
    private var hasLoggedFirstResult = false

    /// ITN 开关。集中一处定义，创建配置与诊断日志共用同一值，
    /// 避免"日志说开着、实际传的是关"这种自欺。
    static let useITN: Int32 = 1

    private(set) var lastError: String?

    var isLoaded: Bool { recognizer != nil }

    /// - Parameters:
    ///   - modelPath: `model.int8.onnx` 的路径。
    ///   - tokensPath: `tokens.txt` 的路径（随包内置，见 `SenseVoiceModel.bundledTokensURL`）。
    ///   - language: "auto" 由模型自动判定；或具体语言（"zh"/"en"/"ja"/"ko"/"yue"）。
    ///     与 whisper 的 language 参数语义一致：只在创建时确定，识别时不再传。
    init?(
        modelPath: String,
        tokensPath: String,
        language: String = "auto",
        numThreads: Int32 = 1
    ) {
        guard let modelString = strdup(modelPath),
              let tokensString = strdup(tokensPath),
              let languageString = strdup(language),
              let providerString = strdup("cpu"),
              let decodingString = strdup("greedy_search") else {
            lastError = "内存分配失败"
            return nil
        }
        retainedStrings = [modelString, tokensString, languageString, providerString, decodingString]

        // 只配置 sense_voice 一个模型家族；其余（transducer / paraformer / whisper 等）
        // 保持全零，交给 sherpa-onnx 自行判断 —— 与 VAD/降噪「只配一个家族」同一原则。
        var modelConfig = SherpaOnnxOfflineModelConfig()
        modelConfig.sense_voice = SherpaOnnxOfflineSenseVoiceModelConfig(
            model: UnsafePointer(modelString),
            language: UnsafePointer(languageString),
            // use_itn=1（2026-10-17 开启）：启用逆文本归一化（ITN）。
            //
            // ══ 为什么必须开 ══
            // ITN 在 sherpa-onnx 里不只是"数字规范化"，它同时决定了模型前缀 token：
            //   use_itn=1 → `<|withitn|>`：输出带标点（，。？），数字/日期按阿拉伯数字规范化
            //   use_itn=0 → `<|woitn|>`  ：输出**完全没有标点**，数字保持中文写法
            // 早先为"避免数字转换错误"关掉它，代价是所有字幕都没有标点 ——
            // 既影响阅读，也让翻译质量下降（翻译模型依赖标点断句），
            // 还让「短句合并」的句末标点判断（endsWithSentencePunctuation）永远失效。
            //
            // 已知副作用：中文数字串可能被规范化（"一百二十三"→"123"），
            // 极少数量词场景可能误转；若真机再出现明显误转，再考虑做成设置项。
            use_itn: Self.useITN
        )
        modelConfig.tokens = UnsafePointer(tokensString)
        modelConfig.num_threads = numThreads
        modelConfig.debug = 0
        modelConfig.provider = UnsafePointer(providerString)

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.model_config = modelConfig
        config.decoding_method = UnsafePointer(decodingString)
        // feat_config 保持默认（全零）：SenseVoice 内部自带特征提取，无需外部指定。

        guard let created = SherpaOnnxCreateOfflineRecognizer(&config) else {
            lastError = "SenseVoice 识别器创建失败（模型或 tokens 可能损坏、或与库版本不匹配）"
            retainedStrings.forEach { free($0) }
            retainedStrings = []
            return nil
        }
        recognizer = created
    }

    deinit {
        close()
    }

    // MARK: - 识别

    /// 识别一段 16 kHz 单声道 PCM（[-1, 1]）。
    ///
    /// 每次调用走完整的 create stream → accept → decode → get result → destroy 流程：
    /// stream 是一次性的（`SherpaOnnxAcceptWaveformOffline` 对每个 stream 至多调用一次），
    /// 而 recognizer（模型）常驻，避免每段都重新加载模型。
    func transcribe(_ samples: [Float]) -> Recognition {
        guard let recognizer, !samples.isEmpty else {
            return Recognition(segments: [], language: nil, isMusic: false)
        }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            lastError = "创建离线流失败"
            return Recognition(segments: [], language: nil, isMusic: false)
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            SherpaOnnxAcceptWaveformOffline(stream, 16_000, base, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            lastError = "获取识别结果失败"
            return Recognition(segments: [], language: nil, isMusic: false)
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        // `text` 是 sherpa-onnx 已过滤特殊 token、做过句读处理的纯文本；
        // 音乐/静音段可能为空字符串。
        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        // `lang` 是 sherpa-onnx 从语言 token 解析出的便捷字段（如 "zh" / "en"）。
        var detectedLanguage: String? = result.pointee.lang
            .map { String(cString: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        // 归一化：sherpa-onnx 的 lang 字段在部分版本/模型下直接给出**token 文本**
        //（如 "<|yue|>"），而不是干净的 "yue"。不清洗会让语言锁定拿到无效值，
        // 后续翻译源语言映射失败、翻译静默不启动
        //（真机日志证据：实时字幕检测语言｜<|yue|>，见 work-2026-10-17.log）。
        if let raw = detectedLanguage {
            detectedLanguage = raw
                .replacingOccurrences(of: "<|", with: "")
                .replacingOccurrences(of: "|>", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        // 事件解析（双保险）：
        // 1) 优先读 `event` 字段 —— 它是 sherpa-onnx 直接给出的「识别事件标签」，
        //    SenseVoice 把 <|MUSIC|> / <|BGM|> 等事件 token 解析到这个字段；
        //    取值随版本可能变化，统一按「是否含 music/bgm 关键字」判断，不依赖具体格式。
        // 2) tokens_arr 遍历找 <|MUSIC|> / <|BGM|> 作兜底，并顺带解析语言 token
        //    （lang 字段为空时从这里取）。
        var isMusic = false
        if let event = result.pointee.event.map({ String(cString: $0) }) {
            let lower = event.lowercased()
            if lower.contains("music") || lower.contains("bgm") {
                isMusic = true
            }
        }
        let count = Int(result.pointee.count)
        /// 前若干个原始 token（诊断用：能直接看出模型有没有吐标点）
        var tokenPrefix: [String] = []
        if let tokensArr = result.pointee.tokens_arr {
            for index in 0..<count {
                guard let token = tokensArr[index] else { continue }
                let tokenText = String(cString: token)
                // 取前 12 个：前 4 个是 lang/emotion/event/itn 结构化前缀，
                // 后面就是正文 token，足以判断有没有 `，` `。` 这类符号
                if tokenPrefix.count < 12 { tokenPrefix.append(tokenText) }
                if tokenText == "<|MUSIC|>" || tokenText == "<|BGM|>" {
                    isMusic = true
                }
                if detectedLanguage == nil {
                    switch tokenText {
                    case "<|zh|>": detectedLanguage = "zh"
                    case "<|en|>": detectedLanguage = "en"
                    case "<|ja|>": detectedLanguage = "ja"
                    case "<|ko|>": detectedLanguage = "ko"
                    case "<|yue|>": detectedLanguage = "yue"
                    default: break
                    }
                }
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 每个引擎实例只打一次原始结果样本。
        // 判读方法：
        //   · token 里有 `，`/`。` 但文本里没有 → 我方后处理或解码拼接出了问题；
        //   · token 里也没有标点      → 模型没输出，问题在 ITN 张量或模型本身。
        if !hasLoggedFirstResult, !trimmed.isEmpty {
            hasLoggedFirstResult = true
            Log.shared.info(
                .asr,
                "识别结果样本｜ITN \(Self.useITN == 1 ? "开" : "关")"
                    + "｜语言 \(detectedLanguage ?? "-")｜音乐 \(isMusic)"
                    + "｜前 12 个 token：\(tokenPrefix.joined(separator: " "))"
                    + "｜文本：\(trimmed.prefix(40))"
            )
        }

        var segments: [Segment] = []
        if !trimmed.isEmpty {
            let audioMs = samples.count * 1000 / 16_000
            segments = [Segment(startMs: 0, endMs: audioMs, text: trimmed)]
        }

        return Recognition(segments: segments, language: detectedLanguage, isMusic: isMusic)
    }

    func close() {
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
        recognizer = nil
        retainedStrings.forEach { free($0) }
        retainedStrings = []
    }

    // MARK: - 音频读取

    /// 从分片文件读入 16 kHz 单声道样本。
    /// M1 落盘的就是 16 kHz 单声道 AAC，因此正常情况下无需重采样。
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(1, file.length))
        ) else {
            throw CaptureError.recordingFailed("无法为 \(url.lastPathComponent) 分配读取缓冲")
        }
        try file.read(into: buffer)

        guard let channel = buffer.floatChannelData?[0] else {
            throw CaptureError.recordingFailed("\(url.lastPathComponent) 不是 Float32 格式，无法读取")
        }
        let frames = Int(buffer.frameLength)
        let raw = Array(UnsafeBufferPointer(start: channel, count: frames))

        // 已是目标采样率则直接返回；否则重采样（正常不会走到这里，属防御性处理）
        if Int(format.sampleRate) == Int(AudioFormatConverter.targetSampleRate) {
            return raw
        }

        Log.shared.warn(
            .asr,
            "分片 \(url.lastPathComponent) 采样率为 \(Int(format.sampleRate))Hz，"
                + "与预期的 16000Hz 不一致，正在重采样"
        )
        guard let converter = AudioFormatConverter(), converter.configure(inputFormat: format) else {
            return raw
        }
        var output = raw.withUnsafeBufferPointer { pointer -> [Float] in
            guard let base = pointer.baseAddress else { return [] }
            return converter.convert(base, frameCount: frames)
        }
        output.append(contentsOf: converter.flush())
        return output
    }

    /// 留一半核心给系统与音频链路 —— 识别把 CPU 吃满会直接影响录音的稳定性。
    static var recommendedThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
