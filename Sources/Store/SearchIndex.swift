import Foundation

/// 一条检索命中。
struct SearchHit: Identifiable {
    let id: String
    let sessionId: String
    let sessionTitle: String
    let sessionStartedAtMs: Int64
    let pass: TranscriptPass
    let startMs: Int
    let endMs: Int
    let text: String
    /// 该行是哪种文本：空字符串 = 原文（转写），否则是译文的目标语言代码。
    ///
    /// 原文与译文放在同一张表里，是为了让检索**一份索引覆盖两种文本**（设计文档 7.4
    /// 要求"支持在原文与译文中搜索"）。用一列区分，比建两套索引简单得多。
    let lang: String

    var isTranslation: Bool { !lang.isEmpty }

    var languageText: String {
        isTranslation ? "\(TranslationLanguageCatalog.name(for: lang))译文" : ""
    }

    /// 命中句在会话内的相对时间（列表展示用）
    var timeText: String {
        let totalSeconds = max(0, startMs) / 1000
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// 全文检索索引（M4）。
///
/// ## 架构定位：数据库是**可从磁盘重建的索引**，不是唯一真相
/// 每次会话的真相仍留在会话目录里的 JSON 文件（manifest / transcript），
/// 数据库只是它们的**查询层**。这样做的收益很实际：
///   · 数据库损坏、schema 改错、升级出问题 —— 删库重扫即可恢复，**不会丢用户数据**
///   · 音频目录依旧"自带解释自己的能力"（M1 定下的性质），不因引入数据库而失效
/// 代价是写入要写两处（JSON 保真、DB 供查），但两者职责清晰、不会互相污染。
///
/// ## 为什么必须运行期探测 FTS5
/// iOS 的系统 SQLite 是否编译了 FTS5 **没有公开保证**。
/// 探测失败时本类降级为 `LIKE` 扫描：功能仍可用、只是慢。
/// 这比"假定它有"然后整块检索功能失效要好得多。
/// `@unchecked Sendable` 是**刻意的、有依据的**声明，不是为了让编译安静：
///   · 本类全部可变状态（database 与两张表）**只在 `queue` 这条串行队列上访问**；
///   · `@Published` 属性的写入一律经 `publish`，它内部用 `Task { @MainActor in }` 回到主线程；
///   · 因此跨线程共享这个对象是安全的 —— 安全性的来源是"串行队列 + 主线程发布"，
///     而不是编译器能推断出来的那些性质。
/// 若不声明它，在 `queue.async` 里捕获 self 会产生
/// 「capture of 'self' with non-sendable type」告警（Swift 6 下是错误），
/// 而我们又无法靠拆参数绕开（搜索路径本身就需要访问 database）。
final class SearchIndex: ObservableObject, @unchecked Sendable {

    static let shared = SearchIndex()

    enum Capability: String {
        /// 尚未探测完成。
        ///
        /// **必须与 `unavailable` 分开**：能力是在后台队列上探测、再经
        /// `Task { @MainActor in }` 异步发布回来的，因此任何**同步**读它的代码
        ///（例如 AppDelegate 的启动摘要）拿到的必然是初始值。
        /// 原先初始值就是 `.unavailable`，于是真机日志里出现了自相矛盾的两行：
        ///   「检索索引就绪｜SQLite 3.51.0｜能力 LIKE 扫描（降级）」← 实测结果
        ///   「检索索引｜不可用」                                      ← 尚未探测
        /// 而排查者读到后者，只会以为检索整体坏了。
        case unknown
        /// 系统 SQLite 带 FTS5，走真正的全文索引
        case fts5
        /// 无 FTS5，降级为 LIKE 扫描
        case likeFallback
        /// 数据库都打不开
        case unavailable

        var title: String {
            switch self {
            case .unknown: return "尚未探测"
            case .fts5: return "FTS5 全文索引"
            case .likeFallback: return "LIKE 扫描（降级）"
            case .unavailable: return "不可用"
            }
        }

        var detail: String {
            switch self {
            case .unknown:
                return "索引能力在后台探测中，结果由 storage 类别的日志给出"
            case .fts5:
                return "中文用 trigram 分词，任意子串都能命中，且随文本量增长仍保持速度"
            case .likeFallback:
                return "系统 SQLite 未编译 FTS5，已自动降级为全表扫描。功能可用，但会话很多时会变慢"
            case .unavailable:
                return "数据库无法打开，检索不可用；转录与音频不受影响"
            }
        }
    }

    @Published private(set) var capability: Capability = .unknown
    @Published private(set) var sqliteVersion = "-"
    @Published private(set) var indexedSessions = 0
    @Published private(set) var indexedSegments = 0
    @Published private(set) var lastMessage: String?

    /// 所有数据库访问都在这条串行队列上（SQLite 单连接不适合并发）
    private let queue = DispatchQueue(label: "com.xfish.moments.search", qos: .utility)
    private var database: Database?

    private init() {}

    // MARK: - 生命周期

    /// 打开数据库、建表，并在需要时从磁盘全量重建。
    ///
    /// 在 App 启动时调用一次即可。它**不阻塞启动**：全部工作在后台队列上完成，
    /// 完成后把状态发布到主线程。
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.openLocked()
            self.refreshCountsLocked()

            // 空库（首次安装、或用户升级到 M4）→ 全量重建。
            // 不要求用户做任何操作：检索应该是打开就有用的。
            if self.indexedSegments == 0 {
                self.rebuildFromDiskLocked()
            }
        }
    }

