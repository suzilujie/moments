import AVFoundation

/// 音频会话模式：M1 的关键取舍（设计文档 4.8 节）。
///
/// 为什么这是个取舍而不是一个配置项：音频会话的仲裁是**双向**的 ——
/// 我们不带混音选项会中断其他 App 的音频；其他 App 不带混音选项也可能中断我们。
/// 两条路都走不通到完美：
///   · 独占：录音最干净，但用户一整天不能听音乐看视频（对"全时录音"是灾难）
///   · 共存：手机可正常使用，但麦克风会录到本机外放的声音（污染音频）
///
/// 因此默认选**共存** —— 本项目的核心承诺是"一直录"。如果一开录音就让手机
/// 变成砖头，用户第二天就不会再打开它了，录音再干净也没有意义。
enum AudioSessionMode: CaseIterable {
    /// 共存（默认）：允许其他 App 继续播放，代价是可能录到外放的声音。
    case coexistent
    /// 高保真（独占）：录音最干净，代价是期间其他 App 无法播放音频。
    case highFidelity

    var title: String {
        switch self {
        case .coexistent: return "共存（默认）"
        case .highFidelity: return "高保真（独占）"
        }
    }

    var detail: String {
        switch self {
        case .coexistent: return "手机可正常听音乐、看视频；可能录到本机外放的声音，建议佩戴耳机"
        case .highFidelity: return "录音最干净；期间其他 App 的音频会被中断"
        }
    }
}

/// 音频会话管理。
///
/// M0 范围：只做「权限申请 + 会话配置 + 激活自检」，**不采集任何音频**。
/// 真正的采集、双轨、分片落盘在 M1 实现（设计文档 4.7–4.15）。
/// 之所以在 M0 就把会话打通，是因为权限与 plist 声明属于"配置类风险"，
/// 提前验证的成本极低，而留到 M1 才发现会打断主线开发。
@MainActor
final class AudioSessionManager {

    private let session = AVAudioSession.sharedInstance()

    /// 最近一次配置结果，供自检页展示。
    private(set) var lastResult: String = "尚未配置"

    // MARK: - 权限

    /// 申请录音权限（iOS 17 起推荐 API，旧的 AVAudioSession 版本已过时）。
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 查询当前权限状态（不触发弹窗）。
    func permissionDescription() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "已授权"
        case .denied: return "已拒绝"
        case .undetermined: return "未决定"
        @unknown default: return "未知"
        }
    }

    // MARK: - 会话

    /// 按模式配置并激活会话。
    /// M0 只做一次自检式激活，用来验证权限、类别与 plist 声明都是通的。
    @discardableResult
    func activate(_ mode: AudioSessionMode) -> Bool {
        do {
            switch mode {
            case .coexistent:
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
                )
            case .highFidelity:
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetooth]
                )
            }
            try session.setActive(true)

            lastResult = "已激活：\(mode.title)"
            Log.shared.info(
                .session,
                "会话激活成功｜模式=\(mode.title)｜类别=\(session.category.rawValue)"
                    + "｜采样率=\(Int(session.sampleRate))Hz"
            )
            return true
        } catch {
            lastResult = "激活失败：\(error.localizedDescription)"
            Log.shared.error(.session, "会话激活失败｜模式=\(mode.title)｜\(error.localizedDescription)")
            return false
        }
    }

    func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            lastResult = "已释放会话"
            Log.shared.info(.session, "会话已释放")
        } catch {
            Log.shared.warn(.session, "会话释放失败｜\(error.localizedDescription)")
        }
    }

    /// 读取当前输入设备的**原生采集格式**。
    ///
    /// 这是 M1 的关键输入：硬件采样率通常不是 16 kHz，而且会随音频路由变化
    /// （插耳机、连蓝牙后可能改变）。"采样率不匹配导致音调怪异"是这类项目
    /// 最经典的坑，且只在锁屏/换设备后才暴露 —— 所以现在就把它读出来看一眼。
    func nativeInputFormat() -> String {
        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        let sampleRate = Int(format.sampleRate)
        guard sampleRate > 0 else {
            return "不可用（可能无输入设备或无权限）"
        }
        return "\(sampleRate) Hz / \(format.channelCount) 声道 / \(String(describing: format.commonFormat))"
    }
}
