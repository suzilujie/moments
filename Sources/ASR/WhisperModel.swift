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
enum WhisperModelCatalog {

    /// 实时稿默认模型：base 量化版。选择理由：在 iPhone 上能跑出快于实时的速度，
    /// 中文可用；tiny 虽更快但中文错字明显，做实时字幕会让人误以为识别很差。
    static let realtimeDefaultId = "base-q5_0"

    /// 终稿默认模型：small 量化版。准确率明显优于 base，且可在充电/息屏时慢慢跑，
    /// 速度不是约束（设计文档 5.4）。
    static let finalDefaultId = "small-q5_0"

    static let all: [WhisperModelDescriptor] = [
        WhisperModelDescriptor(
            id: "tiny-q5_1",
            displayName: "Tiny",
            fileName: "ggml-tiny-q5_1.bin",
            approximateBytes: 31_000_000,
            role: .realtime,
            speedHint: "最快",
            accuracyHint: "一般（中文错字较多）",
            note: "仅在设备过热或电量极低时作为兜底档使用，不建议日常选它"
        ),
        WhisperModelDescriptor(
            id: "base-q5_0",
            displayName: "Base",
            fileName: "ggml-base-q5_0.bin",
            approximateBytes: 57_000_000,
            role: .realtime,
            speedHint: "快于实时",
            accuracyHint: "日常对话可用",
            note: "实时字幕的默认选择：速度与准确率的平衡点"
        ),
        WhisperModelDescriptor(
            id: "small-q5_0",
            displayName: "Small",
            fileName: "ggml-small-q5_0.bin",
            approximateBytes: 181_000_000,
            role: .final,
            speedHint: "接近实时",
            accuracyHint: "好",
            note: "终稿的默认选择：事后补跑，不占用使用时段"
        ),
        WhisperModelDescriptor(
            id: "medium-q5_0",
            displayName: "Medium",
            fileName: "ggml-medium-q5_0.bin",
            approximateBytes: 539_000_000,
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
        all.filter { $0.role == .realtime }
    }

    static var finalCandidates: [WhisperModelDescriptor] {
        all.filter { $0.role == .final }
    }

    /// 识别语言候选。
    ///
    /// 注意这里的取舍：**默认「自动判定」而不是强制指定**。
    /// 强制指定中英之一，会让中英夹杂的对话里另一种语言被强行"翻译"成错误文本；
    /// 而 whisper 的自动判定在这种场景下反而更稳（设计文档 7.5 逐段语言检测的前提）。
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
