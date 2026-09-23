import SwiftUI

/// 设置页。
///
/// 按用户确认的原则：**未定选项由实现方定合理默认值，并做成运行时可改**。
/// 这里暴露的每一项都对应设计文档里一个"待真机标定"的参数 ——
/// 做成可调之后，真机调试就不必每次改代码再重装。
struct SettingsView: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                captureSection
                storageSection
                transcriptionSection
                modelSection
                bundledModelSection
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

    // MARK: - 转写

    private var transcriptionSection: some View {
        Section {
            Toggle("实时字幕", isOn: $settings.realtimeTranscriptionEnabled)
            Text("录音时当场显示文字。关掉它只是省电 —— 录音与终稿转写都不受影响。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("实时字幕使用降噪音频", isOn: $settings.realtimeDenoiseEnabled)
            Text("默认关。降噪会引入失真伪影，有可能反而让识别更差 —— "
                + "因此它是「可对照验证的选项」，不是默认增强。"
                + "录音的原始音频始终保留，随时可关掉重来。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("识别语言", selection: $settings.transcriptionLanguage) {
                ForEach(WhisperModelCatalog.languageOptions, id: \.code) { item in
                    Text(item.name).tag(item.code)
                }
            }
            Text("默认「自动判定」：中英夹杂的对话里强制指定某一种语言，"
                + "会把另一种语言识别成错字。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Picker("实时字幕模型", selection: $settings.realtimeModelId) {
                ForEach(WhisperModelCatalog.realtimeCandidates) { model in
                    Text("\(model.displayName)（\(model.sizeText)）").tag(model.id)
                }
            }
            Picker("终稿模型", selection: $settings.finalModelId) {
                ForEach(WhisperModelCatalog.finalCandidates) { model in
                    Text("\(model.displayName)（\(model.sizeText)）").tag(model.id)
                }
            }
        } header: {
            Text("转写")
        } footer: {
            Text("实时字幕求快、终稿求准，因此分开选模型。终稿在充电或息屏时执行，"
                + "不占用你使用手机的时段。")
        }
    }

    // MARK: - 模型

    private var modelSection: some View {
        Section {
            Toggle("模型下载优先走镜像", isOn: $settings.preferModelMirror)
            Text("当 huggingface.co 不可达时打开此项。它只改变下载来源，不影响识别结果。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(WhisperModelCatalog.all) { model in
                modelRow(model)
            }

            HStack {
                Text("模型占用")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: models.installedBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("模型")
        } footer: {
            if let message = models.lastMessage {
                Text(message)
            } else {
                Text("模型不打进安装包（蜂窝下载上限 200 MB），首次使用时在这里下载。")
            }
        }
    }

    private func modelRow(_ model: WhisperModelDescriptor) -> some View {
        let state = models.states[model.id] ?? .notInstalled
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName).bold()
                    Text(model.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                modelAction(for: model, state: state)
            }
            if case .downloading(let progress) = state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func modelAction(for model: WhisperModelDescriptor, state: ModelDownloadState) -> some View {
        switch state {
        case .installed:
            Button("删除", role: .destructive) {
                try? models.delete(model.id)
            }
            .font(.footnote)

        case .downloading:
            Button("取消") {
                models.cancelDownload(model.id)
            }
            .font(.footnote)

        case .notInstalled, .failed:
            Button("下载 \(model.sizeText)") {
                models.download(model.id, preferMirror: settings.preferModelMirror)
            }
            .font(.footnote)
        }
    }

    // MARK: - 内置模型（M3）

    private var bundledModelSection: some View {
        Section {
            ForEach(SherpaBundledModel.allCases, id: \.self) { model in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.subheadline)
                        Text(model.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(model.isAvailable ? "已内置" : "缺失")
                        .font(.caption)
                        .foregroundStyle(model.isAvailable ? .green : .red)
                }
            }
        } header: {
            Text("内置模型（M3：VAD / 降噪 / 说话人分离）")
        } footer: {
            Text("这些模型随安装包一起提供（合计约 "
                + ByteCountFormatter.string(fromByteCount: SherpaBundledModel.totalBytes, countStyle: .file)
                + "），不需要下载 —— 它们的原始托管地址在交付环境实测不可达，"
                + "做成下载会让这些功能直接不可用。")
        }
    }

    private var languageSection: some View {
        Section("语言") {
            Picker("我正在学", selection: $settings.learningLanguage) {
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Picker("默认翻译成", selection: $settings.defaultTargetLanguage) {
                ForEach(TranslationLanguageCatalog.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            Text("「默认翻译成」决定打开会话时默认的目标语言。"
                + "「我正在学」将决定 M6 学习模式的生词判定方向（学习模式尚未实现）。")
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
            Text("当前为 M2（转写）阶段：录音内核（M1）已完成，正在接入离线转写"
                + "（实时字幕 + 终稿）；说话人分离、翻译、语言学习尚未实现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
