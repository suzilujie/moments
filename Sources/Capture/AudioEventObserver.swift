import AVFoundation
import Foundation

/// 音频事件监听器：把四类"沉默事件"全部记入日志。
///
/// 为什么 M0 就要接上（设计文档 4.12 节）：
/// 这四类事件是 M1 中断恢复机制的**全部输入**，而它们共同的特点是
/// **不报错、用户看不见、UI 也不会显示**：
///   1. 会话中断（来电 / Siri / 其他 App 抢占）
///   2. 音频路由变更（拔插耳机、AirPods 连断）
///   3. 媒体服务重置（系统重建音频栈，此后旧对象全部失效）
///   4. 音频图配置变更（AVAudioEngine 被系统停掉 —— 静默停录最常见的原因）
///
/// 其中第 4 类最危险：**它不会导致任何报错，只是音频不再来了。**
/// 在 M0 就把监听挂上，可以在真机上零成本验证「这些通知到底会不会来、什么时候来、
/// 携带什么信息」，而不是等 M1 写完恢复逻辑再回头怀疑是不是收不到通知。
@MainActor
final class AudioEventObserver {

    static let shared = AudioEventObserver()

    private var observers: [NSObjectProtocol] = []
    private(set) var isStarted = false
    /// 累计收到的事件数，供自检页确认监听确实在工作。
    private(set) var eventCount = 0

    // MARK: - 对外回调（供 RecordingSession 驱动中断恢复）
    //
    // 监听器同时承担两件事：**留痕**（写日志）与**通知**（驱动恢复）。
    // 把两件事放在一处，是为了避免"日志里记录了中断、恢复逻辑却收不到通知"
    // 这种最容易被漏掉的不一致。

    /// 会话中断：began=是否开始中断，shouldResume=系统是否允许自动恢复
    var onInterruption: (@MainActor (_ began: Bool, _ shouldResume: Bool, _ detail: String) -> Void)?
    /// 路由变更（输入/输出设备切换）
    var onRouteChange: (@MainActor (_ detail: String) -> Void)?
    /// 音频图配置变更 —— 引擎已被系统停掉，必须重建（静默停录最常见原因）
    var onEngineConfigurationChange: (@MainActor () -> Void)?
    /// 媒体服务重置 —— 会话与引擎对象全部失效，必须完整重建
    var onMediaServicesReset: (@MainActor () -> Void)?

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default

