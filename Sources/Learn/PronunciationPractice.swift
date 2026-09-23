import AVFoundation
import Foundation

enum PracticeError: LocalizedError {
    case modelNotInstalled(String)
    case sessionActivationFailed
    case recorderFailed(String)
    case noRecording
    case tooShort
    case loadAudioFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name):
            return "跟读需要本地模型「\(name)」，尚未下载。请到「设置 → 模型」下载后重试。"
        case .sessionActivationFailed:
            return "音频会话无法激活（可能被其他 App 占用）。请稍后重试。"
        case .recorderFailed(let reason):
            return "录音启动失败：\(reason)"
        case .noRecording:
            return "没有可评测的录音。"
        case .tooShort:
            return "录音太短（不到 0.3 秒），无法评测。请把整句读完。"
        case .loadAudioFailed(let reason):
            return "读取录音失败：\(reason)"
        case .transcriptionFailed(let reason):
            return "识别失败：\(reason)"
        }
    }
}

/// 跟读录音器。
///
/// **复用 `AudioSessionManager`（M1）而不是自己 setCategory**：
/// 会话配置在本项目里已有唯一一处经过验证的实现（含完整的激活前/后日志），
/// 再写一份就会出现两处配置互相覆盖，且真机排查时不知道该看哪条日志。
///
/// 标 `@MainActor` 是必须的，不是保守起见：`AudioSessionManager` 本身就是 `@MainActor`，
/// 从一个普通类里调它属 actor 隔离违规（编译期错误）。
/// 而本类要做的只有"开始录音 / 停止录音 / 读电平"三件事，全是短操作
///（音频数据由系统直接写进文件，不经这里搬运），放主线程是合适的。
@MainActor
final class PracticeRecorder {

    static let shared = PracticeRecorder()

    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    private(set) var startedAt: Date?

    private init() {}

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start(mode: AudioSessionMode) throws -> URL {
        stop()

        guard AudioSessionManager.shared.activate(mode) else {
            throw PracticeError.sessionActivationFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("practice-\(UUID().uuidString).m4a")

        // 与 M1 落盘保持同一格式（16 kHz 单声道 AAC）：
        // 这样 WhisperEngine.loadSamples 不需要重采样，
        // 也保证"跟读听到的"与"会话录到的"走的是同一套信号链 ——
        // 否则跟读通过但录音识别不准，用户会不知道问题出在哪一边。
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: AudioFormatConverter.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            AudioSessionManager.shared.deactivate()
            throw PracticeError.recorderFailed("AVAudioRecorder 未能开始录音")
        }

        self.recorder = recorder
        self.currentURL = url
        self.startedAt = Date()
        Log.shared.info(.capture, "跟读录音开始｜\(url.lastPathComponent)")
        return url
    }

    /// 停止并返回录音文件（没有在录时返回 nil）。
    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = currentURL
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        self.startedAt = nil
        AudioSessionManager.shared.deactivate()
        return url
    }

    /// 当前输入电平（0...1）。
    ///
    /// 必须给用户电平反馈：否则他无法知道麦克风到底有没有在收 ——
    /// 一路静音录到底、最后拿到 0 分，那种体验非常挫败，
    /// 而且用户会归因于"识别不准"而不是"麦克风没收到声音"。
    func currentLevel() -> Float {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)   // dBFS，约 -160...0
        let normalized = powf(10, power / 20)
        return max(0, min(1, normalized))
    }
}

/// 跟读评测 worker（**非隔离**）。
///
/// 分层理由与 `TranscriptionWorker` 完全相同：
///   · whisper 上下文不是线程安全的，且转写是几百毫秒级的重活，不能占主线程；
///   · 本类只在自己的串行队列上跑，并**独占一个 `WhisperEngine` 实例** ——
///     与实时字幕、终稿转写的引擎互不干扰（共用会因非线程安全而崩溃）。
final class PronunciationWorker {

    private let queue = DispatchQueue(label: "com.xfish.moments.practice.worker", qos: .userInitiated)
    private var engine: WhisperEngine?
    private var loadedModelPath: String?

    /// 评测一段跟读录音。
    ///
    /// `completion` **在 worker 队列上回调** —— 调用方需自行切回主 actor
    /// （既有范式：`Task { @MainActor in }`，见 ModelManager / RecordingSession）。
    func evaluate(
        recordingURL: URL,
        reference: String,
        modelURL: URL,
        language: String?,
        completion: @escaping (Result<PronunciationScore, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let samples: [Float]
                do {
                    samples = try WhisperEngine.loadSamples(from: recordingURL)
                } catch {
                    throw PracticeError.loadAudioFailed(error.localizedDescription)
                }

                let seconds = Double(samples.count) / AudioFormatConverter.targetSampleRate
                guard seconds >= 0.3 else { throw PracticeError.tooShort }

                let engine = self.ensureEngine(modelURL: modelURL)
                guard engine.isLoaded else {
                    throw PracticeError.transcriptionFailed(engine.lastError ?? "模型加载失败")
                }

                // 静音日志：跟读会反复练同一句，成功路径的转写日志会迅速堆积，
                // 而对排查毫无价值（与实时字幕同理）。真正的结论由下面一行 score 记录。
                engine.isQuiet = true
                let segments = engine.transcribe(samples: samples, language: language)
                let recognized = segments
                    .map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let score = PronunciationScorer.score(reference: reference, recognized: recognized)
                Log.shared.info(
                    .asr,
                    score.logLine + "｜录音 \(String(format: "%.1f", seconds))s"
                )
                completion(.success(score))
            } catch {
                Log.shared.warn(.asr, "跟读评测失败｜\(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    /// 释放引擎（退出跟读界面时调用，避免长期占用几十 MB 的模型内存）。
    func releaseEngine() {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine = nil
            self.loadedModelPath = nil
        }
    }

    private func ensureEngine(modelURL: URL) -> WhisperEngine {
        if let engine, loadedModelPath == modelURL.path { return engine }
        let engine = WhisperEngine(modelPath: modelURL.path)
        engine.load()
        self.engine = engine
        self.loadedModelPath = modelURL.path
        return engine
    }
}

/// 跟读练习的界面状态层（@MainActor）。
@MainActor
final class PronunciationPractice: ObservableObject {

    static let shared = PronunciationPractice()

    enum Stage: Equatable {
        case idle
        case recording
        case evaluating
        case done
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .recording, .evaluating: return true
            default: return false
            }
        }
    }

