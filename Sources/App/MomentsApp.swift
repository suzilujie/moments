import SwiftUI

/// 应用入口。
///
/// 用 `@UIApplicationDelegateAdaptor` 而不是纯 SwiftUI 生命周期，原因很实际：
/// M1 必须精确知道「何时进入后台 / 回到前台 / 收到内存警告」（设计文档 4.12、4.13），
/// 而 `UIApplicationDelegate` 是拿到这些事件最直接、最不容易漏的通道。
@main
struct MomentsApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // M4：启动时建立/校验检索索引。
        //
        // 刻意放在 init 里而不是某个页面的 onAppear：
        // 检索应该是"打开就有用"的，不该等用户先访问某个页面才构建。
        // 它**不阻塞启动** —— 全部工作在后台队列上进行，完成后才发布状态
        // （见 SearchIndex.start）。
        SearchIndex.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
