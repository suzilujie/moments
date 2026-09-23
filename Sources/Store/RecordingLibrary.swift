import Foundation

/// 录音库：音频目录与清单文件的读写（M1 的持久化层）。
///
/// 目录布局（设计文档 9.4）：
/// ```
/// Application Support/Moments/Audio/
/// └─ {sessionId}/
///    ├─ manifest.json      本次会话的清单
///    ├─ 000000.m4a         分片
///    └─ 000001.m4a
/// ```
///
/// 设计原则：**清单是音频的自描述**。任何时刻只要目录还在，
/// 就能还原出"这段音频是什么时候录的、有多长、哪里断了"。
final class RecordingLibrary {

    static let shared = RecordingLibrary()

    private let manifestFileName = "manifest.json"
    private let queue = DispatchQueue(label: "com.xfish.moments.library", qos: .utility)

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // 排序 + 缩进：清单是给人看的，真机排错时要能直接读
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder: JSONDecoder = JSONDecoder()

    // MARK: - 路径

    var rootDirectory: URL {
        (try? AppPaths.audioDirectory())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Audio")
    }

    func sessionDirectory(_ sessionId: String) -> URL {
        rootDirectory.appendingPathComponent(sessionId, isDirectory: true)
    }

    func segmentURL(sessionId: String, fileName: String) -> URL {
        sessionDirectory(sessionId).appendingPathComponent(fileName)
    }

    func makeSessionId() -> String {
        // 用时间戳 + 短随机串：可读、可排序、无碰撞风险
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "s\(stamp)-\(suffix)"
    }

    // MARK: - 清单读写

    /// 同步保存。会话结束与分片收尾时调用，必须保证落盘。
    func save(_ manifest: SessionManifest) throws {
        let directory = sessionDirectory(manifest.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(manifestFileName)
        let data = try encoder.encode(manifest)
        // 原子写：避免崩溃时留下半截 JSON（那会导致整次录音"读不出来"）
        try data.write(to: url, options: .atomic)
    }

    /// 异步保存（用于录音过程中的高频更新，不阻塞音频链路）
    func saveAsync(_ manifest: SessionManifest) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.save(manifest)
            } catch {
                Log.shared.error(.storage, "清单写入失败｜会话 \(manifest.id)｜\(error.localizedDescription)")
            }
        }
    }

    func loadManifest(sessionId: String) -> SessionManifest? {
        let url = sessionDirectory(sessionId).appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(SessionManifest.self, from: data)
        } catch {
            Log.shared.error(.storage, "清单解析失败｜会话 \(sessionId)｜\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 列表

    /// 列出全部会话，按开始时间倒序。
    /// M1 直接扫目录：几十到几百次会话的量级足够；M4 换 SQLite 后由数据库承担。
    func listSessions() -> [SessionManifest] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SessionManifest] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            if let manifest = loadManifest(sessionId: entry.lastPathComponent) {
                result.append(manifest)
            }
        }
        return result.sorted { $0.startedAtMs > $1.startedAtMs }
    }

    /// 找出"上次异常终止"的会话（设计文档 4.12）。
    ///
    /// 判定依据：清单里还是 `recording`，但本次启动并没有在录音。
    /// 这是无调试器环境下**唯一**能让用户把问题反馈清楚的入口 ——
    /// 因为被系统直接杀掉时不会触发 applicationWillTerminate，没有任何回调可依赖。
    func unfinishedSessions() -> [SessionManifest] {
        listSessions().filter { $0.state == .recording }
    }

    // MARK: - 删除与清理

    /// 完整删除一次会话（音频 + 清单）。
    func deleteSession(_ sessionId: String) throws {
        let directory = sessionDirectory(sessionId)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
            Log.shared.info(.storage, "已删除会话 \(sessionId)")
        }
    }

    /// 扫描目录，把"有音频文件但清单里没有"的分片补登进清单（设计文档 4.11 的孤儿修复）。
    /// - Returns: 补登的分片数
    @discardableResult
    func repairOrphanSegments(sessionId: String) -> Int {
        guard var manifest = loadManifest(sessionId: sessionId) else { return 0 }
        let directory = sessionDirectory(sessionId)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }

        let known = Set(manifest.segments.map { $0.fileName })
        var repaired = 0
        var repairedManifest = manifest

        for file in files where file.pathExtension == "m4a" {
            let name = file.lastPathComponent
            guard !known.contains(name) else { continue }
            let seq = Int(name.replacingOccurrences(of: ".m4a", with: "")) ?? repairedManifest.segments.count
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0

            // 用分片序号与既有清单后的时长推算时间范围（孤儿分片无法精确还原时间轴，
            // 但至少让它"可见"，而不是被静默忽略 —— 设计原则是让漏录可见）
            let previousEnd = repairedManifest.segments.last?.endMs ?? 0
            let estimateMs = Int(Double(bytes) / 4.0)  // 32 kbps ≈ 4 KB/s
            let entry = SessionManifest.SegmentEntry(
                seq: seq,
                fileName: name,
                startMs: previousEnd,
                endMs: previousEnd + estimateMs,
                sampleCount: estimateMs * 16,
                bytes: bytes
            )
            repairedManifest.segments.append(entry)
            repaired += 1
        }

        if repaired > 0 {
            repairedManifest.segments.sort { $0.seq < $1.seq }
            manifest.segments = repairedManifest.segments
            try? save(manifest)
            Log.shared.warn(.storage, "孤儿分片修复｜会话 \(sessionId)｜补登 \(repaired) 片")
        }
        return repaired
    }

    /// 按保留期清理音频文件（设计文档 4.5：**文本永久、音频有限**）。
    ///
    /// 注意：**只删音频文件，保留清单** —— 清单里仍记录了"这段录音存在过、有多长"，
    /// 后续 M2 的转写文本也挂在同一会话上。这实现了"只留文字、不留音频"。
    /// - Returns: (删除的分片数, 释放的字节数)
    @discardableResult
    func purgeExpiredAudio(retentionDays: Int) -> (segments: Int, bytes: Int) {
        guard retentionDays > 0 else { return (0, 0) }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        var deletedSegments = 0
        var freedBytes = 0

        for var manifest in listSessions() {
            guard manifest.startedAt < cutoff else { continue }
            var remaining: [SessionManifest.SegmentEntry] = []

            for segment in manifest.segments {
                let url = segmentURL(sessionId: manifest.id, fileName: segment.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    deletedSegments += 1
                    freedBytes += segment.bytes
                } catch {
                    remaining.append(segment)
                }
            }

            if remaining.count != manifest.segments.count {
                manifest.segments = remaining
                try? save(manifest)
            }
        }

        if deletedSegments > 0 {
            let freed = ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .file)
            Log.shared.info(
                .storage,
                "音频清理完成｜保留 \(retentionDays) 天｜删除 \(deletedSegments) 片｜释放 \(freed)｜清单与文字已保留"
            )
        }
        return (deletedSegments, freedBytes)
    }

    /// 统计音频总占用（自检页与设置页展示用）。
    func totalAudioBytes() -> Int {
        listSessions().reduce(0) { $0 + $1.totalBytes }
    }
}
