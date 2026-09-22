import Foundation

/// 录音内核状态（设计文档 4.7 节）。
///
/// 这个枚举是**唯一权威状态**：所有状态变更只经由 RecordingSession 一个串行执行体，
/// UI 只作为观察者。多处改状态必然产生"UI 显示在录、实际已经停了"这类极难查的问题。
enum CaptureState: String {
    case idle
    case preparing
    case recording
    case interrupted
    case recovering
    case stopping
    case finalizing
    case failed

    /// 是否处于"用户认为正在录音"的状态（用于恢复标记与看门狗判定）。
    var isActive: Bool {
        switch self {
        case .preparing, .recording, .interrupted, .recovering, .stopping, .finalizing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle: return "未开始"
        case .preparing: return "准备中"
        case .recording: return "正在录音"
        case .interrupted: return "已被中断"
        case .recovering: return "正在恢复"
        case .stopping: return "正在停止"
        case .finalizing: return "正在收尾"
        case .failed: return "已失败"
        }
    }
}

/// 采集源类型（设计文档 4.6 / 10.3）。
///
/// M1 只实现 `.microphone`；`.systemAudio`（会议模式）是 M8 的目标，
/// 这里先把枚举定义出来，是为了让上层从第一天起就不假设"只有一种音源"。
enum CaptureSourceKind: String {
    case microphone
    case systemAudio

    var title: String {
        switch self {
        case .microphone: return "环境模式（麦克风）"
        case .systemAudio: return "会议模式（系统内录）"
        }
    }
}

/// 时间轴断口（设计文档 4.3 / 4.12）。
///
/// 设计原则是**让漏录可见**，而不是假装时间轴连续。
/// 因此断口不是异常，而是一种必须被如实记录的正常数据。
struct CaptureGap: Identifiable, Equatable {
    let id: UUID
    let startMs: Int
    let endMs: Int
    let reason: String

    init(id: UUID = UUID(), startMs: Int, endMs: Int, reason: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.reason = reason
    }

    var durationMs: Int { max(0, endMs - startMs) }
}

/// 内核对外广播的快照，供 UI 观察。
struct CaptureSnapshot {
    var state: CaptureState = .idle
    var source: CaptureSourceKind = .microphone
    var sessionId: String?
    var startedAt: Date?
    /// 已录时长（按**样本计数**推导，不用墙钟 —— 见设计文档 4.11）
    var recordedMs: Int = 0
    var segmentCount: Int = 0
    /// 最近一片写入耗时，用于及早发现落盘跟不上采集
    var lastWriteCostMs: Int = 0
    /// 环形缓冲溢出丢弃的样本数（> 0 即说明消费者跟不上，属严重信号）
    var droppedSamples: Int = 0
    var gapCount: Int = 0
    var totalGapMs: Int = 0
    /// 当前降档原因（空表示未降档）
    var degradation: String = ""
    var lastError: String?

    var recordedTimeText: String {
        let totalSeconds = recordedMs / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// 采集链路的错误类型（区分"可恢复"与"需要用户介入"，避免上层一刀切处理）。
enum CaptureError: LocalizedError {
    case microphonePermissionDenied
    case audioSessionActivationFailed(String)
    case engineStartFailed(String)
    case noInputAvailable
    case diskSpaceTooLow(remainingGB: Double)
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "麦克风权限未授予，请到「设置 → 时刻 → 麦克风」中开启"
        case .audioSessionActivationFailed(let detail):
            return "音频会话激活失败：\(detail)"
        case .engineStartFailed(let detail):
            return "采集引擎启动失败：\(detail)"
        case .noInputAvailable:
            return "当前没有可用的音频输入设备"
        case .diskSpaceTooLow(let remainingGB):
            return String(format: "剩余存储空间不足（仅 %.2f GB），已停止录音以保护已录内容", remainingGB)
        case .recordingFailed(let detail):
            return "录音失败：\(detail)"
        }
    }
}
