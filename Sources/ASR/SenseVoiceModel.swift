import Foundation

/// SenseVoice 模型描述（M6）。
///
/// ## 为什么是「单模型」而不是 whisper 的「多档模型」
/// whisper 有 tiny/base/small/medium 四档，是因为它按参数量分档、实时与终稿各选一个。
/// SenseVoice 只有一个 int8 量化版（约 226 MiB），中文准确率已经高于 whisper medium，
/// 因此**实时字幕与终稿共用同一个模型** —— 不再有「实时求快、终稿求准」的两套模型，
/// 也就删掉了「该下哪个模型」这类用户无法决策的问题（那是 whisper 时代的固有代价）。
///
/// ## 为什么模型运行时下载、tokens 随包内置（刻意拆成两半）
///   · 模型 `model.int8.onnx` 约 226 MiB，超过蜂窝下载 200 MB 上限 —— 打进包会让
///     部分用户在蜂窝下**装不上**（这是硬限制，见设计文档 5.5 / 1.3），故运行时下载；
///   · `tokens.txt` 仅约 308 KB，随包内置（CI 下载到 Resources/SherpaModels/），
///     识别器的词表**永久可用、不依赖网络**；模型与 tokens 的版本由仓库名固定配对，
///     因此「内置 tokens + 下载模型」不会出现版本错配。
enum SenseVoiceModel {

    /// 模型 id。写进 `TranscriptDocument.modelId` 与日志，替代 whisper 的型号 id。
    static let id = "sensevoice"

    static let displayName = "SenseVoice"

    /// 运行时下载的模型文件名。
    static let modelFileName = "model.int8.onnx"

    /// 随包内置的 tokens 文件名。
    static let tokensFileName = "tokens.txt"

    /// 近似体积（仅用于界面展示与磁盘预检，**不用于校验**；校验用「体积下界 + 加载时验证」）。
    static let approximateBytes: Int64 = 237_115_547

    /// 模型仓库（固定 tag，模型与 tokens 从此配对下载）。
    private static let repo = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"

    /// 主站下载地址（模型文件）。
    static var primaryURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(modelFileName)")!
    }

    /// 国内镜像地址。与 whisper 时代同一条教训：交付环境实测 huggingface.co 不可达，
    /// 模型下不下来会让核心功能失效，因此必须有一条回退路。
    static var mirrorURL: URL {
        URL(string: "https://hf-mirror.com/\(repo)/resolve/main/\(modelFileName)")!
    }

    static var sizeText: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }

    /// 包内 tokens 文件的路径（不存在返回 nil，由调用方明确提示）。
    static var bundledTokensURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(tokensFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 语言

    /// 识别语言候选。与 whisper 时代的 `WhisperModelCatalog.languageOptions` 完全一致，
    /// SenseVoice 模型恰好覆盖 zh/en/yue/ja/ko 五门 + 自动判定。
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
