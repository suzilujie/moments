import SwiftUI

/// 应用主框架。
///
/// 五个标签页的分工：
///   · **录音**：M1 的主角，一键开始 / 停止，实时状态与关键指标
///   · **记录**：历史录音、断口、分片回放、文字稿、说话人、双语对照与生词
///   · **说话人**：声纹库维护（M3c）。单独成页的理由是它是跨会话的长期资产，
///     不属于任何一次录音；放在会话详情里会导致"想改个名字得先找到某次录音"
///   · **生词本**：M6 的学习资产，同理是跨会话的
///   · **自检**：M0 建立的能力验证页。它没有因为有了正式界面就被删掉 ——
///     后续每加一层都会在这里补上对应的验证项，
///     因为"关键状态必须在设备上直接可见"是本项目的排错基础（设计文档 4.14）。
struct MainTabView: View {

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("录音", systemImage: "mic.circle.fill") }

            SessionListView()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }

            SpeakerListView()
                .tabItem { Label("说话人", systemImage: "person.2.circle.fill") }

            VocabularyView()
                .tabItem { Label("生词本", systemImage: "character.book.closed.fill") }

            RootView()
                .tabItem { Label("自检", systemImage: "stethoscope") }
        }
    }
}

#Preview {
    MainTabView()
}
