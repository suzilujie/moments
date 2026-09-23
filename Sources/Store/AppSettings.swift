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

    /// 正在学习的语言（用户已确认为英语）
    @Published var learningLanguage: String {
        didSet { defaults.set(learningLanguage, forKey: Keys.learningLang) }
    }

    /// 默认翻译目标语言
    @Published var defaultTargetLanguage: String {
        didSet { defaults.set(defaultTargetLanguage, forKey: Keys.targetLang) }
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
        learningLanguage = defaults.string(forKey: Keys.learningLang) ?? "en"
        defaultTargetLanguage = defaults.string(forKey: Keys.targetLang) ?? "zh"
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
        static let learningLang = "moments.lang.learning"
        static let targetLang = "moments.lang.target"
        static let export = "moments.export.enabled"
    }
}
