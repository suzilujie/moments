import AVFoundation
import Foundation

/// 点句回听播放器（M4）。
///
/// ## 相比 M1/M2 的"逐分片播放"，这里补齐的是真正有用的那一步
/// 之前点一句话只能播它所在的**整分钟**，用户要自己听出是哪一句 —— 那等于没做。
/// 现在能做到「从句子起点开始、到句子终点停下，且能复读」，
/// 这是本项目「找得到、听得回」的核心体验。
///
/// ## 三个实现要点
/// 1. **跨片定位**：会话音频是多个 60 秒分片，一句话可能横跨两片。
///    因此要把"会话毫秒"换算成"分片文件 + 片内偏移"，换算错了的表现是
///    "播放位置偏一点"，而用户只会觉得"播放器不好用"。
/// 2. **变速必须不变调**：`AVAudioPlayer.rate`（配合 `enableRate`）做的是时间伸缩，
///    音高保持不变。若用简单降速，人声会变调，反而更听不懂 —— 那正好抵消慢放的意义。
/// 3. **结束靠定时器**：单句只占分片文件的一小段，不能等"文件播完"。
///    定时器时长要按倍率折算（0.5× 播放 2.5 秒音频要占 5 秒墙钟）。
@MainActor
final class SentencePlayer: ObservableObject {

    @Published private(set) var playingSessionId: String?
    /// 正在播放的"片段标识"：转写句用 segmentId，分片列表用文件名
    @Published private(set) var playingSegmentId: String?
    @Published private(set) var rate: Float = 1.0
    @Published private(set) var isLooping = false
    @Published private(set) var lastError: String?

    /// 可选的倍率。0.5 / 0.75 是语言学习最常用的两档。
    static let availableRates: [Float] = [0.5, 0.75, 1.0]

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    /// 当前播放范围（单句循环与倍率切换时要用它重播）
    private var currentRange: (sessionId: String, segmentId: String, startMs: Int, endMs: Int)?

    var isPlaying: Bool { playingSegmentId != nil }

    var rateText: String {
        String(format: "%.2g×", rate)
    }

    // MARK: - 播放

    /// 播放一句话（或一整片）。
    func play(sessionId: String, segmentId: String, startMs: Int, endMs: Int) {
        stop()

        guard let manifest = RecordingLibrary.shared.loadManifest(sessionId: sessionId) else {
            lastError = "找不到这次录音的记录"
            return
        }
        // 定位分片：优先找**包含起点**的那一片；找不到就退到起点之前最近的一片
        let entry = manifest.segments.first { startMs >= $0.startMs && startMs < $0.endMs }
            ?? manifest.segments.last { $0.startMs <= startMs }
        guard let entry else {
            lastError = "该句所在的分片已不存在"
            return
        }

        let url = RecordingLibrary.shared.segmentURL(sessionId: sessionId, fileName: entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 明确说出原因：音频会按保留期被清理，这不是 bug 而是预期行为
            lastError = "音频文件已被清理（文字与记录仍在）"
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.enableRate = true
            audioPlayer.rate = rate
            audioPlayer.prepareToPlay()

            // 片内偏移 = 目标时刻 − 该片起点。
            // 注意这里**不补偿** AAC 编码器启动延迟（约两千样本，几十毫秒）：
            // 对"听回一句话"这个用途，几十毫秒听不出来；而补偿量若估错反而更糟。
            let offsetSeconds = Double(max(0, startMs - entry.startMs)) / 1000.0
            audioPlayer.currentTime = offsetSeconds
            audioPlayer.play()

            player = audioPlayer
            playingSessionId = sessionId
            playingSegmentId = segmentId
            currentRange = (sessionId, segmentId, startMs, endMs)
            lastError = nil
            scheduleStop(afterMs: max(300, endMs - startMs))
        } catch {
            lastError = "播放失败：\(error.localizedDescription)"
            Log.shared.error(.storage, "点句回听播放失败｜\(entry.fileName)｜\(error.localizedDescription)")
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        playingSessionId = nil
        playingSegmentId = nil
        currentRange = nil
    }

    /// 切换倍率。正在播放时立即生效（用户能马上听出区别）。
    func cycleRate() {
        let rates = Self.availableRates
        let index = rates.firstIndex(of: rate) ?? (rates.count - 1)
        rate = rates[(index + 1) % rates.count]

        player?.rate = rate
        if let range = currentRange {
            scheduleStop(afterMs: max(300, range.endMs - range.startMs))
        }
    }

    func toggleLoop() {
        isLooping.toggle()
    }

    // MARK: - 内部

    private func scheduleStop(afterMs ms: Int) {
        stopTimer?.invalidate()
        // 倍率会改变墙钟时长：0.5× 播 2.5 秒音频要占 5 秒
        let interval = Double(ms) / 1000.0 / Double(max(0.25, rate))
        stopTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleSentenceFinished()
            }
        }
    }

    private func handleSentenceFinished() {
        guard let range = currentRange else {
            stop()
            return
        }
        if isLooping {
            // 单句循环是语言学习里最高频的操作，这里做到"一步可达"：
            // 打开循环后就不需要再做任何操作
            play(
                sessionId: range.sessionId,
                segmentId: range.segmentId,
                startMs: range.startMs,
                endMs: range.endMs
            )
        } else {
            stop()
        }
    }
}
