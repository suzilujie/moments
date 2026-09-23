import Foundation

/// 一次检索命中（M4 换成 FTS5 之前，先用内存扫描实现最小可用检索）。
struct TranscriptHit: Identifiable {
    let id = UUID()
    let sessionId: String
    let pass: TranscriptPass
    let segment: TranscriptSegment
    /// 命中句所在会话的开始时间（用于列表排序与展示）
    let sessionStartedAtMs: Int64
}

/// 转写稿的持久化层。
///
/// 目录布局（与 M1 的清单同处一个会话目录，保持"音频目录自带全部解释"这一性质）：
/// ```
/// Application Support/Moments/Audio/{sessionId}/
/// ├─ manifest.json
/// ├─ transcript-live.json      实时稿
/// ├─ transcript-final.json     终稿
/// └─ 000000.m4a
/// ```
///
/// **为什么要分两个文件而不是一个文件里放两稿**：
/// 终稿是事后批量补跑的，若与实时稿共用一个文件，
/// 写终稿就要读取+重写整份实时稿 —— 一旦中途失败，连实时稿一起损坏。
/// 分开后两稿互不影响：终稿写坏了，实时稿仍然完整可读。
final class TranscriptStore {

    static let shared = TranscriptStore()

    private let queue = DispatchQueue(label: "com.xfish.moments.transcript.store", qos: .utility)
    private let fileManager = FileManager.default

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder: JSONDecoder = JSONDecoder()

    private init() {}

    // MARK: - 路径

    private func fileName(for pass: TranscriptPass) -> String {
        "transcript-\(pass.rawValue).json"
    }

    func url(sessionId: String, pass: TranscriptPass) -> URL {
        RecordingLibrary.shared
            .sessionDirectory(sessionId)
            .appendingPathComponent(fileName(for: pass))
    }

    // MARK: - 读写

    func save(_ document: TranscriptDocument) throws {
        let target = url(sessionId: document.sessionId, pass: document.pass)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        // 原子写：转写是长任务，中途被系统杀掉时不能留下半截 JSON
        try data.write(to: target, options: .atomic)
    }

    /// 异步保存（用于实时稿的高频更新，不阻塞转写线程）
    func saveAsync(_ document: TranscriptDocument) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.save(document)
            } catch {
                Log.shared.error(
                    .storage,
                    "转写稿写入失败｜\(document.sessionId)/\(document.pass.rawValue)"
                        + "｜\(error.localizedDescription)"
                )
            }
        }
    }

    func load(sessionId: String, pass: TranscriptPass) -> TranscriptDocument? {
        let target = url(sessionId: sessionId, pass: pass)
        guard let data = try? Data(contentsOf: target) else { return nil }
        do {
            return try decoder.decode(TranscriptDocument.self, from: data)
        } catch {
            Log.shared.error(
                .storage,
                "转写稿解析失败｜\(sessionId)/\(pass.rawValue)｜\(error.localizedDescription)"
            )
            return nil
        }
    }

    func exists(sessionId: String, pass: TranscriptPass) -> Bool {
        fileManager.fileExists(atPath: url(sessionId: sessionId, pass: pass).path)
    }

    /// 有终稿时优先用终稿 —— 这一条判断被多处 UI 复用，收口在此避免各处写错。
    /// 依据：终稿是更大模型事后跑的稳定结果，比会被反复改写的实时稿更可信（设计文档 5.4）。
    func preferredDocument(sessionId: String) -> TranscriptDocument? {
        load(sessionId: sessionId, pass: .final) ?? load(sessionId: sessionId, pass: .live)
    }

    // MARK: - 删除与统计

    func delete(sessionId: String, pass: TranscriptPass) {
        let target = url(sessionId: sessionId, pass: pass)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.removeItem(at: target)
        Log.shared.info(.storage, "已删除\(pass.title)｜\(sessionId)")
    }

    func deleteAll(sessionId: String) {
        for pass in TranscriptPass.allCases {
            delete(sessionId: sessionId, pass: pass)
        }
    }

    /// 清空全部转写稿（设置页的"只留音频、删掉文字"入口）。
    /// - Returns: 删除的文件数
    @discardableResult
    func deleteAllTranscripts() -> Int {
        var deleted = 0
        for manifest in RecordingLibrary.shared.listSessions() {
            for pass in TranscriptPass.allCases where exists(sessionId: manifest.id, pass: pass) {
                delete(sessionId: manifest.id, pass: pass)
                deleted += 1
            }
        }
        if deleted > 0 {
            Log.shared.warn(.storage, "已清空全部转写稿｜删除 \(deleted) 份")
        }
        return deleted
    }

    func totalCharacterCount() -> Int {
        var total = 0
        for manifest in RecordingLibrary.shared.listSessions() {
            guard let document = preferredDocument(sessionId: manifest.id) else { continue }
            total += document.characterCount
        }
        return total
    }

    /// 已转写的会话数 / 总会话数（自检页与设置页展示"转写覆盖率"用）
    func coverage() -> (transcribed: Int, total: Int) {
        let sessions = RecordingLibrary.shared.listSessions()
        let transcribed = sessions.filter { preferredDocument(sessionId: $0.id) != nil }.count
        return (transcribed, sessions.count)
    }

    // MARK: - 检索（M4 换 SQLite + FTS5 后由数据库承担）

    /// 全文扫描检索。
    ///
    /// 当前实现是内存全扫：几十到几百次会话的量级完全够用，
    /// 且**不引入额外依赖**（M1/M2 的原则是少一个依赖就少一类故障）。
    /// 缺点很明确：会话数上千、文本上百万字后会明显变慢 —— 这正是 M4 要换成 FTS5 的原因。
    func search(_ query: String, limit: Int = 100) -> [TranscriptHit] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return [] }

        var hits: [TranscriptHit] = []
        for manifest in RecordingLibrary.shared.listSessions() {
            for pass in TranscriptPass.allCases {
                guard let document = load(sessionId: manifest.id, pass: pass) else { continue }
                for segment in document.segments {
                    guard segment.text.lowercased().contains(keyword) else { continue }
                    hits.append(
                        TranscriptHit(
                            sessionId: manifest.id,
                            pass: pass,
                            segment: segment,
                            sessionStartedAtMs: manifest.startedAtMs
                        )
                    )
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits.sorted { $0.sessionStartedAtMs > $1.sessionStartedAtMs }
    }
}