    private func openLocked() {
        guard database == nil else { return }
        guard let root = try? AppPaths.appRoot() else {
            publish { $0.capability = .unavailable }
            return
        }
        let url = root.appendingPathComponent("moments.sqlite3")
        // 注意：Database 的 init 不是可失败初始化器（它把失败记在 isOpen/lastErrorMessage 上），
        // 因此这里**不能**写 `guard let db = Database(...)`
        let db = Database(path: url.path)
        guard db.isOpen else {
            let message = "数据库打开失败：\(db.lastErrorMessage)"
            Log.shared.error(.storage, "检索数据库打开失败｜\(message)")
            publish { $0.capability = .unavailable; $0.lastMessage = message }
            return
        }
        database = db

        let version = db.sqliteVersion
        let hasFTS5 = db.supportsFTS5

        // 建表：先建两张普通表，再尝试建 FTS5 虚表
        let baseStatements = [
            """
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER,
              state TEXT NOT NULL,
              source TEXT NOT NULL,
              segment_count INTEGER NOT NULL DEFAULT 0,
              recorded_ms INTEGER NOT NULL DEFAULT 0,
              gap_count INTEGER NOT NULL DEFAULT 0,
              total_bytes INTEGER NOT NULL DEFAULT 0,
              updated_at_ms INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS segments (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              pass TEXT NOT NULL,
              seq INTEGER NOT NULL,
              start_ms INTEGER NOT NULL,
              end_ms INTEGER NOT NULL,
              text TEXT NOT NULL,
              is_provisional INTEGER NOT NULL DEFAULT 0,
              lang TEXT NOT NULL DEFAULT ''
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_segments_session ON segments(session_id);",
            "CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at_ms DESC);"
        ]
        _ = db.executeAll(baseStatements)

        // 迁移：v1 → v2 增加 lang 列（M5 起译文与原文共用一张表）。
        // 老库需要 ALTER；新库的建表语句已含该列，ALTER 会失败并被忽略 ——
        // 两种情况都要能通过，所以这里**不看返回值**，只看版本号是否推进。
        let schemaVersion = db.scalarInt("PRAGMA user_version;") ?? 0
        if schemaVersion < 2 {
            _ = db.execute("ALTER TABLE segments ADD COLUMN lang TEXT NOT NULL DEFAULT '';")
            _ = db.execute("PRAGMA user_version = 2;")
            Log.shared.info(.storage, "检索库已迁移至 schema v2（新增 lang 列）")
        }

        var resolved: Capability = .likeFallback
        if hasFTS5 {
            // 外部内容表 + trigram 分词：
            //   · 外部内容表：文本只在 segments 里存一份，FTS 表不重复占空间
            //   · trigram：中文没有空格，按三元组切分才能做子串检索
            let ftsStatements = [
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
                  text,
                  content='segments',
                  content_rowid='rowid',
                  tokenize='trigram'
                );
                """
            ]
            if db.executeAll(ftsStatements) {
                resolved = .fts5
            } else {
                Log.shared.warn(.storage, "FTS5 虚表创建失败，降级为 LIKE 扫描｜\(db.lastErrorMessage)")
            }
        } else {
            Log.shared.warn(.storage, "系统 SQLite 未编译 FTS5，降级为 LIKE 扫描")
        }

