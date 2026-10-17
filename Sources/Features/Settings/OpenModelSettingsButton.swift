import SwiftUI

/// 「去设置下载模型」按钮 —— 模型未下载时**就地弹出设置页**的快捷入口。
///
/// ## 为什么值得单独成一个视图
/// 这个按钮在两处出现（实时模型未下载 / 终稿模型未下载），而两处的**页面结构
/// 各不相同**。它们的提示文案都写着"去下载模型"，真机验收暴露的正是：
/// **用户看得到原因，却找不到入口**。所以入口必须由提示自己带出来，
/// 不能依赖"调用方那个页面恰好有齿轮"。
///
/// 各页各写一遍的后果是必然的：先是文案不一致，接着有的给了按钮、有的没给。
///
/// ## 只抽按钮、不连文案一起抽
/// 两处的**原因陈述必须各不相同**（缺的是实时模型 / 终稿模型，
/// 后续动作也不同）。硬凑成一个连文案的组件，只会让每处都得多加几个开关。
///
/// ## 2026-10-17
/// 原第三处「跟读页」随语言学习功能移除，这里从"三处"变回"两处"。
/// 设置页已改为底部 Tab（见 MainTabView），本按钮保留「就地弹 sheet」而非跳 Tab：
/// 下载完关闭即回原页，比切 Tab 再切回更顺；sheet 用 `SettingsView(showsCloseButton: true)`
/// 保留「完成」按钮。
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
        // 自带弹层，而不是由调用方去挂：这样它在"本身就在弹层里"的调用点
        // 也能直接用 —— 否则调用方得自己再管一个 @State。
        .sheet(isPresented: $showingSettings) {
            SettingsView(showsCloseButton: true)
        }
    }
}
