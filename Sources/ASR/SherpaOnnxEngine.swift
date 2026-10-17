import Foundation

/// sherpa-onnx 接入层（M3）。
///
/// ## 为什么这里只做「报出版本号」这一件事
/// sherpa-onnx 是一个大得多的外部依赖（自带 onnxruntime、kaldifst、
/// sentencepiece 等），而且官方**没有** iOS 预编译产物，只能由 CI 用 CMake
/// 自行构建。这类依赖的风险集中在"能不能构建出来、能不能链接上"，
/// 与业务逻辑无关。
///
/// 因此按与 M2（whisper.cpp）相同的策略推进：**先把集成本身做成可验证的一件事** ——
/// 能取到版本号，就证明静态库真的被链接进来了，比"编译通过"强得多
/// （编译通过也可能只是没引用而已）。ver 通过之后，再往上叠加
/// 降噪 / VAD 这些真正有业务价值的能力（两者分别封装在
/// `SherpaDenoiser` / `SherpaVad`，本类只负责版本与链接自检）。
///
/// ## 已核实的 C API 名称（供后续查阅）
///   · 语音活动检测 VAD：`SherpaOnnxCreateVoiceActivityDetector`
///     （配置结构 `SherpaOnnxVadModelConfig` / `SherpaOnnxSileroVadModelConfig`）
///   · 语音增强（GTCRN 降噪）：`SherpaOnnxCreateOfflineSpeechDenoiser`
///
/// ## 2026-10-17：说话人分离相关能力已移除
/// `SherpaOnnxCreateOfflineSpeakerDiarization` 这一路（含 pyannote 分割与
/// CAM++ 声纹两个内置模型）随「说话人」功能一并删除，本类不再涉及。
enum SherpaOnnxEngine {

    /// 库版本号。取不到即说明静态库未被真正链接。
    static var version: String? {
        optionalString(SherpaOnnxGetVersionStr())
    }

    /// 构建时的 git 短哈希 —— 与版本号一起留痕，便于日后比对"设备上装的是哪次构建"。
    static var gitSha1: String? {
        optionalString(SherpaOnnxGetGitSha1())
    }

    /// 构建日期
    static var gitDate: String? {
        optionalString(SherpaOnnxGetGitDate())
    }

    /// 是否已真正链接（自检页的验收判据）
    static var isLinked: Bool {
        guard let version else { return false }
        return !version.isEmpty
    }

    /// 一行摘要，供自检页与日志使用
    static var summary: String {
        guard let version else { return "不可用（sherpa-onnx 未链接）" }
        let sha = gitSha1 ?? "?"
        let date = gitDate ?? "?"
        return "v\(version)｜commit \(sha)｜构建于 \(date)"
    }

    /// C 字符串转 Swift String。
    ///
    /// 必须判空：C API 在异常路径上返回 NULL 是常见做法，
    /// 而 `String(cString:)` 遇到 NULL 会直接崩溃 ——
    /// 在一个"自检页"里因为第三方库返回 NULL 而闪退，是最糟糕的失败方式。
    private static func optionalString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}
