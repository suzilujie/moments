import Foundation

/// 生词本导出（设计文档 8.5）。
///
/// ## 格式选择与理由
///
/// **Anki CSV 用制表符分隔，不用逗号。**
/// 释义与来源句里出现逗号是常态（尤其中文句子几乎必然有逗号），
/// 用逗号就必须给大量字段加引号转义 —— 而转义只要有一点偏差，
/// 用户导入后看到的就是串列的字段，且很难自己查出错在哪。
/// 制表符在自然语言文本里几乎不出现，用起来最稳。
///
/// **CSV 不带表头。** Anki 是**按字段顺序**做映射的，带表头会多出一张
/// 内容为表头文字的卡片，用户得自己删。宁可让 CSV 单独打开时不易读，
/// 也不要制造一张脏卡片 —— 列的含义写在 Markdown 导出与界面说明里。
///
/// ## 与设计文档的一处有意偏离
/// 文档写的是导出「词形 / 释义 / 例句 / **音频文件名**」，供 Anki 卡片播原声。
/// 但本项目**不做音频切分导出**（把某一句从 60 秒分片里裁出来是另一件事），
/// 因此最后一列填的是「来源会话 + 时间点」而不是音频文件 ——
/// 用户据此能回 App 里定位到那一句。**"释义"一列当前留空**：
/// 端侧生成释义（Foundation Models）尚未实现，不做假占位。
enum VocabularyExporter {

    /// 导出所用的列顺序（CSV 与界面说明共用同一份定义，避免两处写得不一致）
    static let columnTitles = ["词形", "难度", "备注", "来源句", "来源"]

    // MARK: - Anki CSV

    static func ankiCSV(items: [VocabularyItem], sessionTitles: [String: String]) -> String {
        var lines: [String] = []
        for item in items {
            let fields = [
                item.word,
                item.difficultyText,
                item.note,
                item.sourceSentence ?? "",
                sourceText(for: item, sessionTitles: sessionTitles)
            ]
            lines.append(fields.map(sanitize).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    // MARK: - Markdown

    static func markdown(items: [VocabularyItem], sessionTitles: [String: String]) -> String {
        let exportedAt = Date().formatted(date: .numeric, time: .shortened)
        let mastered = items.filter { $0.mastered }.count

        var lines: [String] = []
        lines.append("# 生词本")
        lines.append("")
        lines.append("> 导出时间 \(exportedAt)｜共 \(items.count) 词｜已掌握 \(mastered)｜待复习 \(items.count - mastered)")
        lines.append(">")
        lines.append("> 由「时刻」导出。生词按**词频**判定（非 AI 判定），因此同一句话的判定结果永远一致。")
        lines.append("> 音质与语调以真实录音为准 —— 这里的文字只是索引。")
        lines.append("")

        guard !items.isEmpty else {
            lines.append("（生词本为空）")
            return lines.joined(separator: "\n") + "\n"
        }

        lines.append("## 待复习")
        lines.append("")
        append(items.filter { !$0.mastered }, to: &lines, sessionTitles: sessionTitles)

        let done = items.filter { $0.mastered }
        if !done.isEmpty {
            lines.append("")
            lines.append("## 已掌握")
            lines.append("")
            append(done, to: &lines, sessionTitles: sessionTitles)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(
        _ items: [VocabularyItem],
        to lines: inout [String],
        sessionTitles: [String: String]
    ) {
        for item in items {
            lines.append("- **\(item.word)**（\(item.difficultyText)）")
            if !item.note.isEmpty {
                lines.append("  - 备注：\(item.note)")
            }
            if let sentence = item.sourceSentence, !sentence.isEmpty {
                lines.append("  - 原句：\(sentence)")
            }
            lines.append("  - 来源：\(sourceText(for: item, sessionTitles: sessionTitles))")
        }
    }

    // MARK: - 辅助

    /// 导出文件名（带日期，便于多次导出后区分）
    static func fileName(extension ext: String) -> String {
        let day = Date().formatted(.iso8601.year().month().day())
        return "moment-vocabulary-\(day).\(ext)"
    }

    /// 写到临时目录，返回文件 URL（供 ShareLink 分享）。
    /// - Returns: nil 表示写入失败，调用方须告知用户而不是静默无反应。
    static func writeToTemporaryFile(contents: String, fileName: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.shared.error(.storage, "生词本导出写入失败｜\(error.localizedDescription)")
            return nil
        }
    }

    /// 把来源写成一句人话：会话标题 + 日期。
    private static func sourceText(for item: VocabularyItem, sessionTitles: [String: String]) -> String {
        guard let sessionId = item.sourceSessionId else { return "手动添加" }
        let title = sessionTitles[sessionId] ?? sessionId
        return title
    }

    /// 清理字段：去掉分隔符与换行，避免把一列撑成两列。
    /// 这里**只做必要的替换**，不做内容改写 —— 导出的是用户自己的材料，
    /// 动它的内容比多两个转义字符更不可接受。
    private static func sanitize(_ field: String) -> String {
        field
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
