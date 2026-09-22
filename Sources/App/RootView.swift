import SwiftUI

/// M0 自检页。
///
/// 这一页不是为了好看，而是为了在「无断点调试器」的前提下，把后续必然会用到
/// 的前提一次性验证掉：plist 声明是否真的生效、麦克风权限能否拿到、音频会话
/// 能否激活、原生采集格式是多少（设计文档 4.14 节）。
///
/// M1 起这一页会被真正的录音界面取代，但它承载的原则会保留：
/// **关键状态必须在设备上直接可见，而不是靠猜。**
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
            row("后台模式", AppInfo.backgroundModes.isEmpty ? "（空）" : AppInfo.backgroundModes.joined(separator: ", "))

            if AppInfo.hasAudioBackgroundMode {
                Text("后台音频模式已声明 —— 锁屏后录音不被挂起的前提已具备")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("后台音频模式缺失 —— 锁屏后录音会被系统挂起，请检查 Resources/Info.plist")
                    .font(.footnote)
                    .foregroundStyle(.red)
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

            Text(model.mode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            row("会话状态", model.sessionText)
            row("原生采集格式", model.inputFormatText)

            HStack {
                Button("激活会话") { model.activateSession() }
                Spacer()
                Button("释放会话") { model.releaseSession() }
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("日志") {
            row("已缓存条数", "\(model.logCount)")
            Button("查看日志 / 导出") { showingLogs = true }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// 自检页的状态与动作。
///
/// 刻意不做成"页面直接调 AudioSessionManager"，是因为 M1 之后录音内核会变成
/// 一个状态机（设计文档 4.7），UI 只能作为观察者。现在就把这层分开，
/// 后面替换内核时 UI 不需要重写。
@MainActor
final class SelfCheckModel: ObservableObject {

    @Published var permissionText = "读取中…"
    @Published var sessionText = "尚未配置"
    @Published var inputFormatText = "未读取"
    @Published var logCount = 0
    @Published var mode: AudioSessionMode = .coexistent

    private let audio = AudioSessionManager()

    func refresh() async {
        permissionText = audio.permissionDescription()
        sessionText = audio.lastResult
        logCount = Log.shared.snapshot().count
    }

    func requestPermission() async {
        let granted = await audio.requestPermission()
        permissionText = audio.permissionDescription()
        Log.shared.info(.session, "权限申请完成｜结果=\(granted ? "已授权" : "被拒绝")")
        if granted {
            inputFormatText = audio.nativeInputFormat()
        }
        logCount = Log.shared.snapshot().count
    }

    func activateSession() {
        audio.activate(mode)
        sessionText = audio.lastResult
        // 授权后才有意义读采集格式，否则拿到的是无效值
        if permissionText == "已授权" {
            inputFormatText = audio.nativeInputFormat()
        }
        logCount = Log.shared.snapshot().count
    }

    func releaseSession() {
        audio.deactivate()
        sessionText = audio.lastResult
        logCount = Log.shared.snapshot().count
    }
}

#Preview {
    RootView()
}
