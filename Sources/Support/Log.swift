import Foundation
import os

/// 日志分类（对应设计文档 4.14 节的分类表）。
///
/// 为什么要分这么细：本项目没有断点调试器（无 Mac、无 Xcode），
/// 所有排错依赖日志推断；而「中断恢复」「降档」属于沉默行为 ——
/// 不报错、用户看不到，没有分类日志就等于没有观测手段。
enum LogCategory: String, CaseIterable {
    case app
    case capture
    case session
    case interrupt
    case route
    case thermal
    case disk
    case storage
}

enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let at: Date
    let category: LogCategory
    let level: LogLevel
    let message: String
}

/// 结构化日志：内存环形缓冲 + 可导出 + 同时写入系统日志。
///
/// 三条通道各有用途：
/// - 内存缓冲：应用内日志面板实时查看（无需连电脑）
/// - 导出文本：通过 USB 取证
/// - 系统日志：`idevicesyslog` 可在 App 还没起来时就看到启动阶段的输出
final class Log {

    static let shared = Log()

    private let capacity: Int
    private var buffer: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.xfish.moments.log")
    private let osLog = os.Logger(subsystem: "com.xfish.moments", category: "Moments")

    init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    func info(_ category: LogCategory, _ message: String) {
        write(category, .info, message)
    }

    func warn(_ category: LogCategory, _ message: String) {
        write(category, .warn, message)
    }

    func error(_ category: LogCategory, _ message: String) {
        write(category, .error, message)
    }

    /// 状态迁移专用入口：统一格式，便于在日志里检索「状态机轨迹」。
    /// 设计文档 4.7 节要求每次状态迁移都留痕，这个方法是那条要求的落点。
    func transition(_ category: LogCategory, from: String, to: String, reason: String) {
        write(category, .info, "状态迁移 \(from) → \(to)｜原因：\(reason)")
    }

    func snapshot() -> [LogEntry] {
        queue.sync { buffer }
    }

    /// 导出为纯文本，供 USB 取出或复制粘贴。
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        let header = "时刻 App 日志导出｜\(AppInfo.deviceModel) / iOS \(AppInfo.systemVersion)"
            + "｜版本 \(AppInfo.version)(\(AppInfo.build))｜commit \(BuildInfo.commit)"
        let body = snapshot()
            .map { "\(formatter.string(from: $0.at)) [\($0.level.rawValue)] [\($0.category.rawValue)] \($0.message)" }
            .joined(separator: "\n")
        return header + "\n" + String(repeating: "-", count: 60) + "\n" + body
    }

    func clear() {
        queue.async { [weak self] in
            self?.buffer.removeAll()
        }
    }

    private func write(_ category: LogCategory, _ level: LogLevel, _ message: String) {
        let entry = LogEntry(at: Date(), category: category, level: level, message: message)
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            // 环形缓冲：超出容量即丢弃最旧的，避免长时间录音把内存吃满
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
        }

        let line = "[\(category.rawValue)] \(message)"
        switch level {
        case .info:
            osLog.info("\(line, privacy: .public)")
        case .warn:
            osLog.warning("\(line, privacy: .public)")
        case .error:
            osLog.error("\(line, privacy: .public)")
        }
    }
}

/// 语法糖：`LogCategory.capture.log("...")`
extension LogCategory {
    func log(_ message: String) { Log.shared.info(self, message) }
    func warn(_ message: String) { Log.shared.warn(self, message) }
    func error(_ message: String) { Log.shared.error(self, message) }
}
