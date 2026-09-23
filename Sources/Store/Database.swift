import Foundation
import SQLite3

/// SQLite 中绑定参数时的"拷贝语义"标记。
///
/// Swift 里没有直接暴露 `SQLITE_TRANSIENT`（它是个宏），业界通用做法是用
/// `unsafeBitCast(-1, ...)` 得到它。**必须传它而不是 nil**：
/// 传 nil 等于 SQLITE_STATIC，SQLite 会直接引用我们传入的缓冲区指针，
/// 而 Swift 的 `String` 转 C 指针是临时的 —— 调用返回后指针失效，
/// 结果是**写入随机乱码或崩溃**，且不一定立刻出现。
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite 连接与语句的薄封装（M4）。
///
/// ## 为什么自己写而不用 GRDB / SQLite.swift
/// 本项目已经有两个手工构建的二进制依赖（whisper.cpp、sherpa-onnx），
/// 再多一个来源不同的依赖，只会增加"到底哪一层坏了"的排查成本。
/// 系统 SQLite 的 C API 啰嗦一点，但确定可用、零版本风险。
///
/// ## 线程约定
/// 以 `SQLITE_OPEN_FULLMUTEX` 打开（串行化模式），并且**所有访问都走同一条串行队列**
/// （由调用方 `SearchIndex` 保证）。SQLite 单连接不适合并发使用，
/// 与其依赖它的内部锁，不如在结构上就串行化。
final class Database {

    private var handle: OpaquePointer?
    private(set) var lastErrorMessage = ""

    var isOpen: Bool { handle != nil }

    init(path: String) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            lastErrorMessage = "打开数据库失败：\(message)"
            if let db { sqlite3_close(db) }
            return
        }
        handle = db

        // 忙等 3 秒而不是立刻失败：转写与分离是长任务，
        // 与界面查询撞上时等待比报错更合适
        sqlite3_busy_timeout(db, 3000)

        // WAL：崩溃/被系统杀掉后不易损坏，且读写不互相阻塞。
        // synchronous=NORMAL 是在 WAL 下的常见折中（比 FULL 快很多，仍保持崩溃安全）。
        _ = execute("PRAGMA journal_mode=WAL;")
        _ = execute("PRAGMA synchronous=NORMAL;")
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close(handle)
        self.handle = nil
    }

    // MARK: - 执行

    @discardableResult
    func execute(_ sql: String) -> Bool {
        guard let handle else {
            lastErrorMessage = "数据库未打开"
            return false
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if code != SQLITE_OK {
            if let errorPointer {
                lastErrorMessage = String(cString: errorPointer)
                sqlite3_free(errorPointer)
            } else {
                lastErrorMessage = "exec 返回 \(code)"
            }
            return false
        }
        return true
    }

    /// 逐条执行多条语句（迁移用）。
    @discardableResult
    func executeAll(_ statements: [String]) -> Bool {
        for statement in statements where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard execute(statement) else { return false }
        }
        return true
    }

    func prepare(_ sql: String) -> Statement? {
        guard let handle else {
            lastErrorMessage = "数据库未打开"
            return nil
        }
        guard let statement = Statement(database: handle, sql: sql) else {
            lastErrorMessage = String(cString: sqlite3_errmsg(handle))
            return nil
        }
        return statement
    }

    /// 便捷查询：取单个整数（如 COUNT(*)）。
    func scalarInt(_ sql: String) -> Int? {
        guard let statement = prepare(sql) else { return nil }
        defer { statement.finalize() }
        guard statement.step() else { return nil }
        return statement.int(0)
    }

    /// 把多条写入包在一个事务里。批量导入几千条时，
    /// 逐条自动提交会慢几十倍（每条一次 fsync）。
    @discardableResult
    func inTransaction(_ body: () -> Bool) -> Bool {
        guard execute("BEGIN;") else { return false }
        guard body() else {
            _ = execute("ROLLBACK;")
            return false
        }
        return execute("COMMIT;")
    }

    /// FTS5 能力探测。
    ///
    /// **必须运行期探测而不是假定**：iOS 的系统 SQLite 是否编译进 FTS5
    /// 并无公开保证（官方文档从未承诺）。探测失败时上层会降级为 LIKE 扫描，
    /// 功能仍可用、只是慢 —— 而不是整个检索功能直接不可用。
    var supportsFTS5: Bool {
        guard let statement = prepare("SELECT sqlite3_compileoption_used('ENABLE_FTS5');") else {
            return false
        }
        defer { statement.finalize() }
        guard statement.step() else { return false }
        return statement.int(0) == 1
    }

    var sqliteVersion: String {
        // 用 isOpen 而不是绑定 handle：sqlite3_libversion 是全局函数，
        // 不需要连接句柄，绑定它只会产生"变量未使用"的告警
        guard isOpen else { return "未打开" }
        return String(cString: sqlite3_libversion())
    }
}

/// 预编译语句。
///
/// 用预编译 + 绑定参数，而不是拼字符串：除了防注入，
/// 更实际的原因是**含引号/换行的转写文本**拼进 SQL 极易出错。
final class Statement {

    private var handle: OpaquePointer?

    init?(database: OpaquePointer?, sql: String) {
        guard let database else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        handle = statement
    }

    deinit {
        finalize()
    }

    func finalize() {
        guard let handle else { return }
        sqlite3_finalize(handle)
        self.handle = nil
    }

    // MARK: - 绑定（参数下标从 1 开始，与 SQLite 一致）

    func bind(_ index: Int32, _ value: String) {
        guard let handle else { return }
        sqlite3_bind_text(handle, index, value, -1, sqliteTransient)
    }

    func bind(_ index: Int32, _ value: Int) {
        bind(index, Int64(value))
    }

    func bind(_ index: Int32, _ value: Int64) {
        guard let handle else { return }
        sqlite3_bind_int64(handle, index, value)
    }

    func bindNull(_ index: Int32) {
        guard let handle else { return }
        sqlite3_bind_null(handle, index)
    }

    // MARK: - 读取

    /// 前进一行。- Returns: 是否取到一行（false 表示结束或出错）
    func step() -> Bool {
        guard let handle else { return false }
        return sqlite3_step(handle) == SQLITE_ROW
    }

    func reset() {
        guard let handle else { return }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func string(_ column: Int32) -> String? {
        guard let handle, let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    var hasRow: Bool { handle != nil }
}
