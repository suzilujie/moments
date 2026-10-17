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
    case route
    case interrupt
    case thermal
    case disk
    case storage
    case system
    /// M2 起：转写（模型加载、转写耗时与实时倍率）
    case asr
    /// M2 起：模型下载与校验
    case model
    /// M5 起：翻译（语言可用性、批量翻译、缓存）
    case translate
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

/// 结构化日志：内存环形缓冲 + 落盘 + 系统日志，三条通道并存。
///
/// 三条通道各自解决不同问题（缺一不可）：
/// - **内存缓冲**：应用内日志面板实时查看，不用连电脑
/// - **落盘文件**：App 被系统杀掉或崩溃后仍能取证 —— 这是本项目最关键的一条，
///   因为最需要诊断的场景（锁屏后停录）发生时，进程已经不在了
/// - **系统日志**：`idevicesyslog` 可在 App 还没启动完成时就看到输出
final class Log {

    static let shared = Log()

    private let capacity: Int
    private var buffer: [LogEntry] = []
    private let queue = DispatchQueue(label: "com.xfish.moments.log")
    private let osLog = os.Logger(subsystem: "com.xfish.moments", category: "Moments")
    private let fileWriter = LogFileWriter()

    init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    // MARK: - 写入口

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

    /// 分段标记：把不同次启动、不同阶段在滚动日志文件里隔开。
    /// 没有它，按天滚动的文件里内容会连成一片，无法判断边界。
    func banner(_ title: String) {
        fileWriter.appendBanner(title)
        write(.app, .info, "── \(title) ──")
    }

    // MARK: - 读取与导出

    func snapshot() -> [LogEntry] {
        queue.sync { buffer }
    }

    /// 导出为纯文本，供 USB 取出或复制粘贴。
    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
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

    // MARK: - 落盘状态（供自检页确认"日志真的写进去了"）

    var filePathText: String { fileWriter.filePathText }
    var fileSizeText: String { fileWriter.fileSizeText }
    var fileWrittenLines: Int { fileWriter.writtenLines }
    var fileErrorText: String? { fileWriter.lastError }
    var isFileActive: Bool { fileWriter.isActive }

    // MARK: - 内部实现

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

        // 落盘：异步，且失败只降级（LogFileWriter 内部保证不抛出）
        fileWriter.append("[\(level.rawValue)] [\(category.rawValue)] \(message)")

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

/// 把 OSStatus 数值转成四字符码（如 `-50` → `'param'`），便于对照 AudioToolbox 常量。
private func fourCharCode(_ value: Int32) -> String {
    let bytes = [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value)
    ]
    guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "\(value)" }
    return String(bytes: bytes, encoding: .ascii).map { "'\($0)'" } ?? "\(value)"
}

extension Error {
    /// 诊断文本：把 NSError 的 domain / code / OSStatus 四字符码 / 底层错误全部展开。
    ///
    /// ## 为什么不能只用 localizedDescription
    /// AVFoundation 抛出的错误常常只有一句「操作无法完成」，真正的判据（OSStatus 码、
    /// 底层 NSCocoaError）全在 `userInfo` 里。日志里丢掉这两个字段，事后就再也分不清
    /// 是磁盘满、权限不足，还是编码器状态错误 —— 只能反复复现，成本极高。
    var diagnosticText: String {
        let ns = self as NSError
        var parts: [String] = ["\(ns.domain)#\(ns.code)"]

        if ns.domain == NSOSStatusErrorDomain {
            parts.append("OSStatus \(fourCharCode(Int32(truncatingIfNeeded: ns.code)))")
        }

        let description = ns.localizedDescription
        if !description.isEmpty {
            parts.append(description)
        }

        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("底层 \(underlying.domain)#\(underlying.code)")
        }
        return parts.joined(separator: "｜")
    }
}
