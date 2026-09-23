import Foundation

/// 会话清单：一次录音的完整元数据，写在音频目录里（`{sessionId}/manifest.json`）。
///
/// ## 为什么 M1 用清单文件而不是 SQLite（对设计文档第 9 章的一处阶段性偏离）
///   1. **音频目录自带描述**：库文件丢了、写坏了，音频仍然能被正确解释；
///      这正好对应设计文档 4.11 要求的「孤儿分片修复」—— 有清单后这个问题几乎不存在。
///   2. M1 是最高风险里程碑，**少一个依赖就少一类故障**（SQLite 链接、迁移、并发）。
///   3. 清单是纯文本，真机排错时可以直接看 —— 这在没有调试器的环境里价值很高。
///
/// M4（存储检索）会换成 SQLite + FTS5 以支持全文检索；届时本结构体作为
/// 迁移来源保留，读取逻辑可复用。
///
/// 时间字段一律存 **Unix 毫秒**（中性时区），展示时换算本地时区 —— 遵循项目既有约定，
/// 避免存无时区字符串导致时区偏移误判。
struct SessionManifest: Codable {

    enum State: String, Codable {
        /// 正在录音（异常退出后仍是这个值 —— 用于 App 强杀恢复识别）
        case recording
        /// 正常结束
        case done
        /// 因失败结束
        case failed
    }

    var id: String
    var title: String
    var startedAtMs: Int64
    var endedAtMs: Int64?
    var state: State
    var source: String
    var nativeSampleRate: Double
    var segmentSeconds: Int
    var bitRate: Int
    var segments: [SegmentEntry]
    var gaps: [GapEntry]
    var note: String?

    struct SegmentEntry: Codable {
        var seq: Int
        var fileName: String
        var startMs: Int
        var endMs: Int
        var sampleCount: Int
        var bytes: Int
    }

    struct GapEntry: Codable {
        var startMs: Int
        var endMs: Int
        var reason: String

        var durationMs: Int { max(0, endMs - startMs) }
    }

    // MARK: - 派生属性

    var startedAt: Date {
        Date(timeIntervalSince1970: Double(startedAtMs) / 1000.0)
    }

    /// 按**样本计数**推导的已录时长（设计文档 4.11：不依赖墙钟）
    var recordedMs: Int {
        segments.last?.endMs ?? 0
    }

    /// 墙钟时长（用于与已录时长对比，差值即中断造成的损失）
    var wallClockMs: Int {
        let endMs = endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        return Int(max(0, endMs - startedAtMs))
    }

    var totalBytes: Int {
        segments.reduce(0) { $0 + $1.bytes }
    }

    var hasGap: Bool { !gaps.isEmpty }

    var totalGapMs: Int {
        gaps.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
    }

    /// 中断造成的损失占比（用于判断这次录音是否还需要重录）
    var lossRatio: Double {
        let wall = wallClockMs
        guard wall > 0 else { return 0 }
        return Double(totalGapMs) / Double(wall)
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    func durationText() -> String {
        let seconds = recordedMs / 1000
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
