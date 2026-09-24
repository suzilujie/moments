import AVFoundation
import Foundation

/// `AVSpeechSynthesizer` 的委托代理。
///
/// **为什么要单独一个类**：`AVSpeechSynthesizerDelegate` 的方法不是主 actor 隔离的，
/// 若让 `@MainActor` 的 `SpeechReader` 直接实现该协议，在严格并发下是隔离冲突。
/// 用一个独立的非隔离代理接收回调、再跳回主 actor，是本项目既有的分层范式
/// （见 TranscriptionService / LiveTranscriber 的编排层-worker 分层）。
private final class SpeechDelegateProxy: NSObject, AVSpeechSynthesizerDelegate {

    /// 一句话朗读结束（无论正常结束还是被停止）
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // 主动停止时**不**推进队列：调用方已经清空了队列，
        // 这里再推进只会让状态错乱（见 SpeechReader.stop）
    }
}

/// TTS 朗读（设计文档 8.4）。
///
/// ## 三个用途（文档原文）
///   1. 朗读**译文** —— 听目标语言的标准发音，同时脱离原文检验自己是否听懂
///   2. 朗读**原文** —— 录音本身听不清时，用合成语音还原句子
///   3. **连播整篇** —— 当作泛听材料
///
/// ## 边界（必须写在界面上，不能只写在注释里）
/// 系统 TTS **音质不如真人，语调平淡、无情绪、无口音差异**。
/// 因此它**不能替代原声回听**：
///   · 原声练的是真实听力（连读、吞音、语速、口音）
///   · TTS 练的是清晰输入（先确认"这句话本身是什么"，再回去听真的）
/// 两者是并存的两种练习，不是替代关系。若界面不说明，用户可能拿 TTS 替代原声，
/// 结果在真实对话里依然听不懂 —— 那是"用错了工具却不自知"。
@MainActor
final class SpeechReader: ObservableObject {

    static let shared = SpeechReader()

    /// 正在朗读的条目标识（供界面高亮）
    @Published private(set) var speakingId: String?
    @Published private(set) var isSpeaking = false
    /// 连播时队列里还剩几句
    @Published private(set) var pendingCount = 0
    /// 出错信息（如本机没有该语言的语音包）。界面必须显示，不能静默用别的语言读。
    @Published private(set) var lastError: String?

    /// 朗读语速。默认值 0.5 对学习者偏快，这里降到 0.45 ——
    /// 目标是"清晰输入"，慢一点比快一点有用；真要练语速应该去听原声。
    static let rate: Float = 0.45

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = SpeechDelegateProxy()

    private var queue: [(id: String, text: String, language: String)] = []
    private var currentIndex = 0

    private init() {
        delegate.onFinish = { [weak self] in
            // 回调来自 AVFoundation，不保证在主线程 —— 用项目既有范式跳回主 actor
            Task { @MainActor in self?.advance() }
        }
        synthesizer.delegate = delegate
    }

    // MARK: - 对外

    /// 朗读一句。会打断当前朗读。
    func speak(id: String, text: String, language: String) {
        start(items: [(id, text, language)])
    }

    /// 连续朗读多句（泛听）。会打断当前朗读。
    func speakAll(_ items: [(id: String, text: String, language: String)]) {
        start(items: items)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queue = []
        currentIndex = 0
        speakingId = nil
        isSpeaking = false
        pendingCount = 0
    }

    /// 切换：正在读这条就停，否则开始读。
    func toggle(id: String, text: String, language: String) {
        if speakingId == id {
            stop()
        } else {
            speak(id: id, text: text, language: language)
        }
    }

    // MARK: - 队列

    private func start(items: [(id: String, text: String, language: String)]) {
        stop()
        let usable = items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return }
        queue = usable
        currentIndex = 0
        lastError = nil
        startNext()
    }

    private func startNext() {
        guard currentIndex < queue.count else {
            speakingId = nil
            isSpeaking = false
            pendingCount = 0
            return
        }

        let item = queue[currentIndex]

        // **语音包缺失必须报错，不能静默回落**：
        // `AVSpeechSynthesizer` 在找不到该语言语音时会用默认语音照读 ——
        // 表现是"用英文音读中文"，而系统不报任何错。
        // 那比朗读失败更糟：用户会以为是自己听错了。
        guard let voice = Self.resolveVoice(for: item.language) else {
            lastError = "本机没有「\(item.language)」的语音包，无法朗读。"
                + "可在 设置 → 辅助功能 → 朗读内容 → 声音 里下载对应语言的语音。"
            stop()
            Log.shared.warn(.asr, "TTS 缺少语音包｜\(item.language)")
            return
        }

        speakingId = item.id
        isSpeaking = true
        pendingCount = queue.count - currentIndex - 1

        let utterance = AVSpeechUtterance(string: item.text)
        utterance.voice = voice
        utterance.rate = Self.rate
        synthesizer.speak(utterance)
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        currentIndex += 1
        startNext()
    }

    // MARK: - 语音解析

    /// 把项目内部的语言代码规整为 `AVSpeechSynthesisVoice` 认识的形式。
    ///
    /// 本项目存的语言代码可能只有主语言（`en` / `ja`）或带脚本（`zh-Hans`），
    /// 而系统要的是「主语言-区域」（`en-US`）。**不做这一步会静默回落到默认语音**。
    static func normalizedVoiceCode(_ code: String) -> String {
        let parts = code.split(separator: "-").map { String($0) }
        guard let primary = parts.first?.lowercased(), !primary.isEmpty else { return "en-US" }

        switch primary {
        case "zh":
            // zh-Hans / zh-Hant 按脚本区分，系统对应 zh-CN / zh-TW
            let script = parts.count >= 2 ? parts[1].lowercased() : "hans"
            return script.hasPrefix("hant") ? "zh-TW" : "zh-CN"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "ru": return "ru-RU"
        case "it": return "it-IT"
        case "pt": return "pt-BR"
        default:
            // 未知语言：两段式则按 "xx-YY" 拼；否则用主语言本身让系统自己匹配
            if parts.count >= 2, parts[1].count == 2 {
                return "\(primary)-\(parts[1].uppercased())"
            }
            return primary
        }
    }

    /// 解析可用的语音。优先精确匹配，失败则按主语言前缀找任意可用语音。
    /// - Returns: nil 表示本机确实没有该语言 —— 调用方必须据此报错，不能照读。
    static func resolveVoice(for code: String) -> AVSpeechSynthesisVoice? {
        let normalized = normalizedVoiceCode(code)
        if let voice = AVSpeechSynthesisVoice(language: normalized) { return voice }

        let prefix = String(normalized.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first {
            $0.language.lowercased().hasPrefix(prefix)
        }
    }

    /// 本机可用语音的概要（自检页展示用）。
    /// 值得暴露出来：语言学习依赖语音包，而"有没有装"只能在设备上看。
    static func availableVoicesSummary() -> String {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard !voices.isEmpty else { return "无" }
        let languages = Set(voices.map { String($0.language.prefix(2)).lowercased() }).sorted()
        return "\(voices.count) 个语音 / \(languages.count) 种语言（\(languages.joined(separator: " "))）"
    }
}
