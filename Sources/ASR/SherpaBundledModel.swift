import Foundation

/// 随包内置的 sherpa-onnx 模型（M3）。
///
/// ## 为什么这几个模型内置，而 whisper 模型走运行时下载
/// 这是**刻意做成两种相反策略**的，判据是「体积 + 可靠性」：
///
/// | | whisper 模型 | sherpa 模型（本文件） |
/// |---|---|---|
/// | 单个体积 | 32 MB ～ 539 MB | 0.5 MB ～ 27 MB（合计约 35 MB）|
/// | 处理方式 | 运行时下载 | **打进 ipa** |
/// | 原因 | 打包则超蜂窝 200 MB 上限，部分用户**装不上** | 体积小；且原始托管在 GitHub Releases，而交付环境实测 github.com 不可达 |
///
/// 关键在最后一条：若把 VAD / 降噪 / 说话人分离做成运行时下载，
/// 它们就会因网络问题而不可用 —— 那是**把一个可用的功能做成不可用**。
/// 内置之后，M3 的全部能力**永久可用，不依赖任何网络**。
enum SherpaBundledModel: String, CaseIterable {

    /// 语音活动检测（Silero VAD，0.6 MB）
    case sileroVad
    /// 语音增强 / 降噪（GTCRN，0.5 MB）
    case gtcrn
    /// 说话人分割（pyannote segmentation 3.0，6.6 MB）
    case pyannoteSegmentation
    /// 声纹嵌入（3D-Speaker CAM++ 中英通用版，27 MB）
    case speakerEmbedding

    /// App 包内的文件名（CI 下载时即按此命名，见 .github/workflows/ios-build.yml）
    var fileName: String {
        switch self {
        case .sileroVad: return "silero_vad.onnx"
        case .gtcrn: return "gtcrn_simple.onnx"
        case .pyannoteSegmentation: return "pyannote_segmentation_3_0.onnx"
        case .speakerEmbedding: return "campplus_zh_en_16k.onnx"
        }
    }

    var displayName: String {
        switch self {
        case .sileroVad: return "语音活动检测（Silero VAD）"
        case .gtcrn: return "语音增强 / 降噪（GTCRN）"
        case .pyannoteSegmentation: return "说话人分割（pyannote 3.0）"
        case .speakerEmbedding: return "声纹嵌入（CAM++ 中英）"
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .sileroVad: return 640_000
        case .gtcrn: return 534_000
        case .pyannoteSegmentation: return 6_960_000
        case .speakerEmbedding: return 28_280_000
        }
    }

    var note: String {
        switch self {
        case .sileroVad:
            return "判断「这段到底是不是人声」。替代 M2 的均方根能量门限 —— 后者分不清人声与稳定噪声"
        case .gtcrn:
            return "降噪模型。注意：降噪会引入失真伪影，可能让识别更差，因此做成可开关的对照实验"
        case .pyannoteSegmentation:
            return "把音频切成「可能换人了」的片段，是说话人分离的第一步"
        case .speakerEmbedding:
            return "把一段语音压成声纹向量，用于判断「是不是同一个人」"
        }
    }

    /// App 包内路径。
    ///
    /// **找不到即返回 nil**，由调用方明确提示 —— 而不是把一个不存在的路径
    /// 交给第三方库（那只会得到一个很难读的底层报错）。
    var url: URL? {
        // 资源在构建时被平铺到包根目录（见 project.yml 的 Resources 配置）
        let candidate = Bundle.main.bundleURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var isAvailable: Bool { url != nil }

    // MARK: - 汇总（自检页与设置页用）

    static var missingModels: [SherpaBundledModel] {
        allCases.filter { !$0.isAvailable }
    }

    /// M3 的能力是否可用（VAD 与降噪是 M3b 的前提）
    static var isReady: Bool { missingModels.isEmpty }

    static var totalBytes: Int64 {
        allCases.reduce(0) { $0 + $1.approximateBytes }
    }

    static var summary: String {
        let missing = missingModels
        if missing.isEmpty {
            return "全部就绪（\(allCases.count) 个，约 \(sizeText(totalBytes))）"
        }
        return "缺失 \(missing.count) 个：\(missing.map { $0.fileName }.joined(separator: "、"))"
    }

    /// 给用户的诊断提示：明确指出"哪个文件缺了、以及它会导致什么功能不可用"。
    /// 只说"模型缺失"而不说后果，用户无法判断该不该在意。
    static func impactText(of missing: [SherpaBundledModel]) -> String {
        missing.map { "\($0.displayName) 不可用：\($0.note)" }.joined(separator: "\n")
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
