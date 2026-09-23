import UIKit

/// 应用生命周期。
///
/// M0 的职责是「把关键链路全部留痕」，具体三件事：
///   1. 启动时记录构建指纹、运行环境、plist 声明与日志落盘位置
///   2. 拉起音频事件监听（中断 / 路由 / 媒体服务 / 音频图）与系统状态监测
///   3. 前后台切换时记一条状态快照
///
/// 为什么这么早就做：M1 的中断恢复、看门狗、降档全部建立在这三类信息之上
/// （设计文档 4.12、4.13）。而**前后台切换与系统状态变化本身不产生任何报错**，
/// 现在不记录，出问题时就没有现场可查。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 用于估算启动耗时。静态属性在首次访问时惰性初始化，
    /// 而 AppDelegate 会在启动早期被引用，因此这个时间点足够接近进程启动。
    private static let firstTouchUptime = ProcessInfo.processInfo.systemUptime

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 分段标记放在最前面：滚动日志文件里靠它区分不同次启动
        Log.shared.banner("App 启动 \(AppInfo.version)(\(AppInfo.build)) commit \(BuildInfo.commit)")

        let elapsed = (ProcessInfo.processInfo.systemUptime - Self.firstTouchUptime) * 1000
        Log.shared.info(.app, "启动完成｜耗时约 \(Int(elapsed)) ms（自 AppDelegate 首次加载）")
        Log.shared.info(
            .app,
            "运行环境｜\(AppInfo.displayName)｜\(AppInfo.deviceModel) / iOS \(AppInfo.systemVersion)｜\(AppInfo.bundleID)"
        )
        Log.shared.info(.app, "构建信息｜commit \(BuildInfo.commit)｜构建于 \(BuildInfo.builtAt)")

        // 日志落盘状态：这是"App 被杀后还能取证"的前提，必须确认它在工作
        Log.shared.info(
            .app,
            "日志落盘｜路径 \(Log.shared.filePathText)｜当前大小 \(Log.shared.fileSizeText)"
                + "｜已写入 \(Log.shared.fileWrittenLines) 行"
        )
        if let fileError = Log.shared.fileErrorText {
            Log.shared.error(.app, "日志落盘异常｜\(fileError)｜已降级为仅内存日志")
        }

        verifyBackgroundMode()
        startMonitors()

        return true
    }

    /// 主动校验后台模式声明，而不是假设它生效。
    /// 这条声明一旦失效，症状是"锁屏后录音停掉"，而那时再查配置就已经很晚了。
    private func verifyBackgroundMode() {
        let modes = AppInfo.backgroundModes
        Log.shared.info(.app, "后台模式声明｜\(modes.isEmpty ? "（空）" : modes.joined(separator: ", "))")
        if !AppInfo.hasAudioBackgroundMode {
            Log.shared.error(
                .app,
                "Info.plist 未声明 audio 后台模式 —— 锁屏后录音会被系统挂起，请检查 Resources/Info.plist"
            )
        }
    }

    private func startMonitors() {
        AudioEventObserver.shared.start()
        SystemStateMonitor.shared.start()
        SystemStateMonitor.shared.checkDisk(reason: "启动")

        // 首次访问 RecordingSession 即完成音频事件回调绑定 —— 必须早于任何录音动作，
        // 否则中断事件来了却没人处理（那正是"静默停录"的典型成因）。
        let closed = RecordingSession.shared.closeUnfinishedSessions()
        if !closed.isEmpty {
            Log.shared.warn(
                .session,
                "启动时有 \(closed.count) 个异常终止的会话已自动收尾，可在「记录」页查看"
            )
        }

        // 顺带按保留期清理过期音频（文本永久、音频有限，设计文档 4.5）
        RecordingLibrary.shared.purgeExpiredAudio(retentionDays: AppSettings.shared.retentionDays)
    }

    // MARK: - 前后台切换

    func applicationDidEnterBackground(_ application: UIApplication) {
        Log.shared.info(.app, "进入后台")
        SystemStateMonitor.shared.logSnapshot("进入后台")
        SystemStateMonitor.shared.checkDisk(reason: "进入后台")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // M1 会在这里做一次健康度校验：不信任"应该还在录"
        Log.shared.info(.app, "回到前台")
        SystemStateMonitor.shared.logSnapshot("回到前台")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.shared.info(.app, "进入活跃状态")
    }

    func applicationWillResignActive(_ application: UIApplication) {
        Log.shared.info(.app, "即将失去活跃状态")
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // M1 会在这里立刻 finalize 当前分片，把"被系统回收"的损失限制在一分钟内
        Log.shared.warn(
            .app,
            "收到内存警告｜当前 \(SystemStateMonitor.memoryFootprintText())"
        )
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // 注意：正常终止才会走到这里。被系统直接杀掉（jetsam）不会触发此回调，
        // 这也正是"日志必须落盘"的原因 —— 否则这种情况完全无从取证。
        Log.shared.info(.app, "App 即将终止（正常路径）")
        Log.shared.banner("App 正常终止")
    }
}