    /// 最长跟读时长（秒）—— 到点自动停止并评测。
    ///
    /// **必须设上限**：用户点下录音后放着不管（或锁屏忘了），录音会一直持续，
    /// 而 whisper 的耗时随音频长度线性增长 —— 一次误操作就能卡住整个评测。
    static let maximumSeconds: Double = 30

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var score: PronunciationScore?
    @Published private(set) var referenceText = ""
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var inputLevel: Float = 0

    private let worker = PronunciationWorker()
    private var timer: Timer?

    private init() {}

    var elapsedText: String {
        String(format: "%.1f s", elapsedSeconds)
    }

    var isRecording: Bool { stage == .recording }

    /// 使用的模型（用于界面展示，让用户知道"是哪把尺子在量"）
    var modelDisplayName: String {
        let modelId = AppSettings.shared.realtimeModelId
        return WhisperModelCatalog.model(id: modelId)?.displayName ?? modelId
    }

    // MARK: - 流程

    func prepare(reference: String) {
        referenceText = reference
        reset()
    }

    func reset() {
        stopTimer()
        score = nil
        elapsedSeconds = 0
        inputLevel = 0
        stage = .idle
    }

    /// 离开界面时调用：停录音、停定时器、丢掉模型。
    func cancel() {
        stopTimer()
        _ = PracticeRecorder.shared.stop()
        score = nil
        elapsedSeconds = 0
        inputLevel = 0
        stage = .idle
        worker.releaseEngine()
    }

    func startRecording() {
        guard !stage.isBusy else { return }

        // 前置检查：模型没下载就明确告知，而不是让用户录完才失败 ——
        // "读完一整句才被告知要去下载模型"是最典型的挫败式交互
        guard installedRealtimeModelURL() != nil else {
            stage = .failed(PracticeError.modelNotInstalled(modelDisplayName).localizedDescription)
            return
        }

        score = nil
        elapsedSeconds = 0
        inputLevel = 0

        do {
            _ = try PracticeRecorder.shared.start(mode: AppSettings.shared.sessionMode)
            stage = .recording
            startTimer()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func stopAndEvaluate() {
        guard stage == .recording else { return }
        stopTimer()

        guard let recordingURL = PracticeRecorder.shared.stop() else {
            stage = .failed(PracticeError.noRecording.localizedDescription)
            return
        }

        guard let modelURL = installedRealtimeModelURL() else {
            try? FileManager.default.removeItem(at: recordingURL)
            stage = .failed(PracticeError.modelNotInstalled(modelDisplayName).localizedDescription)
            return
        }

        stage = .evaluating
        let language = AppSettings.shared.transcriptionLanguage
        worker.evaluate(
            recordingURL: recordingURL,
            reference: referenceText,
            modelURL: modelURL,
            language: language == "auto" ? nil : language
        ) { [weak self] result in
            // 回调来自 worker 队列：必须用 `Task { @MainActor in }` 回到主 actor，
            // 不能用 DispatchQueue.main.async（后者不被识别为主 actor 上下文）
            Task { @MainActor in
                self?.finish(result, recordingURL: recordingURL)
            }
        }
    }

    private func finish(_ result: Result<PronunciationScore, Error>, recordingURL: URL) {
        // 评测算完就删掉录音：跟读录音没有任何留存价值，
        // 留着只会让临时目录里堆满无法辨认的碎片
        try? FileManager.default.removeItem(at: recordingURL)

        switch result {
        case .success(let score):
            self.score = score
            stage = .done
        case .failure(let error):
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - 辅助

    private func installedRealtimeModelURL() -> URL? {
        ModelManager.shared.installedURL(for: AppSettings.shared.realtimeModelId)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Timer 回调虽在主 run loop 上，但闭包未被标注为主 actor 隔离，
            // 因此仍要走 `Task { @MainActor in }`（与 URLSession 回调同理）
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard stage == .recording else { return }
        if let startedAt = PracticeRecorder.shared.startedAt {
            elapsedSeconds = Date().timeIntervalSince(startedAt)
        }
        inputLevel = PracticeRecorder.shared.currentLevel()

        if elapsedSeconds >= Self.maximumSeconds {
            Log.shared.info(.asr, "跟读录音达到上限 \(Int(Self.maximumSeconds))s，自动停止并评测")
            stopAndEvaluate()
        }
    }
}
