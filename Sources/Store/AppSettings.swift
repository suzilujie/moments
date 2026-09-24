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
    @Published var bitRate: Int {
        didSet { defaults.set(bitRate, forKey: Keys.bitRate) }
    }

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

    /// 实时字幕使用的模型（默认 base —— 速度与准确率的平衡点，见 WhisperModelCatalog）
    @Published var realtimeModelId: String {
        didSet { defaults.set(realtimeModelId, forKey: Keys.realtimeModel) }
    }

    /// 终稿使用的模型（默认 small —— 准确优先，跑在闲置时段，速度不是约束）
    @Published var finalModelId: String {
        didSet { defaults.set(finalModelId, forKey: Keys.finalModel) }
    }

    /// 转写语言。取值见 `WhisperModelCatalog.languageOptions`，**默认 "auto"（自动判定）**。
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
    /// 而 whisper 本身对噪声已相当鲁棒 —— 降噪有可能反而让字错误率上升。
    /// 因此它是"可对照、可验证的选项"，不是默认开启的"增强"。
    /// 原始音频始终保存，降噪只在转写时临时施加，随时可关掉重来。
    @Published var realtimeDenoiseEnabled: Bool {
        didSet { defaults.set(realtimeDenoiseEnabled, forKey: Keys.realtimeDenoise) }
    }

    /// 模型下载是否优先走镜像。
    /// 保留这个开关是因为交付环境实测存在 huggingface.co 不可达的情况，
    /// 而模型下不下来会直接让转写功能失效（见 ModelManager）。
    @Published var preferModelMirror: Bool {
        didSet { defaults.set(preferModelMirror, forKey: Keys.modelMirror) }
    }

    /// 首次使用时是否**自动**下载默认的实时模型（Base）。
    ///
    /// 默认**开**。这条推翻了原先"一律由用户显式点击下载"的决定 ——
    /// 原因是真机验收暴露的事实：用户面对 Tiny/Base/Small/Medium 四个名字
    /// 根本不知道该下哪个，结果不是"省了流量"，而是**核心功能一直不可用**
    ///（设备日志里 32 分钟零字节，界面也没有任何进度）。
    @Published var autoPrepareModel: Bool {
        didSet { defaults.set(autoPrepareModel, forKey: Keys.autoPrepareModel) }
    }

    /// 自动下载是否允许走**移动网络**。默认**关**。
    ///
    /// 关闭时只在非计费网络（Wi-Fi / 有线）下自动下载。
    /// 理由：上百 MB 不该由 App 替用户决定花在移动流量上 ——
    /// 静默下载的边界必须止于"可能让用户多付钱"这一条。
    /// （2026-09-24 默认实时模型改为 Small 后，静默下载体量由 57 MB 变为 190 MB，
    ///   这条边界因此更重要，而不是更不重要。）
    @Published var autoPrepareOnCellular: Bool {
        didSet { defaults.set(autoPrepareOnCellular, forKey: Keys.autoPrepareOnCellular) }
    }

    /// 正在学习的语言（用户已确认为英语）
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
    /// TTS 读原文也需要这个值：系统合成语音必须显式指定语言，
    /// 否则会用默认语音把中文按英文读出来（见 SpeechReader）。
    @Published var defaultSourceLanguage: String {
        didSet { defaults.set(defaultSourceLanguage, forKey: Keys.sourceLang) }
    }

    /// 实时翻译的目标语言。**空字符串 = 关闭**（默认）。
    ///
    /// ## 为什么默认关闭，而不是默认跟随"我正在学"
    /// 实时翻译要在录音过程中额外调用系统翻译，而且**语言包必须预先装好**
    ///（系统只在 prepareTranslation 时弹下载界面，那要求页面在屏上）。
    /// 默认打开的话，没准备语言包的用户会在**录音刚开始时**撞上系统下载弹窗 ——
    /// 那是在最不该打断他的时刻打断他。
    ///
    /// 要用的人在设置 →「语言」里选一次即可：那里同时显示语言包状态、
    /// 并提供一个当场装好的入口（`TranslationService.prepareLanguagePack`）。
    @Published var liveTranslationTargetLanguage: String {
        didSet { defaults.set(liveTranslationTargetLanguage, forKey: Keys.liveTranslateTarget) }
    }

    /// 生词判定的水平档（设计文档 8.5：按用户自选水平调整分数线）
    @Published var vocabularyLevel: VocabularyLevel {
        didSet { defaults.set(vocabularyLevel.rawValue, forKey: Keys.vocabLevel) }
    }

    /// 是否允许导出（生词本 / 会话文本）
    @Published var exportEnabled: Bool {
        didSet { defaults.set(exportEnabled, forKey: Keys.export) }
    }

    private init() {
        let rawSource = defaults.string(forKey: Keys.source) ?? CaptureSourceKind.microphone.rawValue
        captureSource = CaptureSourceKind(rawValue: rawSource) ?? .microphone

        let rawMode = defaults.string(forKey: Keys.mode) ?? "coexistent"
        sessionMode = (rawMode == "highFidelity") ? .highFidelity : .coexistent

        segmentSeconds = defaults.object(forKey: Keys.segmentSeconds) as? Int ?? 60
        bitRate = defaults.object(forKey: Keys.bitRate) as? Int ?? 32_000
        maxSessionHours = defaults.object(forKey: Keys.maxHours) as? Int ?? 12
        retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 7
        minFreeDiskGB = defaults.object(forKey: Keys.minFreeDiskGB) as? Double ?? 1.0

        realtimeTranscriptionEnabled = defaults.object(forKey: Keys.realtime) as? Bool ?? true
        // 模型 id 会随上游文件名变化（2026-09-24：base-q5_0 → base-q5_1，
        // 因为上游根本没有 q5_0 那个文件）。存下来的旧 id 若已不在清单里，
        // 必须回落到默认值 —— 否则会留下"设置里记着某模型、清单里查不到"的状态：
        // 界面表现为「模型目录不可用」，而且用户自己无法恢复（下哪个都不对）。
        realtimeModelId = Self.resolveModelId(
            stored: defaults.string(forKey: Keys.realtimeModel),
            fallback: WhisperModelCatalog.realtimeDefaultId
        )
        finalModelId = Self.resolveModelId(
            stored: defaults.string(forKey: Keys.finalModel),
            fallback: WhisperModelCatalog.finalDefaultId
        )
        // 默认 "auto"（用户 2026-09-24 确认）：理由见 transcriptionLanguage 的说明
        transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLang) ?? "auto"
        preferModelMirror = defaults.object(forKey: Keys.modelMirror) as? Bool ?? false
        autoPrepareModel = defaults.object(forKey: Keys.autoPrepareModel) as? Bool ?? true
        autoPrepareOnCellular = defaults.object(forKey: Keys.autoPrepareOnCellular) as? Bool ?? false
        realtimeDenoiseEnabled = defaults.object(forKey: Keys.realtimeDenoise) as? Bool ?? false
        learningLanguage = defaults.string(forKey: Keys.learningLang) ?? "en"
        // 用 zh-Hans 而不是 zh：系统翻译框架的语言标识符采用 BCP-47 形式，
        // 写 "zh" 时 LanguageAvailability 可能与目录里的条目对不上
        defaultTargetLanguage = defaults.string(forKey: Keys.targetLang) ?? "zh-Hans"
        // 与 SessionListView 此前的默认值保持一致（zh-Hans），不改变既有行为
        defaultSourceLanguage = defaults.string(forKey: Keys.sourceLang) ?? "zh-Hans"
        // 实时翻译默认**关闭**（空串）：理由见 liveTranslationTargetLanguage 的说明
        liveTranslationTargetLanguage = defaults.string(forKey: Keys.liveTranslateTarget) ?? ""
        let rawLevel = defaults.string(forKey: Keys.vocabLevel) ?? ""
        vocabularyLevel = VocabularyLevel(rawValue: rawLevel) ?? .fallback
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

    /// 把存储的模型 id 解析成清单里**真实存在**的 id（不存在则回落默认）。
    private static func resolveModelId(stored: String?, fallback: String) -> String {
        guard let stored, WhisperModelCatalog.model(id: stored) != nil else { return fallback }
        return stored
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
        static let realtimeModel = "moments.asr.realtimeModel"
        static let finalModel = "moments.asr.finalModel"
        static let transcriptionLang = "moments.asr.language"
        static let modelMirror = "moments.model.preferMirror"
        static let autoPrepareModel = "moments.model.autoPrepare"
        static let autoPrepareOnCellular = "moments.model.autoPrepareOnCellular"
        static let realtimeDenoise = "moments.asr.realtimeDenoise"
        static let learningLang = "moments.lang.learning"
        static let targetLang = "moments.lang.target"
        static let sourceLang = "moments.lang.source"
        static let liveTranslateTarget = "moments.translate.liveTarget"
        static let vocabLevel = "moments.learn.vocabularyLevel"
        static let export = "moments.export.enabled"
    }
}
