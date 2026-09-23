import Foundation
import Translation

/// 可选的目标语言。
///
/// 刻意只列常用的几门，而不是把系统支持的全部语言摆出来：
/// 选择过多会让用户无法决策，而"能翻成哪些语言"恰恰是最不该让人操心的事。
/// 真正的可用性仍以**运行时查询**为准（见 TranslationService.availability）。
struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

enum TranslationLanguageCatalog {

    static let all: [TranslationLanguage] = [
        TranslationLanguage(code: "zh-Hans", name: "中文（简体）"),
        TranslationLanguage(code: "zh-Hant", name: "中文（繁体）"),
        TranslationLanguage(code: "en", name: "英语"),
        TranslationLanguage(code: "ja", name: "日语"),
        TranslationLanguage(code: "ko", name: "韩语"),
        TranslationLanguage(code: "fr", name: "法语"),
        TranslationLanguage(code: "de", name: "德语"),
        TranslationLanguage(code: "es", name: "西班牙语"),
        TranslationLanguage(code: "ru", name: "俄语")
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }

    static var identifiers: [String] { all.map { $0.code } }
}

/// 转写文本的呈现方式（设计文档 8.2 的三档显示模式）。
enum TranscriptDisplayMode: String, CaseIterable {
    /// 只看原文：复习原话、专注听
    case original
    /// 双语对照（默认）：语言学习的主场景
    case bilingual
    /// 只看译文：快速理解内容
    case translation

    var title: String {
        switch self {
        case .original: return "原文"
        case .bilingual: return "双语"
        case .translation: return "译文"
        }
    }

    var showsOriginal: Bool { self != .translation }
    var showsTranslation: Bool { self != .original }
}

/// 翻译任务的阶段。
enum TranslationStage: Equatable {
    case idle
    case preparing
    case translating
    case done
    case cancelled
    case failed(String)

    var text: String {
        switch self {
        case .idle: return "空闲"
        case .preparing: return "正在准备语言包…"
        case .translating: return "正在翻译…"
        case .done: return "已完成"
        case .cancelled: return "已取消（已翻部分保留）"
        case .failed(let message): return "失败：\(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .translating: return true
        default: return false
        }
    }
}

/// 翻译层（M5）。
///
/// ## 为什么用 SwiftUI 的 `translationTask` 而不是自己建 TranslationSession
/// 系统翻译框架有两条路：
///   · `init(installedSource:target:)` —— 无 UI 场景，**但要求语言包已安装**，
///     且初始化器签名在不同版本间有差异；
///   · `.translationTask(configuration)` —— SwiftUI 修饰器，由系统给出 session。
/// 本项目的翻译本来就是"用户在会话详情页点一下"触发，页面一定在屏上，
/// 所以走第二条：**不依赖不确定的初始化器签名，且语言包未装时能弹出系统下载界面**
/// （这一点很关键：语言包首次使用需要联网下载，纯后台路径无法引导用户完成）。
///
/// ## 请求 → 视图消费 的两段式设计
/// `requestTranslation` 只负责**准备请求并把 configuration 交给视图**；
/// 真正的翻译在 `.translationTask` 的 action 里由 `execute(with:)` 执行。
/// 这个看起来绕的结构，是因为 session 只能由视图拿到 —— 与其和框架对抗，
/// 不如把这个约束显式地表达在接口形状上。
@MainActor
final class TranslationService: ObservableObject {

    static let shared = TranslationService()

    @Published private(set) var stage: TranslationStage = .idle
    @Published private(set) var message: String?
    @Published private(set) var completedSegments = 0
    @Published private(set) var totalSegments = 0
    /// 交给视图的 configuration。非 nil 时，视图上的 `.translationTask` 会开始工作。
    @Published private(set) var configuration: TranslationSession.Configuration?

    /// 当前正在翻译哪次会话的哪种语言（界面据此显示进度）
    @Published private(set) var runningSessionId: String?
    @Published private(set) var runningTargetLanguage: String?

    private struct PendingRequest {
        let sessionId: String
        /// 源语言。**必须指定**：系统翻译的语言可用性查询与配置都要求给出源语言，
        /// 不支持"源语言自动判定"（这与 whisper 的识别不同，那里可以自动判）。
        let source: String
        let target: String
        let pass: TranscriptPass
        /// 需要翻译的片段（已扣掉缓存命中的部分）
        let missing: [TranscriptSegment]
    }

    private var pending: PendingRequest?

    /// 引擎标识与版本。**版本参与缓存键**：
    /// 将来若把引擎换成本地小 LLM，旧译文能被识别出来并重翻，
    /// 而不是悄悄继续用质量较低的旧结果。
    static let engineIdentifier = "system-translation"
    static let engineVersion = "ios18"

    /// 每批提交多少句。
    /// 分批不是为了框架（它自己会批处理），而是为了**进度可见 + 逐批落盘**：
    /// 一次几百句的长会话若中途失败，已翻好的部分不该丢。
    private let batchSize = 40

    private init() {}

    var isBusy: Bool { stage.isActive }

    var progress: Double {
        guard totalSegments > 0 else { return 0 }
        return min(1.0, Double(completedSegments) / Double(totalSegments))
    }

