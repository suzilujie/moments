import SwiftUI

/// 应用主框架。
///
/// 三个标签页的分工：
///   · **录音**：M1 的主角，一键开始 / 停止，实时状态与关键指标
///   · **记录**：历史录音、断口、分片回放
///   · **自检**：M0 建立的能力验证页。它没有因为有了正式界面就被删掉 ——
///     后续 M2–M6 每加一层都会在这里补上对应的验证项，
///     因为"关键状态必须在设备上直接可见"是本项目的排错基础（设计文档 4.14）。
struct MainTabView: View {

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("录音", systemImage: "mic.circle.fill") }

            SessionListView()
                .tabItem { Label("记录", systemImage: "list.bullet.rectangle") }

            RootView()
                .tabItem { Label("自检", systemImage: "stethoscope") }
        }
    }
}

#Preview {
    MainTabView()
}
