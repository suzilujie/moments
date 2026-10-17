import Foundation

/// 录音输入电平（实时声波用）。
///
/// ## 为什么独立成一个对象，而不是塞进 `CaptureSnapshot`
/// `RecordingSession` 是录音页观察的对象。往它的 `@Published snapshot` 里加一个
/// 每 100 ms 变一次的电平，会让**整个录音页**每秒重绘 10 次 ——
/// 而真正需要重绘的只有那 32 根柱子（字幕、按钮、计时一件都没变）。
/// 单独成一个 `ObservableObject` 之后，只有 `WaveformView` 观察它，
/// 其余视图不受影响。这不是洁癖：字幕区每出一句都要重排布局，
/// 再叠加 10 Hz 的整页重绘，滚动会开始掉帧。
///
/// ## 数据来源与线程约定
/// 电平由 `CapturePipeline` 在**后台消费队列**上算：那里本来就每 100 ms
/// 握着一批已转成 16 kHz 的样本，顺手算一次均方根几乎零成本。
/// **实时音频线程一行都没改** —— 那条线程只允许 memcpy
///（见 `AudioCaptureEngine` 的 installTap 注释）。
@MainActor
final class AudioLevelMonitor: ObservableObject {

    static let shared = AudioLevelMonitor()

    /// 0…1 的显示电平（-60 dB → 0，0 dB → 1）。
    ///
    /// 只在录音时为非零；停止后必须 `reset()`，
    /// 否则波形会定格在最后一次的高度上，看起来像还在收音。
    @Published private(set) var level: Float = 0

    private init() {}

    /// 写入一次电平。调用方已在主线程（见 `RecordingSession` 里的接线）。
    func update(_ value: Float) {
        level = value
    }

    func reset() {
        guard level != 0 else { return }
        level = 0
    }
}
