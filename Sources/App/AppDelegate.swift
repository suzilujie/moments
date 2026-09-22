import UIKit

/// 应用生命周期。
///
/// M0 只做一件事：把启动环境与前后台切换**记录成日志**。
/// 这不是形式主义 —— M1 的中断恢复、看门狗、降档全部建立在
/// 「能准确知道何时进后台、何时回到前台」之上（设计文档 4.12、4.13）。
/// 如果这条信息一开始没有记录，等到出问题再补就已经错过了现场。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.shared.info(
            .app,
            "启动完成｜\(AppInfo.displayName) \(AppInfo.version)(\(AppInfo.build))"
                + "｜commit \(BuildInfo.commit)｜构建于 \(BuildInfo.builtAt)"
        )
        Log.shared.info(
            .app,
            "运行环境｜\(AppInfo.deviceModel) / iOS \(AppInfo.systemVersion)｜\(AppInfo.bundleID)"
        )

        let modes = AppInfo.backgroundModes
        Log.shared.info(
            .app,
            "后台模式声明｜\(modes.isEmpty ? "（空）" : modes.joined(separator: ", "))"
        )

        // 主动校验而非假设：这条声明一旦失效，症状是"锁屏后录音停掉"，
        // 而那时再来查配置就已经很晚了（设计文档 3.2、4.14）。
        if !AppInfo.hasAudioBackgroundMode {
            Log.shared.error(
                .app,
                "Info.plist 未声明 audio 后台模式 —— 锁屏后录音会被系统挂起，请检查 Resources/Info.plist"
            )
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Log.shared.info(.app, "进入后台")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 回到前台时 M1 会在这里做一次健康度校验：不信任"应该还在录"。
        Log.shared.info(.app, "回到前台")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.shared.info(.app, "进入活跃状态")
    }

    func applicationWillResignActive(_ application: UIApplication) {
        Log.shared.info(.app, "即将失去活跃状态")
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // M1 会在这里立刻 finalize 当前分片，把"被系统回收"的损失限制在一分钟内。
        Log.shared.warn(.app, "收到内存警告")
    }
}
