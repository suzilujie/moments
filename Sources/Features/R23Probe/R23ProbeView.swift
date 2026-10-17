import SwiftUI
import ReplayKit
import AVFoundation

/// R23 探针页（临时）：验证「广播（系统内录）运行期间，主 App 能否继续采麦克风」。
///
/// 这是会议模式（M8）动工前的前置实测（设计文档 4.6 的 R23）。**用后即删**。
/// 页面回答两件事：
///   1. 麦克风计数在广播启动后是否还在涨 → 判互斥
///   2. 扩展（独立进程）的统计经 App Group 读回 → 看能拿到什么格式
///
/// 操作顺序：先「开始麦克风」→ 再点「系统内录」选本扩展 → 观察计数与结论。
struct R23ProbeView: View {

    @StateObject private var probe = R23ProbeModel()

    var body: some View {
        List {
            Section {
                Text("目的：验证「系统内录（广播）运行期间，主 App 能否继续用麦克风」。"
                    + "请先开麦克风，再启动系统内录，观察下方结论。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("麦克风（主 App 直采）") {
                HStack {
                    Text("累计样本帧")
                    Spacer()
                    Text("\(probe.micSampleCount)")
                        .monospacedDigit()
                }
                Text(probe.micStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(probe.isMicRunning ? "停止麦克风" : "开始麦克风") {
                    probe.toggleMic()
                }
            }

            Section("系统内录（广播扩展）") {
                BroadcastPickerView()
                    .frame(height: 50)
                Text(probe.broadcastStateText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("扩展统计（经 App Group）") {
                row("audioApp（对方/系统声）", "\(probe.appBufferCountText) 帧｜\(probe.appFormatText)")
                row("audioMic（扩展麦克风）", "\(probe.micBufferCountText) 帧｜\(probe.micFormatText)")
                if probe.appGroupAvailable == false {
                    Text("App Group 不可用：侧载未注入该 entitlement，扩展统计读不到。"
                        + "互斥判定仍可用上方「麦克风计数」完成。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Button("刷新扩展统计") { probe.reloadExtensionStats() }
            }

            Section("结论") {
                Text(probe.conclusion)
                    .font(.footnote)
            }
        }
        .navigationTitle("R23 探针")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// 探针页的状态与动作。
///
/// 麦克风采集用一套**独立的** AVAudioEngine，不碰现有 `AudioCaptureEngine` /
/// `CapturePipeline` 链路 —— 探针是临时的一次性验证，与正式录音完全隔离。
@MainActor
final class R23ProbeModel: ObservableObject {

    @Published var micSampleCount = 0
    @Published var micStatus = "未开始"
    @Published var isMicRunning = false
    @Published var broadcastStateText = "未检测到广播"
    @Published var appBufferCountText = "-"
    @Published var micBufferCountText = "-"
    @Published var appFormatText = "-"
    @Published var micFormatText = "-"
    /// nil = 尚未确定；false = 侧载未注入 App Group entitlement
    @Published var appGroupAvailable: Bool?
    @Published var conclusion = "请先开始麦克风，再启动系统内录。"

    private let engine = AVAudioEngine()
    private var timer: Timer?
    private var sampleCounter = 0
    /// 广播启动那一刻的麦克风计数（互斥判定的基准）
    private var sampleCountWhenBroadcastStarted: Int?

    private let groupID = "group.com.xfish.moments"
    private let statFileName = "broadcast-probe.plist"

    // MARK: - 生命周期

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        reloadExtensionStats()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isMicRunning { stopMic() }
    }

    private func tick() {
        micSampleCount = sampleCounter
        reloadExtensionStats()
        updateConclusion()
    }

    // MARK: - 麦克风

    func toggleMic() {
        isMicRunning ? stopMic() : startMic()
    }

    private func startMic() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                micStatus = "麦克风权限未授予"
                return
            }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try? session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                Task { @MainActor in self?.sampleCounter += Int(buffer.frameLength) }
            }
            engine.prepare()
            do {
                try engine.start()
                isMicRunning = true
                micStatus = "采集中（每秒刷新计数）"
            } catch {
                micStatus = "麦克风启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isMicRunning = false
        micStatus = "已停止"
    }

    // MARK: - 扩展统计（App Group）

    func reloadExtensionStats() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            appGroupAvailable = false
            broadcastStateText = "App Group 不可用（侧载未注入 entitlement）"
            return
        }
        appGroupAvailable = true

        let url = container.appendingPathComponent(statFileName)
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            broadcastStateText = "扩展尚未写统计（未启动，或 App Group 未通）"
            return
        }

        appBufferCountText = "\(dict["appBufferCount"] ?? 0)"
        micBufferCountText = "\(dict["micBufferCount"] ?? 0)"
        appFormatText = dict["appFormat"] as? String ?? "-"
        micFormatText = dict["micFormat"] as? String ?? "-"
        let finished = dict["finished"] as? Bool ?? false
        broadcastStateText = finished ? "广播已结束" : "广播运行中"

        // 只在「麦克风正在采」时记下广播启动基准；顺序反了（先广播后开麦）不记
        if sampleCountWhenBroadcastStarted == nil, isMicRunning {
            sampleCountWhenBroadcastStarted = sampleCounter
        }
    }

    // MARK: - 结论

    private func updateConclusion() {
        guard let startCount = sampleCountWhenBroadcastStarted else {
            conclusion = "请先开始麦克风，再启动系统内录。"
            return
        }
        // 广播开始后，麦克风计数若还在涨 = 不互斥；停住 = 互斥
        if micSampleCount > startCount {
            conclusion = "不互斥：广播运行期间麦克风仍在采（计数从 \(startCount) 涨到 \(micSampleCount)）。"
                + "后续可简化为「单模式 + 开关」。"
        } else {
            conclusion = "互斥：广播运行期间麦克风停止采集（计数停在 \(startCount)）。"
                + "后续必须按「双模式切换」设计。"
        }
    }
}

/// 系统广播选择器（RPSystemBroadcastPickerView）的 SwiftUI 包装。
///
/// 用户点击后弹出系统的「屏幕录制」入口，在其中选择本 App 的广播扩展。
/// 这是系统内录（会议模式）**无法绕过**的一步：广播扩展只能由用户经系统入口启动，
/// 主 App 不能替用户点（设计文档 4.6 约束）。
private struct BroadcastPickerView: UIViewRepresentable {

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = "com.xfish.moments.Broadcast"
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