        publish {
            $0.capability = resolved
            $0.sqliteVersion = version
        }
        Log.shared.info(.storage, "检索索引就绪｜SQLite \(version)｜能力 \(resolved.title)")
    }

    // MARK: - 写入

    /// 索引（或重新索引）一次会话。
    /// 转写完成、或说话人时间轴更新后调用。
    func index(sessionId: String) {
        guard let manifest = RecordingLibrary.shared.loadManifest(sessionId: sessionId) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.openLocked()
            self.indexLocked(manifest)
            self.refreshCountsLocked()
        }
    }

    func remove(sessionId: String) {
        queue.async { [weak self] in
            guard let self, let database = self.database else { return }
            if let statement = database.prepare("DELETE FROM segments WHERE session_id = ?;") {
                statement.bind(1, sessionId)
                _ = statement.step()
                statement.finalize()
            }
            if let statement = database.prepare("DELETE FROM sessions WHERE id = ?;") {
                statement.bind(1, sessionId)
                _ = statement.step()
                statement.finalize()
            }
            self.rebuildFTSLocked()
            self.refreshCountsLocked()
            Log.shared.info(.storage, "检索索引已移除会话｜\(sessionId)")
        }
    }

    /// 从磁盘全量重建。**这是本设计的核心保障**：
    /// 数据库可以随时丢掉再从 JSON 重建，因此它坏了不会造成数据损失。
    func rebuildFromDisk() {
        queue.async { [weak self] in
            guard let self else { return }
            self.openLocked()
            self.rebuildFromDiskLocked()
        }
    }

    private func rebuildFromDiskLocked() {
        guard let database else { return }
        let started = Date()

        _ = database.inTransaction {
            _ = database.execute("DELETE FROM segments;")
            _ = database.execute("DELETE FROM sessions;")
            for manifest in RecordingLibrary.shared.listSessions() {
                indexLocked(manifest)
            }
            return true
        }
        rebuildFTSLocked()
        refreshCountsLocked()

        let costMs = Int(Date().timeIntervalSince(started) * 1000)
        let sessions = indexedSessions
        let segments = indexedSegments
        let summary = "索引重建完成｜\(sessions) 次会话｜\(segments) 句｜耗时 \(costMs)ms"
        publish { $0.lastMessage = summary }
        Log.shared.info(.storage, summary)
    }

    /// 单次会话的写入（仅在 queue 上调用）。
    private func indexLocked(_ manifest: SessionManifest) {
        guard let database else { return }

        let sessionSQL = """
        INSERT INTO sessions (id, title, started_at_ms, ended_at_ms, state, source,
                              segment_count, recorded_ms, gap_count, total_bytes, updated_at_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          title=excluded.title, ended_at_ms=excluded.ended_at_ms, state=excluded.state,
          segment_count=excluded.segment_count, recorded_ms=excluded.recorded_ms,
          gap_count=excluded.gap_count, total_bytes=excluded.total_bytes,
          updated_at_ms=excluded.updated_at_ms;
        """
        if let statement = database.prepare(sessionSQL) {
            statement.bind(1, manifest.id)
            statement.bind(2, manifest.title)
            statement.bind(3, manifest.startedAtMs)
            if let ended = manifest.endedAtMs {
                statement.bind(4, ended)
            } else {
                statement.bindNull(4)
            }
            statement.bind(5, manifest.state.rawValue)
            statement.bind(6, manifest.source)
            statement.bind(7, manifest.segments.count)
            statement.bind(8, manifest.recordedMs)
            statement.bind(9, manifest.gaps.count)
            statement.bind(10, manifest.totalBytes)
            statement.bind(11, Int64(Date().timeIntervalSince1970 * 1000))
            _ = statement.step()
            statement.finalize()
        }

        // 先删后插：幂等，重复索引同一会话不会产生重复行
        if let statement = database.prepare("DELETE FROM segments WHERE session_id = ?;") {
            statement.bind(1, manifest.id)
            _ = statement.step()
            statement.finalize()
        }

        let insertSQL = """
        INSERT INTO segments (id, session_id, pass, seq, start_ms, end_ms, text, is_provisional, lang)
        VALUES (?,?,?,?,?,?,?,?,?);
        """
        guard let insert = database.prepare(insertSQL) else { return }

        var segmentIndex: [String: TranscriptSegment] = [:]

        for pass in TranscriptPass.allCases {
            guard let document = TranscriptStore.shared.load(sessionId: manifest.id, pass: pass) else { continue }
            for segment in document.segments {
                insert.reset()
                insert.bind(1, segment.id)
                insert.bind(2, manifest.id)
                insert.bind(3, pass.rawValue)
                insert.bind(4, segment.seq)
                insert.bind(5, segment.startMs)
                insert.bind(6, segment.endMs)
                insert.bind(7, segment.text)
                insert.bind(8, segment.isProvisional ? 1 : 0)
                insert.bind(9, "")      // 原文：lang 留空
                _ = insert.step()

                // 供下面的译文行复用时间戳（片段 id 在不同稿之间可能重复，故带上稿别）
                segmentIndex["\(pass.rawValue)|\(segment.id)"] = segment
            }
        }

        // 译文也进**同一张表**（lang = 目标语言）。
        // 这样"在原文与译文中搜索"只需要一份索引，不必建第二套 FTS 表。
        // 时间戳沿用原文片段的，因此点译文命中也能直接跳到对应的音频位置。
        let translations = TranslationStore.shared.load(sessionId: manifest.id)
        for entry in translations.entries {
            guard let source = segmentIndex["\(entry.pass.rawValue)|\(entry.segmentId)"] else { continue }
            insert.reset()
            insert.bind(1, "\(entry.segmentId)@\(entry.targetLang)")
            insert.bind(2, manifest.id)
            insert.bind(3, entry.pass.rawValue)
            insert.bind(4, source.seq)
            insert.bind(5, source.startMs)
            insert.bind(6, source.endMs)
            insert.bind(7, entry.text)
            insert.bind(8, 0)
            insert.bind(9, entry.targetLang)
            _ = insert.step()
        }

        insert.finalize()
    }

    /// 重建 FTS 索引。外部内容表模式下这比逐行插入更可靠
    /// （也顺带解决了"分段被删改后索引不同步"的问题）。
    private func rebuildFTSLocked() {
        guard capability == .fts5, let database else { return }
        if !database.execute("INSERT INTO segments_fts(segments_fts) VALUES('rebuild');") {
            Log.shared.warn(.storage, "FTS 索引重建失败｜\(database.lastErrorMessage)")
        }
    }

    private func refreshCountsLocked() {
        guard let database else { return }
        let sessions = database.scalarInt("SELECT COUNT(*) FROM sessions;") ?? 0
        let segments = database.scalarInt("SELECT COUNT(*) FROM segments;") ?? 0
        publish {
            $0.indexedSessions = sessions
            $0.indexedSegments = segments
        }
    }

    // MARK: - 检索

    /// 检索。**在后台队列执行**，因此不会卡住输入。
    func search(_ query: String, limit: Int = 200) async -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: [])
                    return
                }
                self.openLocked()
                continuation.resume(returning: self.performSearchLocked(trimmed, limit: limit))
            }
        }
    }

    private func performSearchLocked(_ query: String, limit: Int) -> [SearchHit] {
        guard let database else { return [] }

        let sql: String
        var boundQuery = query
        if capability == .fts5 {
            // 用双引号包成短语：FTS5 的查询语法里 * " - 等都是操作符，
            // 用户随手输入的字符很容易构成非法表达式（那会直接报错而不是"没结果"）。
            // 包成短语后按字面匹配，也正好符合"搜子串"的直觉。
            boundQuery = Self.ftsPhrase(query)
            sql = """
            SELECT s.id, s.session_id, s.pass, s.start_ms, s.end_ms, s.text, se.title, se.started_at_ms, s.lang
            FROM segments_fts f
            JOIN segments s ON s.rowid = f.rowid
            JOIN sessions se ON se.id = s.session_id
            WHERE segments_fts MATCH ?
            ORDER BY se.started_at_ms DESC, s.start_ms ASC
            LIMIT ?;
            """
        } else {
            boundQuery = "%\(query)%"
            sql = """
            SELECT s.id, s.session_id, s.pass, s.start_ms, s.end_ms, s.text, se.title, se.started_at_ms, s.lang
            FROM segments s
            JOIN sessions se ON se.id = s.session_id
            WHERE s.text LIKE ?
            ORDER BY se.started_at_ms DESC, s.start_ms ASC
            LIMIT ?;
            """
        }

        guard let statement = database.prepare(sql) else {
            Log.shared.error(.storage, "检索语句准备失败｜\(database.lastErrorMessage)")
            return []
        }
        defer { statement.finalize() }

        statement.bind(1, boundQuery)
        statement.bind(2, limit)

        var hits: [SearchHit] = []
        while statement.step() {
            guard let id = statement.string(0),
                  let sessionId = statement.string(1),
                  let passRaw = statement.string(2),
                  let text = statement.string(5) else { continue }
            hits.append(
                SearchHit(
                    id: id,
                    sessionId: sessionId,
                    sessionTitle: statement.string(6) ?? "（无标题）",
                    sessionStartedAtMs: statement.int64(7),
                    pass: TranscriptPass(rawValue: passRaw) ?? .final,
                    startMs: statement.int(3),
                    endMs: statement.int(4),
                    text: text,
                    lang: statement.string(8) ?? ""
                )
            )
        }
        return hits
    }

    /// 把用户输入转成 FTS5 短语查询（转义内部双引号）。
    static func ftsPhrase(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - 自检

    /// 数据库与检索的自检。
    ///
    /// **为什么必须有它**：本项目的 CI 只能验证"能编译、能链接"，
    /// **运行期的 SQL 错误它一条都抓不到**（跑不了 iOS App）。
    /// schema 写错、FTS5 虚表建不起来、LIKE 参数绑定错 —— 这些都不会让构建失败，
    /// 只会在用户点下搜索时安静地什么也不返回。
    ///
    /// 因此把"用内存库跑一遍真实 SQL"做成一个能在设备上直接点的自检：
    /// 它用**与正式代码同一套语句**建表、插入、检索，并逐条报告结果。
    ///
    /// 用内存库（`:memory:`）是刻意的：绝不碰用户数据。
    func selfTest() -> [String] {
        var lines: [String] = []

        let test = Database(path: ":memory:")
        guard test.isOpen else {
            return ["✗ 打开内存数据库失败：\(test.lastErrorMessage)"]
        }
        defer { test.close() }

        lines.append("SQLite 版本：\(test.sqliteVersion)")
        lines.append("FTS5 编译选项：\(test.supportsFTS5 ? "已启用" : "未启用（正式库会降级为 LIKE）")")

        // 1) 建表（与正式代码同一套语句）
        let schema = [
            """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, title TEXT NOT NULL, started_at_ms INTEGER NOT NULL,
              ended_at_ms INTEGER, state TEXT NOT NULL, source TEXT NOT NULL,
              segment_count INTEGER NOT NULL DEFAULT 0, recorded_ms INTEGER NOT NULL DEFAULT 0,
              gap_count INTEGER NOT NULL DEFAULT 0, total_bytes INTEGER NOT NULL DEFAULT 0,
              updated_at_ms INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE segments (
              id TEXT PRIMARY KEY, session_id TEXT NOT NULL, pass TEXT NOT NULL,
              seq INTEGER NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
              text TEXT NOT NULL, is_provisional INTEGER NOT NULL DEFAULT 0,
              lang TEXT NOT NULL DEFAULT ''
            );
            """
        ]
        lines.append(test.executeAll(schema) ? "✓ 建表" : "✗ 建表失败：\(test.lastErrorMessage)")

        // 2) 插入一条会话与两句转写（含中文、引号、换行 —— 最容易出问题的字符）
        guard let sessionInsert = test.prepare("INSERT INTO sessions (id,title,started_at_ms,state,source,updated_at_ms) VALUES (?,?,?,?,?,?);") else {
            lines.append("✗ 会话插入语句准备失败")
            return lines
        }
        sessionInsert.bind(1, "selftest")
        sessionInsert.bind(2, "自检会话")
        sessionInsert.bind(3, Int64(1_700_000_000_000))
        sessionInsert.bind(4, "done")
        sessionInsert.bind(5, "microphone")
        sessionInsert.bind(6, Int64(1_700_000_000_000))
        _ = sessionInsert.step()
        sessionInsert.finalize()

        let trickyText = "他说：\"报销\"要走流程\n下周再谈"
        guard let segmentInsert = test.prepare("INSERT INTO segments (id,session_id,pass,seq,start_ms,end_ms,text,is_provisional) VALUES (?,?,?,?,?,?,?,?);") else {
            lines.append("✗ 分句插入语句准备失败")
            return lines
        }
        for (index, text) in ["我们下周讨论报销的事", trickyText].enumerated() {
            segmentInsert.reset()
            segmentInsert.bind(1, "seg-\(index)")
            segmentInsert.bind(2, "selftest")
            segmentInsert.bind(3, "final")
            segmentInsert.bind(4, index)
            segmentInsert.bind(5, index * 3000)
            segmentInsert.bind(6, index * 3000 + 2500)
            segmentInsert.bind(7, text)
            segmentInsert.bind(8, 0)
            _ = segmentInsert.step()
        }
        segmentInsert.finalize()

        let count = test.scalarInt("SELECT COUNT(*) FROM segments;") ?? -1
        lines.append(count == 2 ? "✓ 写入分段（含引号与换行）" : "✗ 写入分段异常：count=\(count)")

        // 3) FTS5 建虚表 + 重建 + 中文子串检索
        if test.supportsFTS5 {
            let ftsOK = test.execute("""
            CREATE VIRTUAL TABLE segments_fts USING fts5(
              text, content='segments', content_rowid='rowid', tokenize='trigram'
            );
            """)
            lines.append(ftsOK ? "✓ 创建 FTS5 虚表（trigram 分词）" : "✗ 创建 FTS5 虚表失败：\(test.lastErrorMessage)")
            if ftsOK {
                let rebuildOK = test.execute("INSERT INTO segments_fts(segments_fts) VALUES('rebuild');")
                lines.append(rebuildOK ? "✓ 重建 FTS 索引" : "✗ 重建 FTS 索引失败：\(test.lastErrorMessage)")

                let hits = countFTSHits(test, query: SearchIndex.ftsPhrase("报销"))
                lines.append(hits == 1 ? "✓ 中文子串检索命中 1 条" : "✗ 中文子串检索异常：命中 \(hits) 条")
            }
        } else {
            lines.append("· 跳过 FTS5 用例（系统未编译 FTS5）")
        }

        // 4) LIKE 降级路径（无论有没有 FTS5 都要验证，因为它是兜底）
        let likeHits = countLikeHits(test, pattern: "%报销%")
        lines.append(likeHits == 2 ? "✓ LIKE 降级检索命中 2 条" : "✗ LIKE 降级检索异常：命中 \(likeHits) 条")

        lines.append("自检结束：以上全部为 ✓ 即表示检索层可用")
        return lines
    }

    private func countFTSHits(_ database: Database, query: String) -> Int {
        guard let statement = database.prepare("SELECT COUNT(*) FROM segments_fts WHERE segments_fts MATCH ?;") else {
            return -1
        }
        defer { statement.finalize() }
        statement.bind(1, query)
        guard statement.step() else { return -1 }
        return statement.int(0)
    }

    private func countLikeHits(_ database: Database, pattern: String) -> Int {
        guard let statement = database.prepare("SELECT COUNT(*) FROM segments WHERE text LIKE ?;") else {
            return -1
        }
        defer { statement.finalize() }
        statement.bind(1, pattern)
        guard statement.step() else { return -1 }
        return statement.int(0)
    }

    // MARK: - 内部

    /// 把状态变更发到主线程（View 观察的是主线程上的 @Published）。
    private func publish(_ mutate: @escaping (SearchIndex) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            mutate(self)
        }
    }
}