    // MARK: - 可用性（前置校验）

    /// 查询语言对是否可用。
    ///
    /// **必须前置校验**：系统翻译的语言对是有限的，而且语言包需要单独下载。
    /// 不查就翻，用户会得到"点了没反应"，那是最糟的失败方式（设计文档 7.4）。
    ///
    /// 注意：`status(from:to:)` 的两个参数都是**非可选**的，
    /// 系统不支持"源语言自动判定" —— 因此源语言必须由调用方给定。
    func availability(from source: String, to target: String) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return await availability.status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
    }

    /// 把状态翻译成用户能看懂的话，并明确**下一步该做什么**。
    /// 只说"不可用"而不说怎么办，等于把问题丢回给用户。
    static func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed:
            return "已就绪"
        case .supported:
            return "需下载语言包"
        case .unsupported:
            return "系统不支持该语言对"
        @unknown default:
            return "状态未知"
        }
    }

    // MARK: - 发起翻译

    /// 用户点了「翻译」。
    /// - Parameter existing: 已缓存的（segmentId → 译文），用来跳过已翻好的句子
    func requestTranslation(
        sessionId: String,
        source: String,
        target: String,
        pass: TranscriptPass,
        segments: [TranscriptSegment],
        existing: [String: String]
    ) {
        guard !isBusy else {
            message = "已有翻译任务在进行中"
            return
        }

        let missing = segments.filter { segment in
            guard let cached = existing[segment.id] else { return true }
            return cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        guard !missing.isEmpty else {
            stage = .done
            message = "这一稿的 \(TranslationLanguageCatalog.name(for: target)) 译文已全部存在，无需重翻"
            return
        }

        runningSessionId = sessionId
        runningTargetLanguage = target
        totalSegments = missing.count
        completedSegments = 0
        message = "准备翻译 \(missing.count) 句 → \(TranslationLanguageCatalog.name(for: target))"
        stage = .preparing

        pending = PendingRequest(
            sessionId: sessionId,
            source: source,
            target: target,
            pass: pass,
            missing: missing
        )

        // 源语言必须显式给出（系统不提供自动判定）。
        // 这一点与 whisper 的识别不同 —— 那里可以自动判语言，这里不行，
        // 所以界面必须让用户选源语言，而不是假装它自己知道。
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
    }

    func cancel() {
        pending = nil
        configuration = nil
        runningSessionId = nil
        runningTargetLanguage = nil
        stage = .cancelled
        message = "已取消翻译"
        Log.shared.info(.translate, "翻译已取消")
    }

    /// 由视图的 `.translationTask` 调用。
    func execute(with session: TranslationSession) async {
        guard let request = pending else { return }

        // 语言包未安装时这一步会弹出系统下载界面；已安装时几乎立即返回。
        // **必须先做**：未准备就翻译会直接抛错，而错误信息对用户毫无指导意义。
        do {
            try await session.prepareTranslation()
        } catch {
            finish(state: .failed("语言包未就绪（\(error.localizedDescription)）"), request: request)
            return
        }

        stage = .translating
        var index = 0

        while index < request.missing.count {
            if Task.isCancelled {
                finish(state: .cancelled, request: request)
                return
            }

            let upper = min(index + batchSize, request.missing.count)
            let chunk = Array(request.missing[index..<upper])
            let requests = chunk.map {
                TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
            }

            do {
                let responses = try await session.translations(from: requests)
                var batch: [String: String] = [:]
                for response in responses {
                    guard let identifier = response.clientIdentifier else { continue }
                    batch[identifier] = response.targetText
                }
                if !batch.isEmpty {
                    // 逐批落盘：长会话中途失败时，已翻好的部分必须留住
                    let result = TranslationStore.shared.merge(
                        sessionId: request.sessionId,
                        targetLang: request.target,
                        pass: request.pass,
                        translations: batch,
                        engine: Self.engineIdentifier,
                        engineVersion: Self.engineVersion
                    )
                    if result.keptManual > 0 {
                        Log.shared.info(.translate, "保留了 \(result.keptManual) 条人工修正的译文")
                    }
                }
            } catch {
                // 一批失败不中断整次翻译：继续下一批，最后如实报告
                Log.shared.warn(
                    .translate,
                    "一批翻译失败｜第 \(index + 1)~\(upper) 句｜\(error.localizedDescription)"
                )
            }

            completedSegments = upper
            index = upper
        }

        finish(state: .done, request: request)
    }

    // MARK: - 内部

    private func finish(state: TranslationStage, request: PendingRequest) {
        stage = state
        pending = nil
        configuration = nil
        runningSessionId = nil
        runningTargetLanguage = nil

        switch state {
        case .done:
            message = "翻译完成｜\(request.missing.count) 句 → \(TranslationLanguageCatalog.name(for: request.target))"
            // 译文的最终落盘在 TranslationStore.merge 里已逐批完成，这里只刷新检索索引
            SearchIndex.shared.index(sessionId: request.sessionId)
        case .cancelled:
            message = "已取消翻译（已翻部分保留）"
        case .failed(let reason):
            message = reason
        default:
            break
        }
        Log.shared.info(.translate, message ?? state.text)
    }
}
