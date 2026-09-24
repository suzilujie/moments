import SwiftUI

/// 「去设置下载模型」按钮 —— **设置入口的唯一一份定义**。
///
/// ## 为什么值得单独成一个视图
/// 这个按钮在三个地方出现，而三处的**页面结构各不相同**：
///   · 录音页：右上角有齿轮，但提示本身在列表中部
///   · 会话详情页：原本**完全没有**设置入口
///   · 跟读页：是个弹层，同样没有入口
///
/// 而它们的提示文案都写着"到设置中下载"。真机验收暴露的正是这件事：
/// **用户看得到原因，却找不到入口**。所以入口不能依赖"调用方那个页面恰好有齿轮"，
/// 必须由提示自己带出来。
///
/// 各页各写一遍的后果是必然的：先是文案不一致，接着有的给了按钮、有的没给。
///
/// ## 只抽按钮、不连文案一起抽
/// 三处的**原因陈述必须各不相同**（缺的是实时模型 / 终稿模型 / 跟读模型，
/// 后续动作也不同）。硬凑成一个连文案的组件，只会让每处都得多加几个开关。
struct OpenModelSettingsButton: View {

    /// 按钮标题。默认「去设置下载模型」
    var title: String = "去设置下载模型"

    @State private var showingSettings = false

    var body: some View {
        Button {
            showingSettings = true
        } label: {
            Label(title, systemImage: "arrow.down.circle")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        // 自带弹层，而不是由调用方去挂：这样它在"本身就是弹层的页面"
        //（跟读页）里也能直接用 —— 否则调用方得自己再管一个 @State。
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}
