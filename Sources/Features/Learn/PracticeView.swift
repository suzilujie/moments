import SwiftUI

/// 跟读比对（M6b）。
///
/// **它不是发音教练 —— 这件事必须写在界面上，而不只是写在代码注释里。**
/// whisper 是语音识别模型，输出的是"把这段声音听成了哪些词"，
/// 因此本页回答的是「这句话你读对了没有」，而不是「你的 th 音舌位对不对」。
///
/// 若不在界面上说清，用户会把它当发音评分，然后对它的沉默
/// （读得不标准却被判满分）产生错误信任 —— 那比没有这个功能更糟。
struct PracticeView: View {

    /// 要跟读的那一句（参考文本）
    let referenceText: String

    @ObservedObject private var practice = PronunciationPractice.shared
    /// 观察模型下载状态：用户在设置里下完模型回来，本页要立刻从
    /// "去设置下载"切成"重试"。不观察的话会一直停在旧判断上 ——
    /// 又一处"设置没生效"。
    @ObservedObject private var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                referenceSection
                actionSection

                if case .failed(let message) = practice.stage {
                    failureSection(message)
                }
                if let score = practice.score {
                    scoreSection(score)
                    alignmentSection(score)
                    heardSection(score)
                }

                boundarySection
            }
            .navigationTitle("跟读比对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        // 退出去必须收干净：停录音、停定时器、释放模型。
                        // 跟读用的模型是独立实例，留着白占几十 MB。
                        practice.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { practice.prepare(reference: referenceText) }
        }
    }

    // MARK: - 参考句

    private var referenceSection: some View {
        Section("跟读这一句") {
            Text(referenceText)
                .font(.title3)
                .textSelection(.enabled)
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private var actionSection: some View {
        Section {
            switch practice.stage {
            case .recording:
                recordingView

            case .evaluating:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("识别中…")
                }
                Text("在本机离线识别，通常一两秒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            default:
                Button {
                    practice.startRecording()
                } label: {
                    Label("开始录音", systemImage: "mic.fill")
                }
            }
        } header: {
            Text("操作")
        } footer: {
            Text("使用模型：\(practice.modelDisplayName)"
                + "（与实时字幕共用同一个模型，可在「设置 → 转写」更换）")
        }
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("录音中 \(practice.elapsedText)")
                    .monospacedDigit()
                Spacer()
                Text("最长 \(Int(PronunciationPractice.maximumSeconds)) 秒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(practice.inputLevel))
                .progressViewStyle(.linear)
                .tint(practice.inputLevel > 0.02 ? .green : .orange)

            if practice.inputLevel <= 0.02 {
                // 静音必须当场提示：否则用户会一路录完、拿到 0 分，
                // 然后归因于"识别不准"，而不是"麦克风没收到声音"
                Text("几乎没有声音。请确认麦克风未被遮挡，也没有被其他 App 占用。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("停止并评测") {
                practice.stopAndEvaluate()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 2)
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)

            // 模型没下载时**不给"重试"**：再录一次仍会失败，那是个点了没用的按钮。
            // 真正的下一步是下载，而本页是个弹层、够不到设置 —— 所以给入口。
            if practice.isModelInstalled {
                Button("重试") { practice.reset() }
                    .font(.footnote)
            } else {
                OpenModelSettingsButton()
            }
        }
    }

    // MARK: - 结果

    private func scoreSection(_ score: PronunciationScore) -> some View {
        Section("得分") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(score.percentText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(score.verdictText)
                        .font(.subheadline)
                    Text(score.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: score.score)
                .progressViewStyle(.linear)
                .tint(score.score >= 0.8 ? .green : (score.score >= 0.5 ? .orange : .red))
        }
    }

    private func alignmentSection(_ score: PronunciationScore) -> some View {
        Section {
            alignmentText(score)
                .font(.body)
                .textSelection(.enabled)

            HStack(spacing: 14) {
                legend("读对", .green)
                legend("没听到", .red)
                legend("读成别的词", .orange)
                legend("多余", .secondary)
            }
            .font(.caption2)
        } header: {
            Text("逐词对照")
        } footer: {
            Text("带删除线的是参考句里有、但没被听到（或读成了别的词）的词。"
                + "灰色斜体是多出来的词 —— 多半是识别噪声，不必在意。")
        }
    }

    /// 逐词着色。
    ///
    /// 用 `Text` 拼接而不是 chips + 换行容器：拼接出来的整体会**按句子自然换行**，
    /// 读起来仍是一句话；chips 会把句子切碎成一个个孤立的块，反而看不出对照关系。
    private func alignmentText(_ score: PronunciationScore) -> Text {
        var output = Text("")
        for (index, item) in score.alignments.enumerated() {
            if index > 0 { output = output + Text(" ") }
            let display = item.displayText

            switch item.verdict {
            case .hit:
                output = output + Text(display).foregroundStyle(.green)
            case .substituted:
                // 同时给出"读成了什么"，否则用户只知道错、不知道错在哪
                output = output + Text(display).foregroundStyle(.orange).strikethrough()
                if let heard = item.heard {
                    output = output + Text("(\(heard))").font(.caption).foregroundStyle(.orange)
                }
            case .missed:
                output = output + Text(display).foregroundStyle(.red).strikethrough()
            case .extra:
                output = output + Text(display).foregroundStyle(.secondary).italic()
            }
        }
        return output
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .foregroundStyle(.secondary)
        }
    }

    private func heardSection(_ score: PronunciationScore) -> some View {
        Section {
            if score.recognizedText.isEmpty {
                Text("模型什么都没听到。请确认麦克风正常，并靠近一点重读。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(score.recognizedText)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        } header: {
            Text("模型听到的是")
        } footer: {
            Text("这一行就是打分的全部依据。得分低不代表你读得不好听，"
                + "只代表模型没听成参考句里的那些词。")
        }
    }

    // MARK: - 边界

    private var boundarySection: some View {
        Section("这个功能测什么、不测什么") {
            Text("测得到：漏读整个词、读成别的词、吞音、声音太小、语速快到糊掉。")
                .font(.footnote)

            Text("测不到：音素级的发音质量。把 think 读成 sink 会被判错（说明它有用），"
                + "但把 think 读成舌位略偏的 think（仍被听成 think）看不出任何差别 —— "
                + "它无法告诉你「th 的舌位不对」。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("真正的发音评测需要专门的 GOP 打分模型，本项目没有引入，"
                + "所以这里叫「跟读比对」而不是「发音评分」。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
