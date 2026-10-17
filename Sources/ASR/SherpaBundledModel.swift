import Foundation

/// 随包内置的 sherpa-onnx 模型（M3）。
///
/// ## 为什么这几个模型内置，而 SenseVoice 识别模型走运行时下载
/// 这是**刻意做成两种相反策略**的，判据是「体积 + 可靠性」：
///
/// | | SenseVoice 识别模型 | sherpa 模型（本文件） |
/// |---|---|---|
/// | 单个体积 | 约 226 MB | 0.5 MB ～ 0.6 MB（合计约 1.1 MB）|
/// | 处理方式 | 运行时下载 | **打进 ipa** |
/// | 原因 | 打包则超蜂窝 200 MB 上限，部分用户**装不上** | 体积小；且原始托管在 GitHub Releases / HuggingFace，交付环境实测 github.com 不可达 |
///
/// 关键在最后一条：若把 VAD / 降噪做成运行时下载，
/// 它们就会因网络问题而不可用 —— 那是**把一个可用的功能做成不可用**。
/// 内置之后，这些能力**永久可用，不依赖任何网络**。
///
/// ## 2026-10-17 收缩到两个模型 + 换 SenseVoice 识别引擎
/// 「说话人分割（pyannote，6.6 MB）」与「声纹嵌入（CAM++，27 MB）」已随
/// 「说话人」功能一并移除；「音乐检测（CED，约 5.86 MB）」随识别引擎整体
/// 换成 SenseVoice（其事件检测内建 <|MUSIC|> 等）一并移除 —— 音乐检测不再是
/// 独立模型，而是 SenseVoice 识别结果的一部分。VAD 与降噪**保留**。
enum SherpaBundledModel: String, CaseIterable {

    /// 语音活动检测（Silero VAD，0.6 MB）
    case sileroVad
    /// 语音增强 / 降噪（GTCRN，0.5 MB）
    case gtcrn

    /// 该模型随包需要的所有文件名（CI 下载时即按此命名，见 .github/workflows/ios-build.yml）。
    ///
    /// 资源在构建时被平铺到包根目录，因此代码里直接用
    /// `Bundle.main.bundleURL.appendingPathComponent(...)` 定位。
    var files: [String] {
        switch self {
        case .sileroVad: return ["silero_vad.onnx"]
        case .gtcrn: return ["gtcrn_simple.onnx"]
        }
    }

    var displayName: String {
        switch self {
        case .sileroVad: return "语音活动检测（Silero VAD）"
        case .gtcrn: return "语音增强 / 降噪（GTCRN）"
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .sileroVad: return 640_000
        case .gtcrn: return 534_000
        }
    }

    var note: String {
        switch self {
        case .sileroVad:
            return "判断「这段到底是不是人声」。替代 M2 的均方根能量门限 —— 后者分不清人声与稳定噪声"
        case .gtcrn:
            return "降噪模型。注意：降噪会引入失真伪影，可能让识别更差，因此做成可开关的对照实验"
        }
    }

    /// 包内已存在的文件 URL（缺失的文件不会出现在结果里）。
    var availableURLs: [URL] {
        files.compactMap { name -> URL? in
            let candidate = Bundle.main.bundleURL.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

    /// 缺失的文件名（空表示齐全）。
    var missingFiles: [String] {
        files.filter { name in
            let candidate = Bundle.main.bundleURL.appendingPathComponent(name)
            return !FileManager.default.fileExists(atPath: candidate.path)
        }
    }

    var isAvailable: Bool { missingFiles.isEmpty }

    /// 单文件模型的包内路径（sileroVad / gtcrn 都是单文件模型）。
    ///
    /// **找不到即返回 nil**，由调用方明确提示 —— 而不是把一个不存在的路径
    /// 交给第三方库（那只会得到一个很难读的底层报错）。
    var url: URL? {
        guard files.count == 1 else { return nil }
        let candidate = Bundle.main.bundleURL.appendingPathComponent(files[0])
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

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
        let files = missing.flatMap { $0.missingFiles }
        return "缺失 \(files.count) 个文件：\(files.joined(separator: "、"))"
    }

    /// 给用户的诊断提示：明确指出"哪个模型缺了、以及它会导致什么功能不可用"。
    /// 只说"模型缺失"而不说后果，用户无法判断该不该在意。
    static func impactText(of missing: [SherpaBundledModel]) -> String {
        missing.map { "\($0.displayName) 不可用：\($0.note)" }.joined(separator: "\n")
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
