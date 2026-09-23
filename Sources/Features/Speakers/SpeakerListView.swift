import SwiftUI

/// 说话人管理（M3c）：声纹库维护。
///
/// 这一页是「跨会话认人」的入口。它承载一个必须讲清楚的心智模型：
/// **声纹库不是自动生成的，是用出来的** ——
/// 你在某次录音里把「说话人 2」命名为"张三"，张三的声纹就进了库，
/// 之后任何一次录音里再出现他，都会自动标出名字。
struct SpeakerListView: View {

    @ObservedObject private var store = SpeakerProfileStore.shared
    @ObservedObject private var diarization = DiarizationService.shared

    @State private var renaming: SpeakerProfile?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            List {
                profileSection
                rematchSection
                aboutSection
            }
            .navigationTitle("说话人")
            .alert("重命名", isPresented: renameBinding) {
                TextField("姓名", text: $draftName)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let renaming, !draftName.trimmingCharacters(in: .whitespaces).isEmpty {
                        store.rename(id: renaming.id, to: draftName.trimmingCharacters(in: .whitespaces))
                    }
                    renaming = nil
                }
            } message: {
                Text("改名只影响展示，不会改变已存的声纹。")
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )
    }

    // MARK: - 档案

    private var profileSection: some View {
        Section {
            if store.profiles.isEmpty {
                Text("声纹库还是空的。到「记录」里打开一次录音、做说话人分离，"
                    + "再把「说话人 1/2」命名成具体的人，声纹就会存到这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.profiles) { profile in
                    Button {
                        draftName = profile.name
                        renaming = profile
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("\(profile.sourceText)｜累计 \(profile.sampleCount) 段｜\(profile.updatedAt.formatted(date: .numeric, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: store.delete)
            }
        } header: {
            Text("已录入的人物（\(store.profiles.count)）")
        } footer: {
            Text("点条目可重命名，左滑可删除。删除后该人不会再被自动认出，但已有录音里的名字不受影响。")
        }
    }

    // MARK: - 重新认人

    private var rematchSection: some View {
        Section {
            Button("用当前声纹库重新认人") {
                diarization.rematchAllSessions()
            }
            .disabled(store.profiles.isEmpty)
        } header: {
            Text("重新认人")
        } footer: {
            Text("对**已分离过**的录音重新比对声纹库。\n"
                + "这一步只用录音时存下的声纹质心，**不重跑音频分离**，因此是秒级完成 —— "
                + "新录入一个人之后，历史录音也能立刻被认出来。")
        }
    }

    // MARK: - 说明

    private var aboutSection: some View {
        Section("关于说话人识别") {
            Text("命中只是**建议**：声纹会随感冒、情绪、距离、麦克风变化而波动，"
                + "不同人偶尔也会相似。所以系统只在高置信度时才写名字，"
                + "不确定时保持「说话人 N」，绝不硬猜。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("多人同时讲话（重叠说话）是公认难题，分割准确率会明显下降。"
                + "这类片段会被标注为「可能重叠」，而不是假装判断正确。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let message = diarization.lastMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SpeakerListView()
}
