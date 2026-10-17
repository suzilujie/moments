import ReplayKit
import Foundation

/// R23 探针用的最小广播处理器（Broadcast Upload Extension 的入口）。
///
/// ## 它只做一件事：统计 + 写 App Group
/// 会议模式（系统内录）的正式实现是 M8。当前这个处理器**不搬运、不落盘、不推理**，
/// 只把「收到了多少 audioApp/audioMic 的 buffer、什么格式」写进 App Group 共享容器，
/// 供主 App 的 R23 探针页读取 —— 用来回答两个问题：
///   1. 广播运行期间主 App 能否继续采麦克风（互斥，R23）
///   2. 扩展到底能拿到什么（audioApp / audioMic 的格式与回调频率）
///
/// ## 为什么不在扩展里做更多
/// 扩展是独立进程、内存上限几十 MB（设计文档 4.6 约束二、R24），任何推理/编码/积压
/// 都会让它被杀。探针阶段连"搬运音频"都不做，把内存风险完全排除在探针之外。
final class SampleHandler: RPBroadcastSampleHandler {

    private var appBufferCount = 0
    private var micBufferCount = 0
    private var appFormatText = "-"
    private var micFormatText = "-"
    private var startedAtText: String?

    private let groupID = "group.com.xfish.moments"
    private let statFileName = "broadcast-probe.plist"

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        startedAtText = Date().description
        persist()
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        switch sampleBufferType {
        case .audioApp:
            appBufferCount += 1
            appFormatText = describe(sampleBuffer)
        case .audioMic:
            micBufferCount += 1
            micFormatText = describe(sampleBuffer)
        case .video:
            // 屏幕视频一律只计数不保存（设计文档 4.6 约束三/五）
            break
        @unknown default:
            break
        }
        // 每次回调都写一次 plist：主 App 端每 1 秒轮询读它，实时性足够。
        // 写盘是覆盖式小文件，几十字节量级，开销可忽略。
        persist()
    }

    override func broadcastPaused() {
        persist()
    }

    override func broadcastResumed() {
        persist()
    }

    override func broadcastFinished() {
        persist(finished: true)
    }

    /// 从 CMSampleBuffer 读出音频流基本描述（采样率 / 声道数）。
    /// 这一项直接决定 M8 的 SystemAudioSource 要不要做格式转换。
    private func describe(_ buffer: CMSampleBuffer) -> String {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else {
            return "非音频"
        }
        let d = asbd.pointee
        return "\(Int(d.mSampleRate))Hz \(Int(d.mChannelsPerFrame))ch"
    }

    private func persist(finished: Bool = false) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        ) else {
            // 拿不到 App Group 容器 = entitlement 未生效（侧载时常见）。
            // 不写文件，主 App 探针页会显示"扩展统计不可读"并降级到只看麦克风计数。
            return
        }
        let dict: [String: Any] = [
            "startedAt": startedAtText ?? "-",
            "appBufferCount": appBufferCount,
            "micBufferCount": micBufferCount,
            "appFormat": appFormatText,
            "micFormat": micFormatText,
            "finished": finished,
            "writtenAt": Date().description
        ]
        let url = container.appendingPathComponent(statFileName)
        try? (dict as NSDictionary).write(to: url, atomically: true)
    }
}
