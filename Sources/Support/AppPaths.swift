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
        let root = base.appendingPathComponent("Moments", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 日志目录（设计文档 4.14：日志必须能在 App 被杀后仍有留存）。
    static func logsDirectory() throws -> URL {
        let dir = try appRoot().appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 音频分片目录（M1 使用，设计文档 9.4）。
    static func audioDirectory() throws -> URL {
        let dir = try appRoot().appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 模型目录（M2 起使用，设计文档 5.5：模型不打进 ipa，运行时下载到这里）。
    static func modelsDirectory() throws -> URL {
        let dir = try appRoot().appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 声纹库目录（M3c 起使用）。
    ///
    /// 刻意与音频目录**分开**存放：声纹库是跨会话的长期资产，
    /// 而音频会按保留期被清理。若混在一起，清理音频时就可能连带
    /// 把声纹库一起删掉 —— 那是用户最不可接受的损失（录音可重录，声纹积累不可重建）。
    static func speakersDirectory() throws -> URL {
        let dir = try appRoot().appendingPathComponent("Speakers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 目录的简短显示形式（完整路径太长，且沙盒路径对用户无意义）。
    static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
