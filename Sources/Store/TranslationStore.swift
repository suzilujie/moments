import Foundation

/// 一条译文。
struct TranslationEntry: Codable, Identifiable {

    var id: String { "\(segmentId)|\(targetLang)" }

    /// 对应的转写片段 id
    var segmentId: String
    /// 目标语言代码（如 ja / en）
    var targetLang: String
    var text: String
    /// 译文属于哪一稿（实时稿/终稿）。同一句在两稿里文本不同，
    /// 译文自然也不同 —— 不分开存会让"终稿的译文"覆盖掉"实时稿的译文"。
    var pass: TranscriptPass
    /// 引擎标识与版本：引擎升级后可识别出旧译文值得重翻
    var engine: String
    var engineVersion: String
    /// 用户手动修正过 —— 优先级最高，任何自动翻译都不得覆盖
    var editedByUser: Bool
    var createdAtMs: Int64

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)
    }
}

/// 一次会话的全部译文（持久化单元）。
///
/// ## 为什么译文必须**持久化**，而不能像索引那样"可重建"
/// M4 定下的架构是「数据库是可从磁盘重建的索引」，但**译文不适用这条**：
/// 重建译文需要重新调用翻译引擎，而语言包可能已被系统清理、用户可能已离线。
/// 因此译文属于**用户资产**，必须与转写稿一样落在会话目录里：
/// ```
/// Application Support/Moments/Audio/{sessionId}/
/// ├─ transcript-final.json
/// ├─ translations.json     ← 本文件
/// └─ speakers.json
/// ```
struct TranslationDocument: Codable {

    var sessionId: String
    var updatedAtMs: Int64
    var entries: [TranslationEntry]

    /// 某语言、某一稿已翻好的片段映射（segmentId → 译文）。
    /// 刻意不叫 `map` —— 那会与 Swift 标准库的 `map` 在阅读时混淆。
    ///
    /// ## 为什么必须按 `pass` 过滤
    /// 同一个 `segmentId` 在实时稿与终稿里可能指向**不同的句子文本**（两稿由不同
    /// 引擎/参数生成），因此译文也必须按稿分开存（见 `TranslationEntry.pass` 与
    /// `merge` 的三维键 `segmentId + targetLang + pass`）。若读取时只按语言过滤、
    /// 以 `segmentId` 为键，两稿的同 id 条目会互相覆盖，表现为"切到终稿却看到
    /// 实时稿的译文"，或"终稿翻译误以为已有译文而跳过"。
    func texts(for targetLang: String, pass: TranscriptPass) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries where entry.targetLang == targetLang && entry.pass == pass {
            result[entry.segmentId] = entry.text
        }
        return result
    }

    func translatedLanguages() -> [String] {
        Array(Set(entries.map { $0.targetLang })).sorted()
    }
}

/// 译文持久化层。
final class TranslationStore {

    static let shared = TranslationStore()

    private let queue = DispatchQueue(label: "com.xfish.moments.translation.store", qos: .utility)
    private let fileName = "translations.json"

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private lazy var decoder = JSONDecoder()

    private init() {}

    func url(sessionId: String) -> URL {
        RecordingLibrary.shared.sessionDirectory(sessionId).appendingPathComponent(fileName)
    }

    func exists(sessionId: String) -> Bool {
        FileManager.default.fileExists(atPath: url(sessionId: sessionId).path)
    }

    func load(sessionId: String) -> TranslationDocument {
        let target = url(sessionId: sessionId)
        guard let data = try? Data(contentsOf: target),
              let document = try? decoder.decode(TranslationDocument.self, from: data) else {
            return TranslationDocument(sessionId: sessionId, updatedAtMs: 0, entries: [])
        }
        return document
    }

    func save(_ document: TranslationDocument) throws {
        let target = url(sessionId: document.sessionId)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(document)
        // 原子写：批量翻译中途被杀时，不能把已有的译文一起毁掉
        try data.write(to: target, options: .atomic)
    }

