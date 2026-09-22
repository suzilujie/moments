import Foundation

/// 构建指纹。
///
/// 本文件由 CI 在构建前**覆盖写入**（见 .github/workflows/ios-build.yml
/// 的 "Inject build info" 步骤），把当次提交号与构建时间打进 App。
///
/// 为什么需要它：侧载链路下，「设备上装的到底是哪一版」是一个高频误判点 ——
/// 装了旧包却以为新改动没生效，会浪费大量时间。把提交号直接显示在界面上，
/// 一眼即可确认。
enum BuildInfo {
    static let commit = "local"
    static let builtAt = "本地未注入"
}
