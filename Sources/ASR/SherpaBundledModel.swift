import Foundation

/// 随包内置的 sherpa-onnx 模型（M3）。
///
/// ## 为什么这几个模型内置，而 whisper 模型走运行时下载
/// 这是**刻意做成两种相反策略**的，判据是「体积 + 可靠性」：
///
/// | | whisper 模型 | sherpa 模型（本文件） |
/// |---|---|---|
/// | 单个体积 | 32 MB ～ 539 MB | 0.5 MB ～ 5.9 MB（合计约 7 MB）|
/// | 处理方式 | 运行时下载 | **打进 ipa** |
/// | 原因 | 打包则超蜂窝 200 MB 上限，部分用户**装不上** | 体积小；且原始托管在 GitHub Releases / HuggingFace，交付环境实测 github.com 不可达 |
///
/// 关键在最后一条：若把 VAD / 降噪 / 音乐检测做成运行时下载，
/// 它们就会因网络问题而不可用 —— 那是**把一个可用的功能做成不可用**。
/// 内置之后，这些能力**永久可用，不依赖任何网络**。
///
/// ## 2026-10-17 收缩到两个模型
/// 「说话人分割（pyannote，6.6 MB）」与「声纹嵌入（CAM++，27 MB）」已随
/// 「说话人」功能一并移除（用户确认不需要），安装包因此减少约 34 MB，
/// CI 也少两段下载与两段字节断言。VAD 与降噪**保留** —— 它们是实时字幕
/// 与对照转写的前提，与说话人功能无关。
///
/// ## 2026-10-17 新增 CED 音乐检测
/// CED tiny int8（约 5.86 MB）随包内置，用于在实时字幕里识别"带歌声的音乐"：
/// VAD 分不清音乐/人声，whisper 对音乐只会编造文本。与 Zipformer 音频标记模型
/// （约 90 MB，无法内置）相比，CED tiny 是唯一"既能内置、又解决这个痛点"的选择。
enum SherpaBundledModel: String, CaseIterable {

    /// 语音活动检测（Silero VAD，0.6 MB）
    case sileroVad
    /// 语音增强 / 降噪（GTCRN，0.5 MB）
    case gtcrn
    /// 音乐检测（CED tiny int8，约 5.86 MB）
    case ced

    /// 该模型随包需要的所有文件名（CI 下载时即按此命名，见 .github/workflows/ios-build.yml）。
    ///
    /// 资源在构建时被平铺到包根目录，因此代码里直接用
    /// `Bundle.main.bundleURL.appendingPathComponent(...)` 定位。
    var files: [String] {
        switch self {
        case .sileroVad: return ["silero_vad.onnx"]
        case .gtcrn: return ["gtcrn_simple.onnx"]
        case .ced: return ["ced.int8.onnx", "ced_labels.csv"]
        }
    }

    var displayName: String {
        switch self {
        case .sileroVad: return "语音活动检测（Silero VAD）"
        case .gtcrn: return "语音增强 / 降噪（GTCRN）"
        case .ced: return "音乐检测（CED）"
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .sileroVad: return 640_000
        case .gtcrn: return 534_000
        // model.int8.onnx 6,133,417 + class_labels_indices.csv 14,675
        case .ced: return 6_148_092
        }
    }

    var note: String {
        switch self {
        case .sileroVad:
            return "判断「这段到底是不是人声」。替代 M2 的均方根能量门限 —— 后者分不清人声与稳定噪声"
        case .gtcrn:
            return "降噪模型。注意：降噪会引入失真伪影，可能让识别更差，因此做成可开关的对照实验"
        case .ced:
            return "判断「这段是音乐还是人声」。带歌声的主题曲/BGM 会被 VAD 误判为语音、whisper 对着音乐编造文本，用它拦住"
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

    /// 单文件模型（sileroVad / gtcrn）的包内路径；多文件模型（ced）返回 nil ——
    /// 它需要同时取模型与标签两个文件，改用 `cedModelAndLabels`。
    ///
    /// **找不到即返回 nil**，由调用方明确提示 —— 而不是把一个不存在的路径
    /// 交给第三方库（那只会得到一个很难读的底层报错）。
    var url: URL? {
        guard files.count == 1 else { return nil }
        let candidate = Bundle.main.bundleURL.appendingPathComponent(files[0])
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// ced 的（模型文件, 标签文件）包内路径；两者都齐全才返回，缺一即 nil。
    var cedModelAndLabels: (model: URL, labels: URL)? {
        let model = Bundle.main.bundleURL.appendingPathComponent("ced.int8.onnx")
        let labels = Bundle.main.bundleURL.appendingPathComponent("ced_labels.csv")
        let fm = FileManager.default
        guard fm.fileExists(atPath: model.path), fm.fileExists(atPath: labels.path) else { return nil }
        return (model, labels)
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