    /// 合并写入一批译文。
    ///
    /// **已有的人工修正不会被覆盖** —— 用户改过的译文优先级最高，
    /// 否则重跑一次翻译就会把他的手改成果抹掉，那是最让人恼火的一类 bug。
    ///
    /// ## 读-改-写必须原子（2026-10-17 修复）
    /// 本类此前是"调用线程同步 `load` + 串行队列异步 `save`"。两次 `merge` 并发时，
    /// 各自读到同一份旧 JSON、各自改、后写的覆盖先写的 —— 丢掉的正是前一次的译文。
    /// 修复后 `load → modify → save` 整体放进同一条串行队列（`queue.sync`），
    /// 一次 `merge` 结束即代表译文已落盘；后续读（如检索索引重建）不再踩到半写状态。
    /// - Returns: (新增或更新的条数, 因人工修正而被保留的条数)
    @discardableResult
    func merge(
        sessionId: String,
        targetLang: String,
        pass: TranscriptPass,
        translations: [String: String],
        engine: String,
        engineVersion: String
    ) -> (updated: Int, keptManual: Int) {
        var result: (updated: Int, keptManual: Int) = (0, 0)
        queue.sync {
            var document = load(sessionId: sessionId)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var updated = 0
            var keptManual = 0

            for (segmentId, text) in translations {
                if let index = document.entries.firstIndex(where: {
                    $0.segmentId == segmentId && $0.targetLang == targetLang && $0.pass == pass
                }) {
                    if document.entries[index].editedByUser {
                        keptManual += 1
                        continue
                    }
                    if document.entries[index].text == text { continue }
                    document.entries[index].text = text
                    document.entries[index].createdAtMs = now
                    document.entries[index].engine = engine
                    document.entries[index].engineVersion = engineVersion
                    updated += 1
                } else {
                    document.entries.append(
                        TranslationEntry(
                            segmentId: segmentId,
                            targetLang: targetLang,
                            text: text,
                            pass: pass,
                            engine: engine,
                            engineVersion: engineVersion,
                            editedByUser: false,
                            createdAtMs: now
                        )
                    )
                    updated += 1
                }
            }

            document.updatedAtMs = now
            do {
                try save(document)
            } catch {
                Log.shared.error(
                    .storage,
                    "译文写入失败｜\(sessionId)｜\(error.localizedDescription)"
                )
            }
            result = (updated, keptManual)
        }
        return result
    }

    /// 用户手动修正一条译文。
    ///
    /// 同样走串行队列的原子读-改-写，理由见 `merge` 的说明。
    func overrideTranslation(
        sessionId: String,
        segmentId: String,
        targetLang: String,
        pass: TranscriptPass,
        text: String
    ) {
        queue.sync {
            var document = load(sessionId: sessionId)
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            if let index = document.entries.firstIndex(where: {
                $0.segmentId == segmentId && $0.targetLang == targetLang && $0.pass == pass
            }) {
                document.entries[index].text = text
                document.entries[index].editedByUser = true
                document.entries[index].createdAtMs = now
            } else {
                document.entries.append(
                    TranslationEntry(
                        segmentId: segmentId,
                        targetLang: targetLang,
                        text: text,
                        pass: pass,
                        engine: "manual",
                        engineVersion: "",
                        editedByUser: true,
                        createdAtMs: now
                    )
                )
            }
            document.updatedAtMs = now
            do {
                try save(document)
            } catch {
                Log.shared.error(
                    .storage,
                    "译文写入失败｜\(sessionId)｜\(error.localizedDescription)"
                )
            }
        }
        Log.shared.info(.storage, "译文已人工修正｜\(sessionId)｜\(segmentId)｜\(targetLang)")
    }

    func deleteAll(sessionId: String) {
        queue.sync {
            let target = url(sessionId: sessionId)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            try? FileManager.default.removeItem(at: target)
        }
        Log.shared.info(.storage, "已删除译文｜\(sessionId)")
    }

    /// 译文总量（自检页与设置页展示用）
    func totalEntryCount() -> Int {
        RecordingLibrary.shared.listSessions().reduce(0) { partial, manifest in
            partial + load(sessionId: manifest.id).entries.count
        }
    }

    /// 已翻译的会话数 / 总会话数
    func coverage() -> (translated: Int, total: Int) {
        let sessions = RecordingLibrary.shared.listSessions()
        let translated = sessions.filter { exists(sessionId: $0.id) }.count
        return (translated, sessions.count)
    }
}
