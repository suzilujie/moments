import AVFoundation

/// 音频会话模式：M1 的关键取舍（设计文档 4.8 节）。
///
/// 为什么这是个取舍而不是一个配置项：音频会话的仲裁是**双向**的 ——
/// 我们不带混音选项会中断其他 App 的音频；其他 App 不带混音选项也可能中断我们。
/// 两条路都走不到完美：
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
/// M0 范围：权限申请 + 会话配置与激活自检 + **音频上下文日志**，
/// 不采集任何音频（采集在 M1，设计文档 4.7–4.15）。
///
/// 之所以把"上下文日志"提前做全：会话类别、选项、采样率、IO 缓冲、输入通道数、
/// 路由设备这几项，是排查「音调怪异 / 语速不对 / 录不到声音」的**现场证据**，
/// 而这些问题只在锁屏、插耳机、连蓝牙之后才暴露 —— 现场没记录下来就再也拿不到了。
@MainActor
final class AudioSessionManager {

    static let shared = AudioSessionManager()

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
    ///
    /// 激活前后的完整参数都会记入日志：一旦真机上出现异常，
    /// 这份记录能直接回答"当时的类别与选项到底是什么"，
    /// 而不是靠回忆当时的代码。
    @discardableResult
    func activate(_ mode: AudioSessionMode) -> Bool {
        Log.shared.info(.session, "准备激活会话｜模式=\(mode.title)｜激活前 \(describeCurrentContext())")

        do {
            switch mode {
            case .coexistent:
                // 共存：不中断其他 App 的音频（代价是可能录到外放声）
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
                )
            case .highFidelity:
                // 独占：不带 mixWithOthers，因而不与其他音频共存
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.allowBluetooth, .defaultToSpeaker]
                )
            }

            try session.setActive(true)

            lastResult = "已激活：\(mode.title)"
            Log.shared.info(.session, "会话激活成功｜模式=\(mode.title)｜激活后 \(describeCurrentContext())")
            logAvailableInputs()
            logInputFormat()
            SystemStateMonitor.shared.logSnapshot("会话激活后")
            return true
        } catch {
            lastResult = "激活失败：\(error.localizedDescription)"
            Log.shared.error(
                .session,
                "会话激活失败｜模式=\(mode.title)｜\(error.localizedDescription)"
                    + "｜权限=\(permissionDescription())"
                    + "｜上下文 \(describeCurrentContext())"
            )
            return false
        }
    }

    func deactivate() {
        Log.shared.info(.session, "准备释放会话｜释放前 \(describeCurrentContext())")
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            lastResult = "已释放会话"
            Log.shared.info(.session, "会话已释放｜释放后 \(describeCurrentContext())")
        } catch {
            Log.shared.warn(.session, "会话释放失败｜\(error.localizedDescription)")
        }
    }

    // MARK: - 上下文描述（关键链路的现场证据）

    /// 一行描述当前音频上下文。被事件监听器与自检页共同复用。
    func describeCurrentContext() -> String {
        "类别=\(session.category.rawValue)/\(session.mode.rawValue)"
            + "｜选项=\(Self.optionsText(session.categoryOptions))"
            + "｜采样率=\(Int(session.sampleRate))Hz"
            + "｜IO缓冲=\(String(format: "%.1f", session.ioBufferDuration * 1000))ms"
            + "｜输入延迟=\(String(format: "%.1f", session.inputLatency * 1000))ms"
            + "｜通道=输入\(session.inputNumberOfChannels)/输出\(session.outputNumberOfChannels)"
            + "｜输入可用=\(session.isInputAvailable ? "是" : "否")"
            + "｜其他音频在播=\(session.isOtherAudioPlaying ? "是" : "否")"
            + "｜路由 \(AudioEventObserver.describeRoute(session.currentRoute))"
    }

    func contextText() -> String {
        describeCurrentContext()
    }

    /// 记录当前可用输入设备列表。
    func logAvailableInputs() {
        let inputs = session.availableInputs ?? []
        if inputs.isEmpty {
            Log.shared.warn(.session, "当前无可用输入设备（availableInputs 为空）")
            return
        }
        let text = inputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        Log.shared.info(.session, "可用输入设备（\(inputs.count) 个）｜\(text)")
    }

    /// 读取并记录当前输入设备的**原生采集格式**。
    ///
    /// 这是 M1 的关键输入：硬件采样率通常不是 16 kHz，而且会随音频路由变化
    /// （插耳机、连蓝牙后可能改变）。「采样率不匹配导致音调怪异、语速不对」
    /// 是这类项目最经典的坑，且只在锁屏/换设备后才暴露 —— 所以必须每次都留下记录。
    @discardableResult
    func logInputFormat() -> String {
        let text = nativeInputFormat()
        Log.shared.info(.capture, "原生采集格式｜\(text)")
        return text
    }

    func nativeInputFormat() -> String {
        let engine = AVAudioEngine()
        let format = engine.inputNode.inputFormat(forBus: 0)
        let sampleRate = Int(format.sampleRate)
        guard sampleRate > 0 else {
            return "不可用（可能无输入设备或权限未授予）"
        }
        let needsResample = sampleRate != 16_000
        return "\(sampleRate) Hz"
            + " / \(format.channelCount) 声道"
            + " / \(String(describing: format.commonFormat))"
            + (needsResample ? "｜M1 需转换到 16000 Hz" : "｜已是 16000 Hz，无需转换")
    }

    // MARK: - 文案映射

    private static func optionsText(_ options: AVAudioSession.CategoryOptions) -> String {
        var parts: [String] = []
        if options.contains(.mixWithOthers) { parts.append("mixWithOthers") }
        if options.contains(.duckOthers) { parts.append("duckOthers") }
        if options.contains(.allowBluetooth) { parts.append("allowBluetooth") }
        if options.contains(.allowBluetoothA2DP) { parts.append("allowBluetoothA2DP") }
        if options.contains(.allowAirPlay) { parts.append("allowAirPlay") }
        if options.contains(.defaultToSpeaker) { parts.append("defaultToSpeaker") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) {
            parts.append("interruptSpokenAudioAndMixWithOthers")
        }
        return parts.isEmpty ? "无" : parts.joined(separator: "+")
    }
}
