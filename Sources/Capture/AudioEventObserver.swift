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

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default

        // 1) 会话中断
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            // 只从通知里取出可跨并发域传递的原始值，避免捕获非 Sendable 的通知对象
            let rawType = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawReason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
            let wasSuspended = (note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber)?.boolValue
            Task { @MainActor in
                AudioEventObserver.shared.handleInterruption(
                    rawType: rawType, rawReason: rawReason, wasSuspended: wasSuspended
                )
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
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                AudioEventObserver.shared.record(
                    category: .session, level: .error,
                    name: "媒体服务丢失 mediaServicesWereLost",
                    detail: "音频服务已不可用"
                )
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
                    detail: "引擎已被系统停止/重建，这是【静默停录】最常见的原因，M1 必须在此重建引擎（设计文档 4.12）"
                )
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

    private func handleInterruption(rawType: UInt?, rawReason: UInt?, wasSuspended: Bool?) {
        let typeText = Self.interruptionTypeText(rawType)
        let reasonText = Self.interruptionReasonText(rawReason)
        let suspendedText = wasSuspended.map { $0 ? "是" : "否" } ?? "未提供"

        // shouldResume 决定 M1 是否会自动恢复；这里先记录下来，真机上直接可见
        let shouldResume = rawType == AVAudioSession.InterruptionType.ended.rawValue

        record(
            category: .interrupt,
            level: shouldResume ? .warn : .warn,
            name: "会话中断 interruption｜\(typeText)",
            detail: "原因=\(reasonText)｜此前被系统挂起=\(suspendedText)"
                + "｜M1 将在 ended 时尝试自动恢复（设计文档 4.12）"
        )
    }

    private func handleRouteChange(rawReason: UInt?, previousText: String) {
        let reasonText = Self.routeChangeReasonText(rawReason)
        record(
            category: .route,
            level: reasonText.contains("oldDeviceUnavailable") ? .warn : .info,
            name: "路由变更 routeChange｜\(reasonText)",
            detail: "变更前路由=\(previousText)｜M1 需在此重建输入节点与格式转换器（设计文档 4.12）"
        )
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
        guard let raw, let reason = AVAudioSession.InterruptionReason(rawValue: raw) else { return "未提供" }
        switch reason {
        case .default: return "default"
        case .appWasSuspended: return "appWasSuspended(App 被系统挂起)"
        case .builtInMicMuted: return "builtInMicMuted(内置麦克风被静音)"
        @unknown default: return "其他(\(raw))"
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
