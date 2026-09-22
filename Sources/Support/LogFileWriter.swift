import Foundation

/// 日志落盘器：按天滚动、自动清理过期文件。
///
/// 为什么必须要它（设计文档 4.14 节）：
/// 日志只在内存环形缓冲里时，App 一旦被系统杀掉或崩溃，日志就随之消失。
/// 而本项目最需要诊断的场景恰恰是"设备在锁屏一段时间后停止录音" ——
/// 那时进程已经不在了，内存日志无从取证。**日志不能存活，观测能力就等于零。**
///
/// 设计原则：**日志失败绝不影响主链路**。
/// 写不进去只降级（记录错误、供自检页显示），绝不抛错、绝不阻塞调用方。
final class LogFileWriter {

    /// 日志保留天数，与音频保留期保持一致（设计文档 4.5）。
    private let retentionDays: Int

    private let queue = DispatchQueue(label: "com.xfish.moments.logfile", qos: .utility)
    private var currentDay = ""
    private var handle: FileHandle?
    private var currentURL: URL?

    /// 最近一次写入错误，供自检页展示（nil 表示正常）。
    private(set) var lastError: String?
    /// 已写入的行数，用于自检页判断"落盘是否真的在工作"。
    private(set) var writtenLines: Int = 0
    /// 是否已成功打开过文件。
    private(set) var isActive = false

    init(retentionDays: Int = 7) {
        self.retentionDays = retentionDays
    }

    var filePathText: String {
        let url = queue.sync { currentURL }
        guard let url else { return "未创建" }
        return AppPaths.shortPath(url)
    }

    var fileSizeText: String {
        let url = queue.sync { currentURL }
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return "-"
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    /// 异步追加一行。调用方不会被阻塞。
    func append(_ line: String) {
        queue.async { [weak self] in
            self?.appendLocked(line)
        }
    }

    /// 写一条醒目的分隔标记，用来把多次启动的日志区分开。
    /// 没有这个标记时，滚动文件里的内容会连成一片，无法判断"这一次启动到哪里结束"。
    func appendBanner(_ title: String) {
        let stamp = Self.bannerFormatter.string(from: Date())
        append("")
        append(String(repeating: "=", count: 60))
        append("\(stamp)  \(title)")
        append(String(repeating: "=", count: 60))
    }

    // MARK: - 内部实现

    private func appendLocked(_ line: String) {
        let day = Self.dayFormatter.string(from: Date())
        if day != currentDay {
            rotate(to: day)
        }
        guard let handle else { return }

        let text = "\(Self.lineFormatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }

        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            writtenLines += 1
            lastError = nil
        } catch {
            // 日志失败只降级，不抛出、不中断调用方
            lastError = error.localizedDescription
        }
    }

    private func rotate(to day: String) {
        try? handle?.close()
        handle = nil
        currentDay = day

        guard let dir = try? AppPaths.logsDirectory() else {
            lastError = "无法获取日志目录"
            return
        }

        let url = dir.appendingPathComponent("moments-\(day).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        do {
            let newHandle = try FileHandle(forWritingTo: url)
            handle = newHandle
            currentURL = url
            isActive = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isActive = false
        }

        purgeExpired(in: dir)
    }

    /// 删除超过保留期的日志文件。
    private func purgeExpired(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for file in files where file.lastPathComponent.hasPrefix("moments-")
            && file.pathExtension == "log" {
            let dayPart = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "moments-", with: "")
            guard let date = Self.dayFormatter.date(from: dayPart) else { continue }
            if date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - 格式化器（按天滚动必须用固定区域设置，否则日志会随系统区域变化）

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let bannerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
