import AVFoundation
import Foundation

/// whisper.cpp 的 Swift 封装（M2 转写引擎）。
///
/// 通过桥接头直接调用 C API —— 因为 whisper.cpp 官方已移除 SwiftPM 支持，
/// 只能由 CI 用官方脚本构建静态 xcframework 后链接（见 .github/workflows/ios-build.yml）。
///
/// 设计取舍（对设计文档 4.10 的补充）：
///   · **先只用 CPU 路径保证正确性**。ggml 的 Metal 后端在真机上的表现需要实测，
///     而"能不能转写"比"转写多快"更基础 —— 先让功能跑通，再谈加速。
///     注意：不改 params 里的 GPU 字段，用官方默认值（由 ggml 自行决定）。
///   · 识别语言**默认由模型自动判定**，但允许显式指定以提升中英文准确性。
///
/// 本类不做线程调度，调用方需自行放到后台队列（转写是重任务，绝不能占主线程）。
final class WhisperEngine {

    struct Segment {
        /// 相对本段音频起点的毫秒偏移（whisper 内部以 10ms 为单位）
        let startMs: Int
        let endMs: Int
        let text: String
    }

    private var context: OpaquePointer?
    private let modelPath: String
    private(set) var lastError: String?

    /// 静音模式：只给实时字幕用。
    ///
    /// 实时字幕每 5 秒重解一次窗口，若每次都在 info 级别留日志，一小时就是 700 多条。
    /// 8 小时会话会把日志的环形缓冲与日志文件全部淹掉 ——
    /// 而那时恰恰是最需要看清「中断恢复 / 降档」记录的场合。
    /// 因此实时路径静音，终稿路径保持正常记录。
    var isQuiet = false

    var isLoaded: Bool { context != nil }

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    deinit {
        unload()
    }

    /// 引擎与后端信息（供自检页展示，确认链接到的是真实实现而非空壳）。
    static var systemInfo: String {
        guard let pointer = whisper_print_system_info() else { return "不可用" }
        return String(cString: pointer)
    }

    // MARK: - 生命周期

    @discardableResult
    func load() -> Bool {
        if context != nil { return true }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            lastError = "模型文件不存在：\(modelPath)"
            Log.shared.error(.asr, lastError ?? "")
            return false
        }

        let started = Date()
        // 用官方默认参数，不逐字段设置 —— 这些结构体的字段名在版本间会变动，
        // 写死字段名会让升级变得脆弱。
        let params = whisper_context_default_params()

        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            lastError = "whisper 上下文初始化失败（模型可能损坏或与库版本不匹配）"
            Log.shared.error(.asr, lastError ?? "")
            return false
        }
        context = ctx

        let costMs = Int(Date().timeIntervalSince(started) * 1000)
        Log.shared.info(
            .asr,
            "whisper 模型已加载｜\(URL(fileURLWithPath: modelPath).lastPathComponent)｜耗时 \(costMs)ms"
        )
        return true
    }

    func unload() {
        guard let context else { return }
        whisper_free(context)
        self.context = nil
        Log.shared.info(.asr, "whisper 模型已释放")
    }

    // MARK: - 转写

    /// 最近一次转写实际使用的语言（**仅当 `language` 传 nil、即自动判定时有意义**）。
    ///
    /// 用途：实时字幕据此**锁定**语言。原先实时路径对每个 15 秒窗口都传 nil，
    /// 于是同一段对话里 whisper 每 15 秒重新判一次语言、结果来回跳 ——
    /// 用户看到的就是「识别结果出现各种语言」（真机反馈原话）。
    /// 详见 `LiveTranscriptionEngine.pinLanguageIfNeeded`。
    private(set) var lastDetectedLanguage: String?

    /// 转写一段 16 kHz 单声道 PCM。
    /// - Parameters:
    ///   - samples: 16 kHz 单声道 Float32 样本
    ///   - language: 语言代码（如 "zh" / "en"）；传 nil 由模型自动判定
    ///   - translateToEnglish: 是否让 whisper 直接输出英文（注意：whisper 只能译成英文）
    /// - Returns: 分段文本；失败返回空数组并写入 lastError
    func transcribe(
        samples: [Float],
        language: String? = nil,
        translateToEnglish: Bool = false
    ) -> [Segment] {
        guard let context else {
            lastError = "模型尚未加载"
            return []
        }
        guard !samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(Self.recommendedThreadCount)
        params.translate = translateToEnglish
        // 全部关闭：这些是给命令行工具用的实时打印，在 App 里只会拖慢速度
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false

        // 语言指针必须在 whisper_full 调用期间保持有效，故用 strdup + defer free
        var languagePointer: UnsafeMutablePointer<CChar>?
        if let language, !language.isEmpty {
            languagePointer = strdup(language)
        }
        defer {
            if let languagePointer { free(languagePointer) }
        }
        params.language = languagePointer.map { UnsafePointer($0) }

        let started = Date()
        var status: Int32 = -1
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            status = whisper_full(context, params, base, Int32(buffer.count))
        }

        guard status == 0 else {
            lastError = "whisper_full 返回 \(status)"
            Log.shared.error(.asr, lastError ?? "")
            return []
        }

        // 记下本次实际使用的语言（只在自动判定时有意义）。
        // 传了明确语言时清空 —— 免得调用方把上一次的判定结果当成"这次也是它"。
        lastDetectedLanguage = nil
        if language == nil {
            let languageId = whisper_full_lang_id(context)
            if languageId >= 0, let languagePointer = whisper_lang_str(languageId) {
                lastDetectedLanguage = String(cString: languagePointer)
            }
        }

        let count = whisper_full_n_segments(context)
        var result: [Segment] = []
        for index in 0..<count {
            guard let textPointer = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // whisper 的时间单位是 10 毫秒
            let t0 = whisper_full_get_segment_t0(context, index)
            let t1 = whisper_full_get_segment_t1(context, index)
            result.append(Segment(startMs: Int(t0) * 10, endMs: Int(t1) * 10, text: text))
        }

        let costMs = Int(Date().timeIntervalSince(started) * 1000)
        let audioMs = Int(Double(samples.count) / 16.0)
        let ratio = audioMs > 0 ? Double(costMs) / Double(audioMs) : 0
        if !isQuiet {
            Log.shared.info(
                .asr,
                "转写完成｜音频 \(audioMs)ms｜耗时 \(costMs)ms"
                    + "｜实时倍率 \(String(format: "%.2f", ratio))（<1.0 表示快于实时）"
                    + "｜分段 \(result.count)"
            )
        }
        return result
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

    /// 留一半核心给系统与音频链路 —— 转写把 CPU 吃满会直接影响录音的稳定性。
    static var recommendedThreadCount: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}
