import Foundation

/// 停滞看门狗（设计文档 4.13）。
///
/// ## 它解决的是哪一类问题
/// 系统通知覆盖的是"系统明确告知我们被打断"的情形。但还有一类更危险的情况：
/// **系统没有报任何错，音频却已经不来了** —— 例如音频图被重建后旧引擎静默失效。
/// 这种状态下所有回调都不触发，UI 也显示"正在录音"，只有"长时间收不到音频帧"能识别它。
///
/// ## 两个实现要点
///   1. **必须用单调时钟**。设备休眠、系统时间被调整都会让墙钟跳变；
///      用墙钟判定会导致误报（把正常录音判成停滞）或漏报。
///   2. 恢复后要有**冷却期**，否则真故障时会高频重建引擎 —— 既费电，也会把日志刷满、
///      把真正有用的信息淹没。
@MainActor
final class CaptureWatchdog {

    /// 超过该秒数没有收到音频帧即判定停滞
    private let staleThresholdSeconds: Double
    /// 恢复后的冷却时间
    private let cooldownSeconds: Double
    /// 检查间隔
    private let tickSeconds: Double = 1.0

    /// 停滞判定回调（在冷却期外、且确实停滞时调用）
    var onStall: ((_ stalledSeconds: Double) -> Void)?

    /// **每秒心跳回调**（每个 tick 都调用，与是否停滞无关）。
    ///
    /// 存在的理由：看门狗本来就已经有一个 1 秒定时器和一个进度探针
    ///（`progressProvider`，本项目传入环形缓冲的累计写入帧数），
    /// 只是结果只用于停滞判定、没有喂给界面。让上层挂到这里，
    /// 就不必为"刷新已录时长"另起一个定时器 ——
    /// 两个定时器做同一件事，迟早会出现两者读数不一致。
    var onTick: (() -> Void)?

    /// 进度探针：返回一个单调递增的计数（本项目传入环形缓冲的累计写入帧数）。
    /// 计数发生变化即视为"音频还在来"。
    /// 用探针而不是让实时线程回调主线程，避免了每秒十次的跨线程开销。
    var progressProvider: (() -> Int)?

    private var timer: DispatchSourceTimer?
    private var lastFrameUptime: Double = 0
    private var lastRecoveryUptime: Double = 0
    private var lastProgress: Int = -1
    private var isRunning = false

    private(set) var stallCount = 0
    private(set) var lastStallSeconds: Double = 0

    init(staleThresholdSeconds: Double = 3.0, cooldownSeconds: Double = 10.0) {
        self.staleThresholdSeconds = staleThresholdSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    func start(now: Double = ProcessInfo.processInfo.systemUptime) {
        stop()
        lastFrameUptime = now
        lastRecoveryUptime = 0
        isRunning = true

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + tickSeconds,
            repeating: tickSeconds,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()

        Log.shared.info(
            .capture,
            "看门狗已启动｜阈值 \(Int(staleThresholdSeconds))s｜冷却 \(Int(cooldownSeconds))s"
        )
    }

    func stop() {
        guard isRunning else { return }
        timer?.cancel()
        timer = nil
        isRunning = false
        Log.shared.info(.capture, "看门狗已停止｜累计判定停滞 \(stallCount) 次")
    }

    /// 手动喂狗（探针之外需要显式标记进度时使用）。
    func feed(now: Double = ProcessInfo.processInfo.systemUptime) {
        lastFrameUptime = now
    }

    /// 读取一次探针；若计数有变化则更新基准时间。
    /// - Returns: 是否存在进度
    @discardableResult
    func sampleProgress(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let progressProvider else { return false }
        let current = progressProvider()
        guard current != lastProgress else { return false }
        lastProgress = current
        lastFrameUptime = now
        return true
    }

    /// 标记一次恢复动作，启动冷却期。
    func markRecovered(now: Double = ProcessInfo.processInfo.systemUptime) {
        lastRecoveryUptime = now
        // 恢复后把基准重置，避免刚恢复就被判定为停滞
        lastFrameUptime = now
    }

    var secondsSinceLastFrame: Double {
        ProcessInfo.processInfo.systemUptime - lastFrameUptime
    }

    private func tick() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // 先用探针更新"最后一帧时间"，再做停滞判定
        sampleProgress(now: now)

        // 心跳放在冷却判定**之前**：冷却期内不判定停滞，但界面上的数字
        // 仍然必须每秒刷新 —— 否则恢复期间界面会僵住，看起来像卡死。
        onTick?()

        // 冷却期内不判定（防止真故障时高频重建）
        if lastRecoveryUptime > 0, now - lastRecoveryUptime < cooldownSeconds {
            return
        }

        let stalled = now - lastFrameUptime
        guard stalled > staleThresholdSeconds else { return }

        stallCount += 1
        lastStallSeconds = stalled
        lastRecoveryUptime = now

        Log.shared.error(
            .capture,
            "看门狗判定停滞｜已 \(String(format: "%.1f", stalled)) 秒未收到音频帧"
                + "（阈值 \(Int(staleThresholdSeconds))s）｜第 \(stallCount) 次判定"
        )
        onStall?(stalled)
    }
}
