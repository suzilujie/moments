import Foundation

/// 应用内的统一目录规划。
///
/// 集中在这里的原因：设计文档 9.4 节规定了目录布局，而日志、音频分片、模型
/// 三类数据的路径会被多个模块引用。分散拼接路径是"某个目录没被创建"这类
/// 低级故障的常见来源，因此统一收口并保证目录存在。
enum AppPaths {

    /// Application Support 下的应用根目录。
    /// 这是 Apple 推荐存放"用户数据、不应被随意清理"的位置（与 Documents 相比
    /// 不暴露给文件 App，与 Caches 相比不会被系统在空间紧张时回收）。
    static func appRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ensureDirectory(base.appendingPathComponent("Moments", isDirectory: true))
    }

    /// 日志目录（设计文档 4.14：日志必须能在 App 被杀后仍有留存）。
    static func logsDirectory() throws -> URL {
        try ensureDirectory(try appRoot().appendingPathComponent("Logs", isDirectory: true))
    }

    /// 音频分片目录（M1 使用，设计文档 9.4）。
    static func audioDirectory() throws -> URL {
        try ensureDirectory(try appRoot().appendingPathComponent("Audio", isDirectory: true))
    }

    /// 模型目录（M2 起使用，设计文档 5.5：模型不打进 ipa，运行时下载到这里）。
    static func modelsDirectory() throws -> URL {
        try ensureDirectory(try appRoot().appendingPathComponent("Models", isDirectory: true))
    }

    // MARK: - 已移除的两个目录（2026-10-17）

    /// `Speakers/`（声纹库）与 `Vocabulary/`（生词本）随对应功能一并删除
    /// （用户确认不需要），不再创建、也不再读写。
    ///
    /// **老用户设备上这两个目录仍然存在** —— 里面是用户过去积累的数据，
    /// 没有理由替他删掉；它们不再被任何代码引用，占用也很小。
    /// 今后若再引入"跨会话长期资产"，仍应遵循原来那条判据：
    /// **长期资产必须与音频目录分开**，否则按保留期清理音频时会连带删掉它。

    /// 目录的简短显示形式（完整路径太长，且沙盒路径对用户无意义）。
    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - 统一创建

    /// 统一的目录创建入口，**失败时必定留下一条错误日志**。
    ///
    /// 为什么值得收口：调用方大量使用 `try?`（"拿不到目录就算了"），
    /// 于是目录创建失败会退化成**静默不落盘** ——
    /// 用户看到的现象是"数据丢了 / 设置没保存 / 日志断了"，
    /// 而日志里一条线索都没有，真正的原因（沙盒异常、磁盘满、权限）
    /// 就永远查不出来了。
    ///
    /// 这里刻意**先记日志再抛出**：调用方仍然可以按自己的语义决定要不要继续，
    /// 但"发生过这件事"必须留在日志里。
    @discardableResult
    private static func ensureDirectory(_ url: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            Log.shared.error(
                .storage,
                "目录创建失败｜\(shortPath(url))｜\(error.localizedDescription)"
                    + "｜该目录下的数据将无法落盘（调用方多为 try? 会静默跳过）"
            )
            throw error
        }
    }
}