        // 1) 会话中断
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            // 只从通知里取出可跨并发域传递的原始值，避免捕获非 Sendable 的通知对象。
            //
            // 这里**不再读 AVAudioSessionInterruptionWasSuspendedKey**：
            // 该键自 iOS 14.5 起已废弃，而它承载的这个信息自 **iOS 16 起
            // 已被系统彻底移除**（弃用说明："wasSuspended reason no longer present"）。
            // 详见 handleInterruption 的说明 —— 整项已移除，不要加回来。
            let rawType = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawReason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor in
                AudioEventObserver.shared.handleInterruption(rawType: rawType, rawReason: rawReason)
            }
        })

        // 2) 路由变更
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { note in
            let rawReason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let previousText = AudioEventObserver.describeRoute(previous)
            Task { @MainActor in
                AudioEventObserver.shared.handleRouteChange(rawReason: rawReason, previousText: previousText)
            }
        })

        // 3) 媒体服务重置 / 丢失：此后所有会话与引擎对象都不再有效，必须全部重建
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AudioEventObserver.shared.record(
                    category: .session, level: .error,
                    name: "媒体服务重置 mediaServicesWereReset",
                    detail: "音频栈已被系统重建，会话与引擎对象全部失效，必须完整重建（设计文档 4.12）"
                )
                AudioEventObserver.shared.onMediaServicesReset?()
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AudioEventObserver.shared.record(
                    category: .session, level: .error,
                    name: "媒体服务丢失 mediaServicesWereLost",
                    detail: "音频服务已不可用，按彻底重建处理"
                )
                AudioEventObserver.shared.onMediaServicesReset?()
            }
        })

        // 4) 音频图配置变更：最危险的一类 —— 不报错，但音频不再来了
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AudioEventObserver.shared.record(
                    category: .capture, level: .warn,
                    name: "音频图配置变更 AVAudioEngineConfigurationChange",
                    detail: "引擎已被系统停止/重建，这是【静默停录】最常见的原因，必须在此重建引擎（设计文档 4.12）"
                )
                AudioEventObserver.shared.onEngineConfigurationChange?()
            }
        })

        Log.shared.info(.session, "音频事件监听已启动｜中断 / 路由变更 / 媒体服务重置丢失 / 音频图配置变更 共 5 类")
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isStarted = false
    }

    // MARK: - 事件处理

    private func handleInterruption(rawType: UInt?, rawReason: UInt?) {
        let typeText = Self.interruptionTypeText(rawType)
        let reasonText = Self.interruptionReasonText(rawReason)

        // 原本这里还有一项「此前是否被系统挂起」。**已整项移除**，不是简化：
        //   · 原用的 AVAudioSessionInterruptionWasSuspendedKey 自 iOS 14.5 起废弃；
        //   · 改用的 InterruptionReason.appWasSuspended 又自 **iOS 16 起废弃**，
        //     弃用说明原文是 "wasSuspended reason no longer present" ——
        //     即**系统已不再提供这个信息**。
        // 继续保留只会显示一个误导性的「否」，把"系统没提供"说成"没被挂起"，
        // 比不显示更糟：排查【锁屏后被静默停录】时会把方向带偏。
        // 这段记录留在这里，是为了避免以后有人"顺手把它加回来"。
        let isBegan = rawType == AVAudioSession.InterruptionType.began.rawValue
        // 系统会在 .ended 通知里通过 shouldResume 告知是否允许我们恢复。
        // 这里按"允许"处理并交给状态机尝试 —— 真正能否恢复，由重新激活会话的结果决定，
        // 不能只信这个布尔值（真机上存在 shouldResume 为真却无法恢复的情况）。
        let shouldResume = !isBegan

        let detail = "原因=\(reasonText)"
        record(
            category: .interrupt,
            level: .warn,
            name: "会话中断 interruption｜\(typeText)",
            detail: detail + "｜shouldResume=\(shouldResume ? "是" : "否")"
        )
        onInterruption?(isBegan, shouldResume, detail)
    }

    private func handleRouteChange(rawReason: UInt?, previousText: String) {
        let reasonText = Self.routeChangeReasonText(rawReason)
        let detail = "变更前路由=\(previousText)"
        record(
            category: .route,
            level: reasonText.contains("oldDeviceUnavailable") ? .warn : .info,
            name: "路由变更 routeChange｜\(reasonText)",
            detail: detail + "｜需重建输入节点与格式转换器（设计文档 4.12）"
        )
        onRouteChange?(detail)
    }

    /// 统一出口：先记事件本身，再补一条当前音频上下文的快照。
    ///
    /// 为什么一定要补上下文：只知道"发生了路由变更"没用，
    /// 必须知道"变更之后采样率变成了多少、还有没有输入设备"。
    /// 「采样率随路由变化导致音调怪异」正是靠这条上下文才能定位（设计文档 4.10）。
    private func record(category: LogCategory, level: LogLevel, name: String, detail: String) {
        eventCount += 1
        let message = "\(name)｜\(detail)"
        switch level {
        case .info: Log.shared.info(category, message)
        case .warn: Log.shared.warn(category, message)
        case .error: Log.shared.error(category, message)
        }
        Log.shared.info(category, "音频上下文快照｜\(AudioSessionManager.shared.describeCurrentContext())")
    }

    // MARK: - 文案映射

    private static func interruptionTypeText(_ raw: UInt?) -> String {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return "未知" }
        switch type {
        case .began: return "began(被打断)"
        case .ended: return "ended(打断结束)"
        @unknown default: return "其他(\(raw))"
        }
    }

    private static func interruptionReasonText(_ raw: UInt?) -> String {
        guard let raw else { return "未提供" }

        // 按**原始值**判断，而不是 switch 枚举本身。
        //
        // 原因：CI 所用的 **Xcode 16.4（iOS 18 SDK）** 下，对
        // AVAudioSession.InterruptionReason 做 switch（**即使带 @unknown default**）
        // 仍会报「switch must be exhaustive」—— 说明 SDK 里存在下面这两种之外的情形。
        // 本机是 Windows，看不到 SDK 头文件，因此无法确认它指的是哪一个 case。
        //（这里写清版本是有必要的：先前记成"iOS 26 SDK"是错的，
        //  而错误的归因会让后人按错误的方向去查。）
        //
        // 取舍：本函数只负责把原因翻译成一句人话，任何未知值打出原始数字即可，
        // 因此按原始值判断最稳 —— 既覆盖已知情形，也不会因将来 SDK 变更
        // 而编译失败。代价是失去"枚举新增 case 时编译器会提醒"这一保护，
        // 而这里的失效后果仅仅是多显示一个数字，可以接受。
        //
        // 注意：**不要把 .appWasSuspended 加回来** —— 它自 iOS 16 起已废弃
        //（"wasSuspended reason no longer present"），系统不再提供该值；
        // 引用它还会额外换来一条编译告警。
        switch raw {
        case AVAudioSession.InterruptionReason.default.rawValue:
            return "default(系统未给出具体原因)"
        case AVAudioSession.InterruptionReason.builtInMicMuted.rawValue:
            return "builtInMicMuted(内置麦克风被静音)"
        default:
            return "其他(\(raw))"
        }
    }

    private static func routeChangeReasonText(_ raw: UInt?) -> String {
        guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "未知" }
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable(新设备接入)"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable(设备断开)"
        case .categoryChange: return "categoryChange(类别变更)"
        case .override: return "override(被覆盖)"
        case .wakeFromSleep: return "wakeFromSleep(唤醒)"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory(无合适路由)"
        case .routeConfigurationChange: return "routeConfigurationChange(路由配置变化)"
        @unknown default: return "其他(\(raw))"
        }
    }

    /// nonisolated：需要在非 MainActor 的通知回调里调用（见 start()）
    nonisolated static func describeRoute(_ route: AVAudioSessionRouteDescription?) -> String {
        guard let route else { return "无" }
        let inputs = route.inputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        let outputs = route.outputs
            .map { "\($0.portName)[\($0.portType.rawValue)]" }
            .joined(separator: ", ")
        return "输入(\(inputs.isEmpty ? "无" : inputs)) 输出(\(outputs.isEmpty ? "无" : outputs))"
    }
}
