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
        logCapabilitySnapshot()
        // 首次使用时静默备好默认实时模型（Base）。放在能力清单之后：
        // 这样日志里先是"已下载模型｜（无）"，紧接着才是"自动准备｜开始静默下载"，
        // 顺序与因果关系一目了然（排查时最怕的就是顺序错乱的日志）。
        ModelManager.shared.autoPrepareIfNeeded()

        return true
    }

    /// 启动时把「这台设备上哪些能力是活的」一次性写进日志。
    ///
    /// 为什么必须有这一条：这些信息此前只散落在自检页的十几行里，而自检页
    /// 只能**用眼睛看**。真出问题时我们手里通常只有一份导出的日志，
    /// 于是最常见的困境是：「到底是 whisper 没链接、还是模型没下载、
    /// 还是 FTS5 不可用导致检索降级了？」—— 这些问题必须在日志里能直接回答，
    /// 而不是靠回忆"当时自检页长什么样"。
    ///
    /// 频率：每次启动一次，开销可忽略。
    private func logCapabilitySnapshot() {
        let settings = AppSettings.shared
        Log.shared.info(.app, "配置摘要｜\(settings.summary())")

        // 两个推理引擎的链接状态。取不到版本号即说明静态库没真正链上 ——
        // 这比"编译通过"是强得多的证据（编译通过也可能只是没引用）。
        let whisper = WhisperEngine.systemInfo
        Log.shared.info(
            .app,
            "推理引擎｜whisper \(whisper.isEmpty ? "不可用" : "已链接（\(whisper.prefix(50))）")"
                + "｜sherpa-onnx \(SherpaOnnxEngine.summary)"
        )

        // 随包内置的 sherpa 模型：缺任何一个都会让对应能力**静默降级**
        // （代码里刻意做了失败降级），所以不仅报"缺不缺"，还要报"缺了会导致什么"。
        Log.shared.info(.app, "内置模型｜\(SherpaBundledModel.summary)")
        if !SherpaBundledModel.isReady {
            Log.shared.warn(
                .app,
                "内置模型不完整，以下能力将不可用（不报错，只表现为「功能没反应」）："
                    + SherpaBundledModel.impactText(of: SherpaBundledModel.missingModels)
            )
        }

        // whisper 模型是运行时下载的，因此"装没装"必须单独说
        let installed = ModelManager.shared.installedModels
        let modelBytes = ByteCountFormatter.string(
            fromByteCount: ModelManager.shared.installedBytes,
            countStyle: .file
        )
        Log.shared.info(
            .app,
            "已下载模型｜\(installed.isEmpty ? "（无）" : installed.map { $0.displayName }.joined(separator: "、"))"
                + "｜占用 \(modelBytes)"
        )

        // 学习层依赖的两个外部资源：语音包与词表。两者缺了也都只会"没反应"。
        Log.shared.info(.app, "朗读语音｜\(SpeechReader.availableVoicesSummary())")
        Log.shared.info(
            .app,
            "生词词表｜\(WordFrequencyTable.shared.summary)"
                + "｜学习语言 \(settings.learningLanguage)"
                + "｜水平档 \(settings.vocabularyLevel.title)"
        )

        // 数据规模：一眼看出"以前的数据还在不在"（升级/覆盖安装后最关心这个）
        let sessions = RecordingLibrary.shared.listSessions()
        let sessionBytes = ByteCountFormatter.string(
            fromByteCount: Int64(sessions.reduce(0) { $0 + $1.totalBytes }),
            countStyle: .file
        )
        let transcript = TranscriptStore.shared.coverage()
        let translation = TranslationStore.shared.coverage()
        Log.shared.info(
            .app,
            "数据规模｜会话 \(sessions.count) 个（\(sessionBytes)）"
                + "｜有文字稿 \(transcript.transcribed) 个"
                + "｜有译文 \(translation.translated) 个（\(TranslationStore.shared.totalEntryCount()) 条）"
                + "｜生词本 \(VocabularyStore.shared.summary())"
        )

        // 注意：此处读到的可能是「尚未探测」—— 索引能力是在后台队列上探测、
        // 再异步发布回主 actor 的，而本摘要是**同步**写的。
        // 真实结果由 storage 类别的「检索索引就绪｜…｜能力 …」那行给出。
        // （本轮之前这里会把异步发布前的初始值当成"不可用"写进日志，
        //   与 storage 行的"LIKE 扫描（降级）"自相矛盾 —— 真机日志里实际发生了。）
        Log.shared.info(.app, "检索索引｜\(SearchIndex.shared.capability.title)")
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
