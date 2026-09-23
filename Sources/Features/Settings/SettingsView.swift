import SwiftUI

/// 设置页。
///
/// 按用户确认的原则：**未定选项由实现方定合理默认值，并做成运行时可改**。
/// 这里暴露的每一项都对应设计文档里一个"待真机标定"的参数 ——
/// 做成可调之后，真机调试就不必每次改代码再重装。
struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                storageSection
                languageSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var captureSection: some View {
        Section("采集") {
            Picker("音频会话模式", selection: $settings.sessionMode) {
                ForEach(AudioSessionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(settings.sessionMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("分片时长", selection: $settings.segmentSeconds) {
                Text("30 秒").tag(30)
                Text("60 秒").tag(60)
                Text("120 秒").tag(120)
            }

            Picker("落盘码率", selection: $settings.bitRate) {
                Text("32 kbps（约 14 MB/小时）").tag(32_000)
                Text("48 kbps（约 21 MB/小时）").tag(48_000)
                Text("64 kbps（更保真）").tag(64_000)
            }

            Picker("单次录制上限", selection: $settings.maxSessionHours) {
                Text("2 小时").tag(2)
                Text("6 小时").tag(6)
                Text("12 小时").tag(12)
                Text("不限制").tag(0)
            }
        }
    }

    private var storageSection: some View {
        Section("存储") {
            Picker("音频保留", selection: $settings.retentionDays) {
                Text("3 天").tag(3)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("永久保留").tag(0)
            }
            Text("转写文字永久保留；音频到期后自动删除。删除音频不会删除文字与记录。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Text("磁盘下限")
                Spacer()
                Text(String(format: "%.0f GB", settings.minFreeDiskGB))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.minFreeDiskGB, in: 0.5...5.0, step: 0.5)
            Text("剩余空间低于该值时自动停止录音，保护已录内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        Section("语言") {
            Picker("我正在学", selection: $settings.learningLanguage) {
                Text("英语").tag("en")
                Text("日语").tag("ja")
                Text("韩语").tag("ko")
            }
            Picker("默认翻译成", selection: $settings.defaultTargetLanguage) {
                Text("中文").tag("zh")
                Text("英文").tag("en")
                Text("日文").tag("ja")
            }
            Text("这两项决定 M6 学习模式的生词判定与默认展示（尚未实现）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
            }
            HStack {
                Text("提交")
                Spacer()
                Text(BuildInfo.commit).foregroundStyle(.secondary)
            }
            Text("当前为 M1（录音内核）阶段：已能录音、分片落盘与断口标注；"
                + "转写、翻译、说话人分离、语言学习尚未实现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
