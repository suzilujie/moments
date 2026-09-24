import Foundation

/// whisper.cpp 的 ggml 模型描述。
///
/// ## 为什么模型要下载而不是打包（设计文档 5.5 / 1.3 事实四）
///   · 蜂窝网络下载安装包上限 200 MB，而 small 以上模型单个就接近或超过这个量级；
///   · 打包会让部分用户在蜂窝下**根本装不上**，这不是取舍而是硬限制；
///   · 因此模型一律运行时下载到 `Application Support/Moments/Models/`。
///
/// 本文件只描述「有哪些模型、各自多大、用来干什么」，下载与校验在 `ModelManager`。
struct WhisperModelDescriptor: Identifiable, Hashable {

    /// 模型在链路中的用途。设计文档 5.4 的「两遍转写」用不同模型：
    /// 实时稿求快、终稿求准 —— 这是本项目能耗与体验的核心取舍。
    enum Role: String, Codable {
        /// 录音过程中出实时字幕
        case realtime
        /// 事后补跑，作为留档（准确率优先）
        case final
        /// **两用**（2026-09-24 新增）。
        ///
        /// Small 原先只作终稿，理由是"实时求快"。真机实测推翻了这条前提：
        /// Base 的实时倍率是 **0.03**（快于实时约 33 倍），余量足够放更准的模型。
        /// 而实时字幕最被诟病的一点恰恰是「Base 中文错字较多」——
        /// 用"快 33 倍"换掉准确率，等于拿一个用不完的资源去换一个天天被感知的短板。
        case both

        /// 可用于实时字幕
        var canRealtime: Bool { self != .final }
        /// 可用于终稿
        var canFinal: Bool { self != .realtime }

        /// 给用户看的**用途**名。
        ///
        /// 存在的理由是真机验收的一句反馈：「用户可能根本不知道这几个模型是干嘛用的」。
        /// Tiny / Base / Small / Medium 是发布方的内部命名，对用户没有任何含义 ——
        /// 界面上必须写清楚"它是用来干什么的"，而不是让用户去推理型号大小。
        var purposeTitle: String {
            switch self {
            case .realtime: return "录音时出实时字幕"
            case .final: return "事后转成准确文字"
            case .both: return "实时字幕与终稿都能用"
            }
        }
    }

    let id: String
    let displayName: String
    let fileName: String
    /// 近似体积，仅用于界面展示与磁盘预检；**不用于校验**（见 ModelManager）
    let approximateBytes: Int64
    let role: Role
    let speedHint: String
    let accuracyHint: String
    let note: String
}

extension WhisperModelDescriptor {

    /// 官方模型仓库（ggerganov/whisper.cpp）的固定下载地址。
    var primaryURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    /// 国内镜像地址。
    ///
    /// 存在的理由很实际、不是过度设计：本项目交付依赖 GitHub 推送，
    /// 而实测中已多次遇到 github.com / huggingface.co 不可达的情况
    /// （见工作日志「阶段十一」）。既然音频转写是这个 App 的核心能力，
    /// 就不该让"模型下不下来"成为不可绕过的单点。
    var mirrorURL: URL {
        URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }

    /// 量化标记（q5_0 / q5_1）—— 保留可选信息用途：
    /// 用户看到 "q5" 能知道这是压缩过的版本，避免把它当成"模型缺斤少两"。
    var quantizationText: String {
        guard let range = fileName.range(of: "q5_", options: .backwards) else { return "原始精度" }
        return String(fileName[range.lowerBound...]).replacingOccurrences(of: ".bin", with: "")
    }
}

/// 模型清单。**只列经过权衡的几个**，而不是把 whisper.cpp 全部尺寸都摆出来 ——
/// 选项过多会让用户无法决策，而"选哪个"恰恰是这里最不该让用户操心的事。
///
/// ## ⚠️ 文件名必须与上游逐字一致，而上游的量化命名**并不统一**（2026-09-24 真机教训）
///
/// 上游 `ggerganov/whisper.cpp` 里**实际存在**的量化文件是：
///   · tiny   → `ggml-tiny-q5_1.bin`     （32,152,673 字节）
///   · base   → `ggml-base-q5_1.bin`     （59,707,625 字节）
///   · small  → `ggml-small-q5_1.bin`    （190,085,487 字节）
///   · medium → `ggml-medium-q5_0.bin`   （539,212,467 字节）← **只有它叫 q5_0**
///
/// 即 base / small **根本没有 q5_0 版本**。本项目最初写的
/// `ggml-base-q5_0.bin` / `ggml-small-q5_0.bin` 在上游不存在，服务器返回 404，
/// 正文是 15 字节的 `Entry not found` —— 而该正文会被 URLSession 当作
/// "下载成功"存成模型文件，最终以「体积异常（可能被网络中间层截断）」报错，
/// 与真实原因完全不符（真机验收就是这么被误导的）。
///
/// **改这里之前必须先查上游真实文件名，不要按 q5_0 / q5_1 的规律类推。**
enum WhisperModelCatalog {

