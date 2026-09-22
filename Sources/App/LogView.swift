import SwiftUI

/// 应用内日志面板。
///
/// 存在的理由：本项目没有 Mac、没有断点调试器，`idevicesyslog` 又必须插线。
/// 一个能在手机上直接翻看并导出的日志面板，是排错效率的分水岭 ——
/// 尤其是 M1 那些"沉默行为"（中断恢复、降档、看门狗触发），
/// 它们不报错、UI 也未必显示，只有日志能证明它们发生过（设计文档 4.14 节）。
struct LogView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LogEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text")
                } else {
                    List(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(entry.level.rawValue)
                                    .font(.caption2)
                                    .bold()
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(timeText(entry.at))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message)
                                .font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("日志 (\(entries.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Log.shared.exportText()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                // 最新的排在最上面，符合排错时的阅读顺序
                entries = Array(Log.shared.snapshot().reversed())
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    LogView()
}
