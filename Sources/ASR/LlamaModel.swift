import Foundation

/// Qwen2.5-0.5B 纠错模型的描述（LLM 纠错功能，2026-10-17 接入）。
///
/// 这个模型只做一件事：把识别引擎吐出的「同音字 / 识别错误」纠正回正确文本。
/// 它与 `SenseVoiceModel` 分属两个独立下载项，理由相同：模型不打进 ipa，
/// 运行时按需下载到 `Models/` 目录（见 `AppPaths.modelsDirectory()`）。
enum LlamaModel {

    /// 模型 id。写进日志，用于区分与排查「当前跑的是哪个纠错模型」。
    static let id = "qwen2.5-0.5b-instruct"

    static let displayName = "Qwen2.5-0.5B（纠错）"

    /// 运行时下载的 GGUF 文件名。
    static let modelFileName = "qwen2.5-0.5b-instruct-q4_k_m.gguf"

    /// 近似体积（仅用于界面展示与磁盘预检，不用于校验；校验用「体积下界 + 加载时验证」）。
    static let approximateBytes: Int64 = 397_559_808

    /// 模型仓库（固定 tag，GGUF 从此下载）。
    private static let repo = "Qwen/Qwen2.5-0.5B-Instruct-GGUF"

    /// 主站下载地址。
    static var primaryURL: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(modelFileName)")!
    }

    /// 国内镜像地址（交付环境实测 huggingface.co 可能不可达，必须有一条回退路）。
    static var mirrorURL: URL {
        URL(string: "https://hf-mirror.com/\(repo)/resolve/main/\(modelFileName)")!
    }

    static var sizeText: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}
