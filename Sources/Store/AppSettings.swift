import Foundation

/// 可配置项（用户已确认：未定选项由实现方定合理默认值，并做成运行时可改）。
///
/// 全部通过 UserDefaults 持久化。之所以现在就把"待真机标定"的参数集中到这里，
/// 是因为设计文档里登记的一批不确定项（采样率、分片时长、码率、保留期、
/// 降档阈值）都需要在真机上逐步调整 —— 做成可调，就不必每次改代码重装。
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - 采集

    /// 默认录制模式。M1 只有环境模式；会议模式（系统内录）是 M8。
    @Published var captureSource: CaptureSourceKind {
        didSet { defaults.set(captureSource.rawValue, forKey: Keys.source) }
    }

    /// 音频会话模式：默认**共存**（保"一直录"的体验，设计文档 4.8）
    @Published var sessionMode: AudioSessionMode {
        didSet { defaults.set(sessionMode == .coexistent ? "coexistent" : "highFidelity", forKey: Keys.mode) }
    }

    /// 分片时长（秒）。60 秒 = 崩溃最多损失 1 分钟
    @Published var segmentSeconds: Int {
        didSet { defaults.set(segmentSeconds, forKey: Keys.segmentSeconds) }
    }

    /// 落盘码率（bps）。32 kbps ≈ 14 MB/小时（设计文档 4.4）
    ///
    /// **上限由编码器决定，不是由存储预算决定**：16 kHz 单声道 AAC 在 64 kbps 时
    /// `AVAudioFile(forWriting:)` 直接抛 `#560226676`（`'!dat'`），整场录音 0 分片。
    /// 因此超过 `maxBitRate` 的取值一律钳制回 32 kbps（含旧版本存下来的 64 kbps）。
    @Published var bitRate: Int {
        didSet { defaults.set(bitRate, forKey: Keys.bitRate) }
    }

    /// 16 kHz 单声道 AAC 的实测可用码率上限。
    static let maxBitRate = 48_000

    /// 单次录音时长上限（小时），防止忘记停止录满存储
    @Published var maxSessionHours: Int {
        didSet { defaults.set(maxSessionHours, forKey: Keys.maxHours) }
    }

    /// 音频保留天数（文本永久、音频有限，设计文档 4.5）
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }

    /// 剩余磁盘低于此值即停止录音（GB，设计文档 4.13）
    @Published var minFreeDiskGB: Double {
        didSet { defaults.set(minFreeDiskGB, forKey: Keys.minFreeDiskGB) }
    }

    // MARK: - 转写与语言（M2 / M5 / M6 使用）

    /// 是否启用实时转写。默认开；低电量或过热时自动降档关闭（设计文档 4.13）
    @Published var realtimeTranscriptionEnabled: Bool {
        didSet { defaults.set(realtimeTranscriptionEnabled, forKey: Keys.realtime) }
    }

    /// 转写语言。取值见 `SenseVoiceModel.languageOptions`，**默认 "auto"（自动判定）**。
    ///
    /// ## 两个选项各自的定位（2026-09-24 与用户确认）
    ///
    /// · **自动判定（默认）**：不需要用户操心，由模型在开头判一次并**锁定**整场。
    ///   它的固有代价是"在有限证据上猜一次"——猜错的代价是整场都按错的语言重拼。
    ///   （真机反馈「实时识别有的扯淡，出现各种语言」正是它在没锁定时的表现。）
    ///   为把代价压到最低，实现上做了三件事：判一次即锁定、只在该窗口**真正出字**
    ///   之后才锁、把锁定结果显示出来并允许一键更改。
    ///
    /// · **指定语言**：更确定、可复现 —— 指认是知识，检测是猜测。
    ///   日常中文语境下指定「中文」最稳，而指定中文**不妨碍**识别夹在其中的英文词
    ///  （language 参数只钉住解码起手语言，不限制词表）；只有**整段**外语才会退化。
    ///
    /// 两者并存、随时可切（设置页与录音页都有入口）。
    /// **选了 auto 就不必再问「为什么偶尔判错」——那是这条路的固有代价；
    /// 要确定性就指定语言。** 这句话也是留给后人的。
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: Keys.transcriptionLang) }
    }

    /// 实时字幕是否先对音频降噪（M3）。
    ///
    /// 默认**关**。理由必须说清楚：降噪会引入失真伪影（artifact），
    /// 而 SenseVoice 本身对噪声已相当鲁棒 —— 降噪有可能反而让字错误率上升。
    /// 因此它是"可对照、可验证的选项"，不是默认开启的"增强"。
    /// 原始音频始终保存，降噪只在转写时临时施加，随时可关掉重来。
    @Published var realtimeDenoiseEnabled: Bool {
        didSet { defaults.set(realtimeDenoiseEnabled, forKey: Keys.realtimeDenoise) }
    }

    /// LLM 纠错（识别 → 纠正 → 翻译 → 展示纠正文本）是否启用。默认**关**（2026-10-17 用户定：
    /// 0.5B 模型在 CPU 上偏慢，先聚焦「实时识别 + 实时翻译」主线，纠错作为可选增强按需开启）。
    ///
    /// ## 关闭 / 模型未下载时的降级
    /// 纠错是可选增强，不是核心链路的一环：开关关闭或纠错模型（Qwen2.5-0.5B）
    /// 尚未下载时，实时链路**自动退回**「识别原文直接翻译」，不会影响字幕与译文本身。
    /// 纠错模型需要单独下载（约 397 MB），下载入口在设置 →「模型」区。
    @Published var llmCorrectionEnabled: Bool {
        didSet { defaults.set(llmCorrectionEnabled, forKey: Keys.llmCorrection) }
    }

    /// 模型下载是否优先走镜像。
    /// 保留这个开关是因为交付环境实测存在 huggingface.co 不可达的情况，
    /// 而模型下不下来会直接让转写功能失效（见 ModelManager）。
    @Published var preferModelMirror: Bool {
        didSet { defaults.set(preferModelMirror, forKey: Keys.modelMirror) }
    }

    /// 首次使用时是否**自动**下载识别模型（SenseVoice）。
    ///
    /// 默认**开**。这条推翻了原先"一律由用户显式点击下载"的决定 ——
    /// 原因是真机验收暴露的事实：用户根本不知道该下哪个模型，
    /// 结果不是"省了流量"，而是**核心功能一直不可用**。
    @Published var autoPrepareModel: Bool {
        didSet { defaults.set(autoPrepareModel, forKey: Keys.autoPrepareModel) }
    }

    /// 自动下载是否允许走**移动网络**。默认**关**。
    ///
    /// 关闭时只在非计费网络（Wi-Fi / 有线）下自动下载。
    /// 理由：上百 MB 不该由 App 替用户决定花在移动流量上 ——
    /// 静默下载的边界必须止于"可能让用户多付钱"这一条。
    /// （SenseVoice 模型约 226 MB，这条边界因此更重要，而不是更不重要。）
    @Published var autoPrepareOnCellular: Bool {
        didSet { defaults.set(autoPrepareOnCellular, forKey: Keys.autoPrepareOnCellular) }
    }

    /// 学习语言。
    ///
    /// ## 「语言学习」功能已移除，但**这个属性必须保留**（2026-10-17）
    /// 它不再对应任何界面入口，唯一的用途是：首次启动时作为
    /// `liveTranslationTargetLanguage` 的兜底来源（见 init 里的 `storedLearningLanguage`）。
    /// 删掉它会连带拆掉那条初始化链 —— 而那条链**踩过"used before being initialized"
    /// 的坑、CI 编译失败过一次**，改动它的收益为零、风险不为零。
    @Published var learningLanguage: String {
        didSet { defaults.set(learningLanguage, forKey: Keys.learningLang) }
    }

    /// 默认翻译目标语言
    @Published var defaultTargetLanguage: String {
        didSet { defaults.set(defaultTargetLanguage, forKey: Keys.targetLang) }
    }

    /// 默认翻译源语言。
    ///
    /// **改为持久化，是为了修掉一个真实的重复劳动**：此前源语言是会话详情页的
    /// `@State`（每次进入都重置为 zh-Hans）。用户把它改成 en、退出去再进来，
    /// 又变回 zh-Hans —— 而"源语言与目标语言相同"是无效组合，界面还会就地纠正一次。
    /// 等于每次都要重选。持久化后只选一次。
    ///
    /// 打开会话详情时「源语言」的默认值（系统翻译不支持源语言自动判定，
    /// 必须显式指定一个）。
    @Published var defaultSourceLanguage: String {
        didSet { defaults.set(defaultSourceLanguage, forKey: Keys.sourceLang) }
    }

    /// 实时翻译的目标语言。**空字符串 = 关闭**。
    ///
    /// ## 默认值：跟随「我正在学」，即**默认开启**（2026-09-24 用户拍板）
    ///
    /// 初版是默认关闭，理由是"语言包必须先装好，否则用户会在录音刚开始那一刻
    /// 撞上系统下载界面"。**用户否掉了这个取舍**，理由更硬：
    /// 他要的是这个功能**默认就在**；缺语言包、正在下载这类状态，
    /// **在字幕下方直接告诉他**就行。
    ///
    /// 这个判断纠正了我两处错误：
    ///   1. 把"可能打断一次"当成关闭功能的理由 —— 而真正该做的是**把状态说清楚**
    ///   2. 又一次栽在同一类问题上：**默认关闭 ≈ 用户不知道它存在**
    ///      （真机反馈原话就是「没看到双语，只看到源语」）
    ///
    /// 初值取「我正在学」对应的翻译标识符（en → en，zh → zh-Hans）；
    /// 学习语言不在可翻译目录里时回落为空串（= 关闭）。
    /// 用户显式选过「关闭」时存的也是空串 —— 不会又被默认值顶回来
    /// （`?? 默认值` 只在从未存过值时生效）。
    @Published var liveTranslationTargetLanguage: String {
        didSet { defaults.set(liveTranslationTargetLanguage, forKey: Keys.liveTranslateTarget) }
    }

    /// 是否允许导出（会话文字稿）
    @Published var exportEnabled: Bool {
        didSet { defaults.set(exportEnabled, forKey: Keys.export) }
    }

    private init() {
        let rawSource = defaults.string(forKey: Keys.source) ?? CaptureSourceKind.microphone.rawValue
        captureSource = CaptureSourceKind(rawValue: rawSource) ?? .microphone

        let rawMode = defaults.string(forKey: Keys.mode) ?? "coexistent"
        sessionMode = (rawMode == "highFidelity") ? .highFidelity : .coexistent

        segmentSeconds = defaults.object(forKey: Keys.segmentSeconds) as? Int ?? 60
        // 旧安装里可能存着 64 kbps（当时设置页提供该项），升级后必须钳制，
        // 否则"设置已经改了"但用户仍然录不到音 —— 这是最难解释的一类问题。
        let storedBitRate = defaults.object(forKey: Keys.bitRate) as? Int ?? 32_000
        if storedBitRate > Self.maxBitRate {
            bitRate = 32_000
            defaults.set(32_000, forKey: Keys.bitRate)
            Log.shared.warn(
                .app,
                "落盘码率已钳制｜配置里是 \(storedBitRate / 1000)kbps，超过编码器上限"
                    + " \(Self.maxBitRate / 1000)kbps（16kHz 单声道）｜已回落到 32kbps"
            )
        } else {
            bitRate = storedBitRate
        }
        maxSessionHours = defaults.object(forKey: Keys.maxHours) as? Int ?? 12
        retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 7
        minFreeDiskGB = defaults.object(forKey: Keys.minFreeDiskGB) as? Double ?? 1.0

        realtimeTranscriptionEnabled = defaults.object(forKey: Keys.realtime) as? Bool ?? true
        // 默认 "auto"（用户 2026-09-24 确认）：理由见 transcriptionLanguage 的说明
        transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLang) ?? "auto"
        preferModelMirror = defaults.object(forKey: Keys.modelMirror) as? Bool ?? false
        autoPrepareModel = defaults.object(forKey: Keys.autoPrepareModel) as? Bool ?? true
        autoPrepareOnCellular = defaults.object(forKey: Keys.autoPrepareOnCellular) as? Bool ?? false
        realtimeDenoiseEnabled = defaults.object(forKey: Keys.realtimeDenoise) as? Bool ?? false
        // LLM 纠错默认关（2026-10-17 用户定：CPU 上 0.5B 慢，先聚焦实时识别+翻译主线）
        llmCorrectionEnabled = defaults.object(forKey: Keys.llmCorrection) as? Bool ?? false
        // 存成局部变量：下面的实时翻译默认值要用它，而**不能在 init 里直接读
        // learningLanguage 属性**（带 didSet 的属性被读会触发 definite-initialization
        // 检查，报 used before being initialized —— 见下方说明）
        let storedLearningLanguage = defaults.string(forKey: Keys.learningLang) ?? "en"
        learningLanguage = storedLearningLanguage
        // 用 zh-Hans 而不是 zh：系统翻译框架的语言标识符采用 BCP-47 形式，
        // 写 "zh" 时 LanguageAvailability 可能与目录里的条目对不上
        defaultTargetLanguage = defaults.string(forKey: Keys.targetLang) ?? "zh-Hans"
        // 与 SessionListView 此前的默认值保持一致（zh-Hans），不改变既有行为
        defaultSourceLanguage = defaults.string(forKey: Keys.sourceLang) ?? "zh-Hans"
        // 实时翻译默认**开启**、目标取「我正在学」（2026-09-24 用户拍板）：
        // 理由见 liveTranslationTargetLanguage 的说明。
        //
        // ⚠️ 这两行**必须这么写**。第一版写成链式表达式：
        //      liveTranslationTargetLanguage = defaults.string(...) 
        //          ?? TranslationLanguageCatalog.identifier(forWhisperCode: learningLanguage)
        //          ?? ""
        //    CI 直接编译失败，报的是：
        //      variable 'self.liveTranslationTargetLanguage' used before being initialized
        //    原因是两条叠在一起：① 在 init 里读**带 didSet 的属性**（learningLanguage）；
        //    ② 多行 ?? 长链。改法就是拆成局部变量、只赋值一次。
        //    **而本机 linter 对这个问题一个字都没报** —— 见日志里的教训：
        //    Swift 的语言语义错误只有 CI 才是真检查，"零 lint"不等于"能编译"。
        let liveTargetFallback = TranslationLanguageCatalog.identifier(
            forWhisperCode: storedLearningLanguage
        ) ?? ""
        liveTranslationTargetLanguage = defaults.string(forKey: Keys.liveTranslateTarget)
            ?? liveTargetFallback
        exportEnabled = defaults.object(forKey: Keys.export) as? Bool ?? true
    }

    /// 一行摘要，供日志与设置页展示（排查"当时用的是哪套参数"时非常有用）。
    func summary() -> String {
        "源=\(captureSource.rawValue)"
            + "｜会话模式=\(sessionMode.title)"
            + "｜分片=\(segmentSeconds)s"
            + "｜码率=\(bitRate / 1000)kbps"
            + "｜上限=\(maxSessionHours)h"
            + "｜音频保留=\(retentionDays)天"
            + "｜磁盘下限=\(minFreeDiskGB)GB"
    }

    private enum Keys {
        static let source = "moments.capture.source"
        static let mode = "moments.capture.sessionMode"
        static let segmentSeconds = "moments.capture.segmentSeconds"
        static let bitRate = "moments.capture.bitRate"
        static let maxHours = "moments.capture.maxSessionHours"
        static let retentionDays = "moments.storage.retentionDays"
        static let minFreeDiskGB = "moments.storage.minFreeDiskGB"
        static let realtime = "moments.asr.realtimeEnabled"
        static let transcriptionLang = "moments.asr.language"
        static let modelMirror = "moments.model.preferMirror"
        static let autoPrepareModel = "moments.model.autoPrepare"
        static let autoPrepareOnCellular = "moments.model.autoPrepareOnCellular"
        static let realtimeDenoise = "moments.asr.realtimeDenoise"
        static let llmCorrection = "moments.asr.llmCorrection"
        static let learningLang = "moments.lang.learning"
        static let targetLang = "moments.lang.target"
        static let sourceLang = "moments.lang.source"
        static let liveTranslateTarget = "moments.translate.liveTarget"
        static let export = "moments.export.enabled"
    }
}