    /// 实时稿默认模型：small 量化版（**2026-09-24 由 base 改为 small**）。
    ///
    /// ## 为什么改
    /// 原选 base 的理由是"要快"。真机实测（概念文档 P23）把这个前提推翻了：
    /// base 平均 440ms / 15 秒音频 = **实时倍率 0.03，快于实时约 33 倍**。
    /// 也就是说我们一直在为一个**不存在的**性能问题付准确率的代价，
    /// 而 base 的中文错字多（本文件里就标注着"中文错字较多"）是天天被感知的短板。
    /// 按参数量推算 small 约 0.10，仍快于实时近 10 倍。
    ///
    /// ## 必须知道的连带影响
    /// **首次使用自动准备下载的就是它**（见 `ModelManager.autoPrepareIfNeeded`）——
    /// 所以静默下载的体量从 57 MB 变成 **190 MB**（仍只在 Wi-Fi 下，
    /// 除非用户另外打开「允许在移动网络下自动下载」）。
    /// **静默下载的体量变了，这是本次改动的代价之一，不是附带细节。**
    ///
    /// 若哪天真机发热明显，改回 `"base-q5_1"` 或让用户切到 Base 即可（设置里可选）。
    static let realtimeDefaultId = "small-q5_1"

    /// 终稿默认模型：small 量化版。准确率明显优于 base，且可在充电/息屏时慢慢跑，
    /// 速度不是约束（设计文档 5.4）。
    static let finalDefaultId = "small-q5_1"

    static let all: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(
            id: "tiny-q5_1",
            displayName: "Tiny",
            fileName: "ggml-tiny-q5_1.bin",
            approximateBytes: 32_150_000,
            role: .realtime,
            speedHint: "最快",
            accuracyHint: "一般（中文错字较多）",
            note: "仅在设备过热或电量极低时作为兜底档使用，不建议日常选它"
        ),
        WhisperModelDescriptor(
            id: "base-q5_1",
            displayName: "Base",
            fileName: "ggml-base-q5_1.bin",
            approximateBytes: 59_700_000,
            role: .realtime,
            speedHint: "快于实时",
            accuracyHint: "日常对话可用",
            // 2026-09-24：它不再是默认（默认已改为 Small）。保留为"省电档"——
            // 发热明显或想省电时切到它，代价是中文错字变多。
            note: "省电档：速度余量最大（实测快于实时约 33 倍），但中文准确率一般"
        ),
        WhisperModelDescriptor(
            id: "small-q5_1",
            displayName: "Small",
            fileName: "ggml-small-q5_1.bin",
            approximateBytes: 190_100_000,
            // 2026-09-24：改为两用 —— 实时字幕的默认也用它（实测余量足够，见 realtimeDefaultId）
            role: .both,
            speedHint: "接近实时",
            accuracyHint: "好",
            note: "实时与终稿都能用：中文明显比 Base 准；实时下约慢 3 倍，但仍有近 10 倍余量"
        ),
        WhisperModelDescriptor(
            id: "medium-q5_0",
            displayName: "Medium",
            fileName: "ggml-medium-q5_0.bin",
            approximateBytes: 539_200_000,
            role: .final,
            speedHint: "慢于实时",
            accuracyHint: "很好",
            note: "适合夜间充电时补跑重要会话；体积较大，占用存储明显"
        )
    ]

    static func model(id: String) -> WhisperModelDescriptor? {
        all.first { $0.id == id }
    }

    static var realtimeCandidates: [WhisperModelDescriptor] {
        all.filter { $0.role.canRealtime }
    }

    static var finalCandidates: [WhisperModelDescriptor] {
        all.filter { $0.role.canFinal }
    }

    /// 识别语言候选。
    ///
    /// 注意这里的取舍：**默认「自动判定」而不是强制指定**。
    /// 强制指定中英之一，会让中英夹杂的对话里另一种语言被强行"翻译"成错误文本。
    ///
    /// **但"自动判定"必须锁定，否则比强制指定更糟**（2026-09-24 真机教训）。
    /// whisper 的语言判定是**按窗口独立做的**，而实时字幕每 5 秒就要重解最近 15 秒 ——
    /// 每个窗口各自判一次的结果，就是同一段对话里语言来回跳，
    /// 用户看到的是「实时识别有的扯淡，出现各种语言」。
    /// 实现因此改为：首个出字窗口判一次、之后锁定沿用
    ///（见 `LiveTranscriptionEngine.pinLanguageIfNeeded`），
    /// 并在录音页把锁定结果显示出来、允许一键更改。
    ///
    /// 原先这里写的"whisper 的自动判定在这种场景下反而更稳"是**未经验证的假设**，
    /// 已被真机推翻 —— 留在这里是为了说明它为什么不能退回原来的写法。
    static let languageOptions: [(code: String, name: String)] = [
        ("auto", "自动判定"),
        ("zh", "中文"),
        ("en", "英语"),
        ("yue", "粤语"),
        ("ja", "日语"),
        ("ko", "韩语")
    ]

    static func languageName(_ code: String) -> String {
        languageOptions.first { $0.code == code }?.name ?? code
    }
}
