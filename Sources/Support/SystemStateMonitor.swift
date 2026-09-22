import Darwin
import Foundation
import UIKit

/// 系统状态监测：电量、低电量模式、热状态、磁盘余量、进程内存占用。
///
/// 为什么 M0 就要它（设计文档 4.13 节）：
/// 这些量正是 M1「降档策略」的全部输入 —— 低电量与电量决定是否暂停实时转写，
/// 热状态决定是否停止重任务，磁盘余量决定何时停止录音。
/// 提前把监测与记录接上，M1 写降档逻辑时就不必再重新验证"这些值拿不拿得到"。
///
/// 内存占用（phys_footprint）是 Apple 判断是否回收进程的口径，
/// 也是 M1 排查「8 小时长录是否泄漏」的唯一依据。
@MainActor
final class SystemStateMonitor {

    static let shared = SystemStateMonitor()

    private var observers: [NSObjectProtocol] = []
    private var lastThermal = ""
    private var lastLowPower: Bool?
    private var lastBatteryBucket = -1
    private var lastDiskBucket = -1

    private(set) var isStarted = false
    /// 记录到的状态变更次数，供自检页确认监听确实在工作。
    private(set) var changeCount = 0

    private init() {}

    // MARK: - 启动

    func start() {
        guard !isStarted else { return }
        isStarted = true

        UIDevice.current.isBatteryMonitoringEnabled = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SystemStateMonitor.shared.handleThermal() }
        })
        observers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SystemStateMonitor.shared.handleLowPower() }
        })
        observers.append(center.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SystemStateMonitor.shared.handleBattery(reason: "电源状态变化") }
        })
        observers.append(center.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SystemStateMonitor.shared.handleBattery(reason: "电量变化") }
        })

        Log.shared.info(.system, "系统状态监测已启动｜监听 4 类事件")
        logSnapshot("启动初始状态")
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        isStarted = false
    }

    // MARK: - 变更处理（只在跨越档位时记录，避免日志被刷满）

    private func handleThermal() {
        let current = Self.thermalText()
        guard current != lastThermal else { return }
        let previous = lastThermal.isEmpty ? "未知" : lastThermal
        lastThermal = current
        changeCount += 1
        // 热状态跨越 serious / critical 是 M1 降档的触发条件，必须高亮记录
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            Log.shared.warn(.thermal, "热状态变化 \(previous) → \(current)｜M1 将在此触发降档（设计文档 4.13）")
        } else {
            Log.shared.info(.thermal, "热状态变化 \(previous) → \(current)")
        }
    }

    private func handleLowPower() {
        let current = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard current != lastLowPower else { return }
        lastLowPower = current
        changeCount += 1
        if current {
            Log.shared.warn(.thermal, "低电量模式已开启｜M1 将暂停实时转写与批处理（设计文档 4.13）")
        } else {
            Log.shared.info(.thermal, "低电量模式已关闭")
        }
        logSnapshot("低电量模式变化")
    }

    private func handleBattery(reason: String) {
        let level = Self.batteryLevel()
        let bucket = level < 0 ? -1 : level / 5
        guard bucket != lastBatteryBucket else { return }
        lastBatteryBucket = bucket
        changeCount += 1

        let levelText = level < 0 ? "未知" : "\(level)%"
        let stateText = Self.batteryStateText()
        if level >= 0 && level < 20 && !Self.isCharging() {
            Log.shared.warn(.disk, "电量偏低（\(reason)）｜\(levelText) / \(stateText)｜M1 将在此降档")
        } else {
            Log.shared.info(.system, "电源信息变化（\(reason)）｜\(levelText) / \(stateText)")
        }
    }

    /// 磁盘跨越阈值时记录一次（M1 的停止/清理阈值是 3 GB 与 1 GB）。
    func checkDisk(reason: String) {
        let gb = Self.freeDiskGB()
        guard let gb else { return }
        let bucket = gb >= 3 ? 3 : (gb >= 1 ? 1 : 0)
        guard bucket != lastDiskBucket else { return }
        lastDiskBucket = bucket
        changeCount += 1

        switch bucket {
        case 0:
            Log.shared.error(.disk, "剩余磁盘不足 1 GB（\(reason)）｜当前 \(String(format: "%.2f", gb)) GB"
                + "｜M1 将在此停止录音（设计文档 4.13）")
        case 1:
            Log.shared.warn(.disk, "剩余磁盘不足 3 GB（\(reason)）｜当前 \(String(format: "%.2f", gb)) GB"
                + "｜M1 将在此触发清理")
        default:
            Log.shared.info(.disk, "剩余磁盘 \(String(format: "%.2f", gb)) GB（\(reason)）")
        }
    }

    // MARK: - 快照

    /// 把完整状态打一条日志。调用时机：启动、进入后台、回到前台、手动触发。
    func logSnapshot(_ reason: String) {
        Log.shared.info(.system, "状态快照（\(reason)）｜\(snapshotText())")
    }

    func snapshotText() -> String {
        let level = Self.batteryLevel()
        let levelText = level < 0 ? "未知" : "\(level)%"
        let diskText = Self.freeDiskGB().map { String(format: "%.2f GB", $0) } ?? "-"
        let memoryText = Self.memoryFootprintText()
        return "电量 \(levelText) / \(Self.batteryStateText())"
            + "｜低电量模式 \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "开" : "关")"
            + "｜热状态 \(Self.thermalText())"
            + "｜磁盘余量 \(diskText)"
            + "｜内存占用 \(memoryText)"
    }

    // MARK: - 取值

    static func batteryLevel() -> Int {
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else { return -1 }
        return Int((raw * 100).rounded())
    }

    static func isCharging() -> Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        default: return false
        }
    }

    static func batteryStateText() -> String {
        switch UIDevice.current.batteryState {
        case .unknown: return "未知"
        case .unplugged: return "未充电"
        case .charging: return "充电中"
        case .full: return "已充满"
        @unknown default: return "其他"
        }
    }

    static func thermalText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal(正常)"
        case .fair: return "fair(略高)"
        case .serious: return "serious(偏高)"
        case .critical: return "critical(过热)"
        @unknown default: return "其他"
        }
    }

    static func freeDiskGB() -> Double? {
        guard let url = try? AppPaths.appRoot() else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_073_741_824.0
    }

    /// 进程实际内存占用（phys_footprint）—— Apple 判断是否回收进程的口径。
    /// 用 resident size 会低估，用 phys_footprint 才能与系统的 jetsam 阈值对齐。
    static func memoryFootprintText() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "读取失败(\(result))" }
        let megabytes = Double(info.phys_footprint) / 1_048_576.0
        return String(format: "%.1f MB", megabytes)
    }
}
