import SwiftUI

/// 应用入口。
///
/// 用 `@UIApplicationDelegateAdaptor` 而不是纯 SwiftUI 生命周期，原因很实际：
/// M1 必须精确知道「何时进入后台 / 回到前台 / 收到内存警告」（设计文档 4.12、4.13），
/// 而 `UIApplicationDelegate` 是拿到这些事件最直接、最不容易漏的通道。
@main
struct MomentsApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
