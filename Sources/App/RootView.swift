import SwiftUI

/// M0 自检页。
///
/// 这一页不是为了好看，而是为了在「无断点调试器」的前提下，把后续必然会用到
/// 的前提一次性验证掉：plist 声明是否真的生效、麦克风权限能否拿到、音频会话
/// 能否激活、原生采集格式与音频事件能否收到（设计文档 4.14）。
///
/// 原则：**关键状态必须在设备上直接可见，而不是靠猜。**
struct RootView: View {

    @StateObject private var model = SelfCheckModel()
    @State private var showingLogs = false

    var body: some View {
        NavigationStack {
            List {
                buildSection
                environmentSection
                permissionSection
                sessionSection
                systemSection
                eventSection
                logSection
            }
            .navigationTitle("M0 自检")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("日志") { showingLogs = true }
                }
            }
            .sheet(isPresented: $showingLogs) {
                LogView()
            }
        }
        .task { await model.refresh() }
    }

    // MARK: - 构建指纹

    private var buildSection: some View {
        Section("构建") {
            row("版本", "\(AppInfo.version) (\(AppInfo.build))")
            row("提交", BuildInfo.commit)
            row("构建时间", BuildInfo.builtAt)
        }
    }

    // MARK: - 运行环境与 plist 声明

    private var environmentSection: some View {
        Section("运行环境") {
            row("设备", "\(AppInfo.deviceModel) / iOS \(AppInfo.systemVersion)")
            row("Bundle ID", AppInfo.bundleID)
            row("后台模式", AppInfo.backgroundModes.isEmpty
                ? "（空）"
                : AppInfo.backgroundModes.joined(separator: ", "))

            if AppInfo.hasAudioBackgroundMode {
                note("后台音频模式已声明 —— 锁屏后录音不被挂起的前提已具备", color: .secondary)
            } else {
                note("后台音频模式缺失 —— 锁屏后录音会被挂起，请检查 Resources/Info.plist", color: .red)
            }
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section("麦克风权限") {
            row("当前状态", model.permissionText)
            row("用途说明", AppInfo.microphoneUsageDescription)

            Button("申请录音权限") {
                Task { await model.requestPermission() }
            }
            .disabled(model.permissionText == "已授权")
        }
    }

    // MARK: - 音频会话

    private var sessionSection: some View {
        Section("音频会话") {
            Picker("会话模式", selection: $model.mode) {
                ForEach(AudioSessionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            note(model.mode.detail, color: .secondary)

            row("会话状态", model.sessionText)
            row("原生采集格式", model.inputFormatText)

            HStack {
                Button("激活会话") { model.activateSession() }
                Spacer()
                Button("释放会话") { model.releaseSession() }
                    .foregroundStyle(.secondary)
            }

            Button("记录一次音频上下文") { model.logContext() }
        }
    }

    // MARK: - 系统状态

    private var systemSection: some View {
        Section("系统状态") {
            note(model.systemStateText, color: .secondary)
            Button("记录一次状态快照") { model.logSnapshot() }
            Button("检查磁盘余量") { model.checkDisk() }
        }
    }

    // MARK: - 音频事件监听

    private var eventSection: some View {
        Section("音频事件监听") {
            row("监听状态", model.observerText)
            row("已收到事件数", "\(model.eventCount)")
            note(
                "已监听：会话中断 / 路由变更 / 媒体服务重置 / 媒体服务丢失 / 音频图配置变更。"
                    + "其中「音频图配置变更」不报错却会让音频静默中断，是 M1 最需要确认的一类。",
                color: .secondary
            )
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("日志") {
            row("内存条数", "\(model.logCount)")
            row("落盘文件", model.logFilePath)
            row("文件大小", model.logFileSize)
            row("已写入行数", "\(model.logLines)")

            if let error = model.logFileError {
                note("落盘异常：\(error)（已降级为仅内存日志）", color: .orange)
            } else {
                note("日志同时写入内存、磁盘与系统日志；App 被系统杀掉后仍可从文件取证。", color: .secondary)
            }

            Button("查看日志 / 导出") { showingLogs = true }
        }
    }

    // MARK: - 小组件

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
    }
}

/// 自检页的状态与动作。
///
/// 刻意不做成「页面直接调 AudioSessionManager」，是因为 M1 之后录音内核会变成
/// 一个状态机（设计文档 4.7），UI 只能作为观察者。现在就把这层分开，
/// 后面替换内核时 UI 不需要重写。
@MainActor
final class SelfCheckModel: ObservableObject {

    @Published var permissionText = "读取中…"
    @Published var sessionText = "尚未配置"
    @Published var inputFormatText = "未读取"
    @Published var systemStateText = "-"
    @Published var observerText = "-"
    @Published var eventCount = 0
    @Published var logCount = 0
    @Published var logFilePath = "-"
    @Published var logFileSize = "-"
    @Published var logLines = 0
    @Published var logFileError: String?
    @Published var mode: AudioSessionMode = .coexistent

    private let audio = AudioSessionManager.shared

    func refresh() async {
        permissionText = audio.permissionDescription()
        sessionText = audio.lastResult
        refreshDiagnostics()
        if permissionText == "已授权" {
            inputFormatText = audio.nativeInputFormat()
        }
    }

    func requestPermission() async {
        let granted = await audio.requestPermission()
        permissionText = audio.permissionDescription()
        Log.shared.info(.session, "权限申请完成｜结果=\(granted ? "已授权" : "被拒绝")")
        if granted {
            inputFormatText = audio.logInputFormat()
        }
        refreshDiagnostics()
    }

    func activateSession() {
        audio.activate(mode)
        sessionText = audio.lastResult
        if permissionText == "已授权" {
            inputFormatText = audio.nativeInputFormat()
        }
        refreshDiagnostics()
    }

    func releaseSession() {
        audio.deactivate()
        sessionText = audio.lastResult
        refreshDiagnostics()
    }

    func logContext() {
        Log.shared.info(.session, "手动记录音频上下文｜\(audio.contextText())")
        refreshDiagnostics()
    }

    func logSnapshot() {
        SystemStateMonitor.shared.logSnapshot("自检页手动触发")
        refreshDiagnostics()
    }

    func checkDisk() {
        SystemStateMonitor.shared.checkDisk(reason: "自检页手动触发")
        refreshDiagnostics()
    }

    private func refreshDiagnostics() {
        systemStateText = SystemStateMonitor.shared.snapshotText()
        eventCount = AudioEventObserver.shared.eventCount
        observerText = AudioEventObserver.shared.isStarted ? "已注册" : "未注册"

        let log = Log.shared
        logCount = log.snapshot().count
        logFilePath = log.filePathText
        logFileSize = log.fileSizeText
        logLines = log.fileWrittenLines
        logFileError = log.fileErrorText
    }
}

#Preview {
    RootView()
}
