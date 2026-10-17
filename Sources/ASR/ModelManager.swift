import Foundation

/// 一次下载的实时进度快照。
///
/// **为什么不是单纯一个 `Double`**：真机验收时用户报"下载半天没反应"，
/// 而设备日志里除"开始下载"那一行之外**什么都没有** —— 因为原实现只在
/// 拿到 Content-Length 时才上报进度，且完全不打日志。于是"慢但在动"与
/// "连接已经死了"在日志与界面上长得一模一样，只能靠猜。
///
/// 因此这里把四件事一起带上：**已收字节**、**服务器是否报了总大小**、
/// **速率**、**距上次收到数据的秒数**。界面能显示，日志能回答。
struct ModelDownloadProgress: Equatable {
    /// 已接收字节
    var receivedBytes: Int64 = 0
    /// 服务器给出的总字节。**<= 0 表示服务器没给 Content-Length**
    ///（分块传输、或中间层改写了响应头）—— 此时无法按比例显示进度，
    /// 但**仍然要显示已接收的字节数**，否则界面就是一片空白。
    var totalBytes: Int64 = 0
    /// 平滑后的速率（字节/秒）
    var bytesPerSecond: Double = 0
    /// 当前数据来源主机（多地址尝试时让用户看出正在试哪个）
    var sourceHost: String = ""
    /// 距上次收到数据的秒数。**不是**"下载已耗时"：
    /// 一个持续有数据的慢下载应当显示为正常，这个值长时间不归零才是"卡住"。
    var idleSeconds: Double = 0

    var isProportional: Bool { totalBytes > 0 }

    /// 可显示的比例。服务器未给总大小时返回 0，界面应改用不确定进度条。
    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(receivedBytes) / Double(totalBytes)))
    }

    var receivedText: String {
        ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
    }

    var totalText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var speedText: String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// 界面与日志共用的一行摘要（两处措辞一致，才不会出现"界面说在下载、
    /// 日志说卡住了"这类互相矛盾）
    var summary: String {
        var parts: [String] = []
        parts.append(isProportional ? "\(receivedText) / \(totalText)" : "已接收 \(receivedText)")
        if !speedText.isEmpty { parts.append(speedText) }
        if !sourceHost.isEmpty { parts.append(sourceHost) }
        if !isProportional { parts.append("服务器未报总大小") }
        return parts.joined(separator: "｜")
    }
}

/// 下载失败原因。
///
/// **刻意把"停滞"单独成一种**：它与"服务器回了错误"是完全不同的两件事 ——
/// 前者应当自动换下一个地址，后者多半要用户查网络。
/// 混成一句"下载失败"，日志就失去了诊断价值（真机验收时正是这种日志缺失，
/// 导致 32 分钟无数据却查不出到底发生了什么）。
enum ModelDownloadError: LocalizedError {
    case stalled(idleSeconds: Double)
    /// 服务器返回了非 2xx。**必须单独成一种**：URLSession 不会把 404/500
    /// 当作错误，若不自己检查，错误页正文会被当成模型文件存下来。
    case badStatus(code: Int, host: String)

    var errorDescription: String? {
        switch self {
        case .stalled(let seconds):
            return "下载停滞：已 \(Int(seconds)) 秒没有收到任何数据"
        case .badStatus(let code, let host):
            return "服务器返回 HTTP \(code)（\(host)）"
        }
    }
}

/// 单个模型的下载状态（界面直接绑定它）。
enum ModelDownloadState: Equatable {
    case notInstalled
    case downloading(ModelDownloadProgress)
    case installed
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isInstalled: Bool { self == .installed }

    var progress: ModelDownloadProgress? {
        if case .downloading(let value) = self { return value }
        return nil
    }
}

/// SenseVoice 模型的下载与安装管理（设计文档 5.5）。
///
/// ## 与 whisper 时代的三点不同（2026-10-17 换引擎）
/// 1. **单模型**：whisper 有四档（tiny/base/small/medium）要分别管理下载/删除/占用；
///    SenseVoice 只有一个，因此 `states` 字典退化为单个 `state`，
///    下载、删除、占用统计全部简化。
/// 2. **校验不再是 ggml 魔数**：ONNX 模型是 protobuf 格式、没有固定魔数，
///    因此删掉 ggml 魔数判断，改用「体积下界 + 加载时验证」——
///    体积下界能识破"错误页/半截文件"，最终正确性由 `SenseVoiceEngine` 加载时验证。
/// 3. **tokens 内置、模型下载**：只下载 `model.int8.onnx` 一个文件，
///    `tokens.txt` 随包内置（见 `SenseVoiceModel.bundledTokensURL`）。
///
/// 仍保留的两个设计决定（与 whisper 时代一致）：
///   · 下载到 `.download` 临时文件、完成后再原子改名 —— 避免半截文件骗过存在性检查；
///   · 主站失败自动回退镜像 —— 交付环境实测 huggingface.co 不可达，必须有第二条路。
@MainActor
final class ModelManager: ObservableObject {

    static let shared = ModelManager()

    /// 模型的当前状态（界面绑定）。
    @Published private(set) var state: ModelDownloadState = .notInstalled

    /// 最近一次操作结果（供界面提示，非错误也展示，例如"已回退镜像并成功"）
    @Published var lastMessage: String?

    private var downloader: ModelDownloader?
    private let fileManager = FileManager.default
    private let settings = AppSettings.shared

    /// 自动准备的说明（目前只用于"因计费网络而跳过"这一种情况）。
    ///
    /// 为什么单独一个字段而不是复用 `lastMessage`：`lastMessage` 是
    /// "最近一次操作的结果"，而这里是"我们**没有**发起操作的原因" ——
    /// 混在一起，就会出现"上一次下载成功了，但这条跳过说明还挂着"。
    @Published private(set) var autoPrepareNote: String?

    private init() {
        refreshInstalled()
    }

    // MARK: - 路径与状态

    /// 模型文件的目标路径（未下载时该文件不存在，但路径仍可计算）。
    var modelURL: URL? {
        (try? AppPaths.modelsDirectory())?.appendingPathComponent(SenseVoiceModel.modelFileName)
    }

    var isInstalled: Bool {
        guard let modelURL else { return false }
        return fileManager.fileExists(atPath: modelURL.path)
    }

    /// 已安装模型的磁盘占用（字节）。未安装返回 0。
    var installedBytes: Int64 {
        guard let modelURL,
              let size = (try? fileManager.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        else { return 0 }
        return size
    }

    /// 重新扫描磁盘，刷新状态。**任何时刻都应能从磁盘还原状态**，
    /// 不依赖内存里的状态机 —— App 被杀后重启，模型仍在。
    func refreshInstalled() {
        if isInstalled {
            state = .installed
        } else if !state.isDownloading {
            state = .notInstalled
        }
        // 清理可能残留的半截下载文件（上次被系统杀掉时留下的）
        cleanupPartialDownloads()
    }

    // MARK: - 首次使用自动准备

    /// 首次使用时静默备好 SenseVoice 模型（约 226 MiB）。
    ///
    /// **只在非计费网络下自动下载**：上百 MB 不该由我们替用户决定花在移动流量上。
    /// 计费网络下不静默下载，但会留下说明、由界面给一次点击的入口。
    /// 重复调用安全：已装或下载进行中都会直接返回（每次启动都会调一次）。
    func autoPrepareIfNeeded() {
        guard settings.autoPrepareModel else { return }
        guard !isInstalled, !state.isDownloading else { return }

        NetworkReach.checkUnmetered { [weak self] unmetered in
            Task { @MainActor in
                guard let self else { return }
                guard unmetered || self.settings.autoPrepareOnCellular else {
                    self.autoPrepareNote = "识别模型「\(SenseVoiceModel.displayName)」"
                        + "（\(SenseVoiceModel.sizeText)）尚未下载。"
                        + "当前是移动网络，未自动下载以免消耗你的流量 —— "
                        + "可直接在下方点「下载」，或在上面打开「允许在移动网络下自动下载」。"
                    Log.shared.info(.model, "自动准备｜跳过｜当前为计费网络，且未允许移动网络自动下载")
                    return
                }

                Log.shared.info(
                    .model,
                    "自动准备｜开始静默下载 \(SenseVoiceModel.displayName)（\(SenseVoiceModel.sizeText)）"
                        + "｜网络 \(unmetered ? "非计费（Wi-Fi/有线）" : "计费（用户已允许）")"
                )
                self.download(preferMirror: self.settings.preferModelMirror)
            }
        }
    }

    // MARK: - 下载

    /// 下载模型。若主站失败会自动尝试镜像。
    /// - Parameter preferMirror: 是否优先走镜像（用户在设置里可选，见 AppSettings）
    func download(preferMirror: Bool = false) {
        guard !state.isDownloading else { return }
        guard let destination = modelURL else {
            state = .failed("模型目录不可用")
            return
        }

        let candidates = preferMirror
            ? [SenseVoiceModel.mirrorURL, SenseVoiceModel.primaryURL]
            : [SenseVoiceModel.primaryURL, SenseVoiceModel.mirrorURL]

        state = .downloading(ModelDownloadProgress())
        Log.shared.info(
            .model,
            "开始下载模型｜\(SenseVoiceModel.displayName)（\(SenseVoiceModel.sizeText)）"
                + "｜首选 \(candidates[0].host ?? "?")"
                + "｜停滞判定 \(Int(ModelDownloader.stallSeconds))s"
        )

        attemptDownload(candidates: candidates, index: 0, destination: destination)
    }

    /// 依次尝试候选地址。用递归而不是循环，是因为每步都要等回调、
    /// 且失败后的提示要带上"已经试过哪个地址"。
    private func attemptDownload(
        candidates: [URL],
        index: Int,
        destination: URL,
        lastFailure: String? = nil
    ) {
        guard index < candidates.count else {
            let reason = lastFailure ?? "未知原因"
            state = .failed("\(candidates.count) 个地址均失败：\(reason)")
            Log.shared.error(
                .model,
                "模型下载失败｜\(SenseVoiceModel.displayName)｜所有地址均不可用｜最后原因：\(reason)"
            )
            return
        }

        let source = candidates[index]
        let downloader = ModelDownloader()

        Log.shared.info(
            .model,
            "尝试下载地址 \(index + 1)/\(candidates.count)｜\(SenseVoiceModel.displayName)｜\(source.host ?? "?")"
        )

        downloader.start(
            from: source,
            to: destination,
            label: SenseVoiceModel.displayName,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.state = .downloading(progress)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloader = nil
                    self.autoPrepareNote = nil

                    switch result {
                    case .success(let url):
                        if let problem = self.validate(at: url) {
                            try? self.fileManager.removeItem(at: url)
                            Log.shared.warn(
                                .model,
                                "模型文件校验未通过｜\(SenseVoiceModel.displayName)｜\(problem)｜尝试下一个地址"
                            )
                            if index + 1 < candidates.count {
                                self.lastMessage = "\(SenseVoiceModel.displayName)：\(problem)，"
                                    + "正在改试 \(candidates[index + 1].host ?? "下一个地址")…"
                            }
                            self.attemptDownload(
                                candidates: candidates,
                                index: index + 1,
                                destination: destination,
                                lastFailure: problem
                            )
                            return
                        }
                        self.state = .installed
                        let via = source.host ?? "未知来源"
                        self.lastMessage = "\(SenseVoiceModel.displayName) 已下载完成（来源 \(via)）"
                        Log.shared.info(
                            .model,
                            "模型下载完成｜\(SenseVoiceModel.displayName)｜来源 \(via)"
                                + "｜\(AppPaths.shortPath(url))"
                        )

                    case .failure(let error):
                        let detail = error.localizedDescription
                        Log.shared.warn(
                            .model,
                            "模型下载失败｜\(SenseVoiceModel.displayName)｜地址 \(source.host ?? "?")"
                                + "｜\(detail)｜尝试下一个地址"
                        )
                        if index + 1 < candidates.count {
                            self.lastMessage = "\(SenseVoiceModel.displayName)：\(detail)，"
                                + "正在改试 \(candidates[index + 1].host ?? "下一个地址")…"
                        }
                        self.attemptDownload(
                            candidates: candidates,
                            index: index + 1,
                            destination: destination,
                            lastFailure: detail
                        )
                    }
                }
            }
        )
        self.downloader = downloader
    }

    func cancelDownload() {
        downloader?.cancel()
        downloader = nil
        state = .notInstalled
        Log.shared.info(.model, "模型下载已取消｜\(SenseVoiceModel.id)")
    }

    // MARK: - 删除

    func delete() throws {
        guard let modelURL else { return }
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        state = .notInstalled
        Log.shared.info(.model, "已删除模型｜\(SenseVoiceModel.displayName)")
    }

    // MARK: - 内部

    /// 校验下载到的文件。返回 nil 表示通过，否则返回一句**可读的原因**。
    ///
    /// ONNX 模型是 protobuf 格式、没有固定魔数，因此这里只做**体积下界**校验：
    /// 错误页正文（几 KB）与半截文件会被识破；最终正确性由 `SenseVoiceEngine` 加载时
    /// 验证（`SherpaOnnxCreateOfflineRecognizer` 返回 NULL 即模型无效）。
    private func validate(at url: URL) -> String? {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return "无法读取文件体积"
        }

        let lower = Int64(Double(SenseVoiceModel.approximateBytes) * 0.75)
        guard size >= lower else {
            return "文件被截断（\(size) 字节，至少应有 \(lower) 字节）"
        }
        return nil
    }

    private func cleanupPartialDownloads() {
        guard let directory = try? AppPaths.modelsDirectory(),
              let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }

        for file in files where file.pathExtension == ModelDownloader.partialExtension {
            try? fileManager.removeItem(at: file)
            Log.shared.warn(.model, "清理未完成的下载残留｜\(file.lastPathComponent)")
        }
    }
}

/// 下载执行器。
///
/// 之所以单独成类：`URLSessionDownloadTask` 的进度回调必须由 delegate 接收，
/// 而 delegate 是 NSObject 子类。把这个必要之恶隔离在一个小类里，
/// 好过让 ModelManager 本身变成 NSObject 并混入 delegate 方法。
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    static let partialExtension = "download"

    /// 多久收不到任何数据就判定卡死。
    ///
    /// 30 秒是权衡后的取值：正常网络下即使很慢也总会有字节在动，
    /// 而真正的"连接被挂住"（SYN 被丢、TLS 之后无响应、被链路静默限速到 0）
    /// 都会在 30 秒内暴露。真机验收时正是这一类在无声地挂着：
    /// 32 分钟里没有一个字节，也没有一条错误。
    static let stallSeconds: Double = 30

    /// 心跳日志间隔。**日志必须能回答"慢但在动"还是"已经死了"** ——
    /// 原先两者在日志上完全一样（都是除了"开始下载"之外什么都没有）。
    private static let heartbeatSeconds: Double = 10
    /// 进度上报节流。URLSession 每收到几 KB 就回调一次，
    /// 每次都写 @Published 会让 SwiftUI 高频重算。
    private static let reportSeconds: Double = 0.25

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var label = ""
    private var sourceHost = ""
    private var onProgress: ((ModelDownloadProgress) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var isFinished = false

    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var smoothedRate: Double = 0
    private var lastDataUptime: Double = 0
    private var lastReportUptime: Double = 0
    private var lastHeartbeatUptime: Double = 0
    private var bytesAtLastReport: Int64 = 0
    private var bytesAtLastHeartbeat: Int64 = 0
    private var watchdogTimer: DispatchSourceTimer?

    func start(
        from source: URL,
        to destination: URL,
        label: String,
        onProgress: @escaping (ModelDownloadProgress) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.destination = destination
        self.label = label
        self.sourceHost = source.host ?? "?"
        self.onProgress = onProgress
        self.onFinish = onFinish

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        // **刻意关掉 waitsForConnectivity**（原先是 true）。
        // 它为 true 时，路径不可用或被阻断会让请求**静默等待**，
        // 且等待期间 request 超时**不生效** —— 最长可等到
        // timeoutIntervalForResource（此处 1 小时）。
        // 取舍：宁可 60 秒内失败并自动切到下一个地址（主站 ↔ 镜像本来就有两条路），
        // 也不要无声地等一小时。
        configuration.waitsForConnectivity = false

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let now = ProcessInfo.processInfo.systemUptime
        lastDataUptime = now
        lastReportUptime = now
        lastHeartbeatUptime = now

        startWatchdog()

        let task = session.downloadTask(with: source)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        finish(with: .failure(TranscriptionError.cancelled))
    }

    // MARK: - 停滞判定与心跳

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        watchdogTimer = timer
        timer.resume()
    }

    private func tick() {
        guard !isFinished else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let idle = now - lastDataUptime

        if idle >= Self.stallSeconds {
            Log.shared.error(
                .model,
                "下载停滞｜\(label)｜来源 \(sourceHost)"
                    + "｜已 \(Int(idle)) 秒无数据｜已接收 \(receivedBytes) 字节"
                    + "｜判定卡死，交由上层切换下一个地址"
            )
            task?.cancel()
            finish(with: .failure(ModelDownloadError.stalled(idleSeconds: idle)))
            return
        }

        guard now - lastHeartbeatUptime >= Self.heartbeatSeconds else { return }
        let interval = now - lastHeartbeatUptime
        let delta = receivedBytes - bytesAtLastHeartbeat
        smoothedRate = interval > 0 ? Double(delta) / interval : 0

        var progress = makeProgress()
        progress.idleSeconds = idle
        Log.shared.info(.model, "下载中｜\(label)｜\(progress.summary)｜已挂起 \(Int(idle))s")
        onProgress?(progress)

        lastHeartbeatUptime = now
        bytesAtLastHeartbeat = receivedBytes
    }

    private func makeProgress() -> ModelDownloadProgress {
        ModelDownloadProgress(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: smoothedRate,
            sourceHost: sourceHost
        )
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        receivedBytes = totalBytesWritten
        // 服务器未给 Content-Length 时这里是 -1。**不能因此就不上报** ——
        // 原实现正是 `guard totalBytesExpectedToWrite > 0 else { return }`，
        // 于是这类下载在界面上永远是一片空白。
        totalBytes = max(0, totalBytesExpectedToWrite)

        lastDataUptime = now

        let interval = now - lastReportUptime
        if interval > 0 {
            let instant = Double(totalBytesWritten - bytesAtLastReport) / interval
            smoothedRate = smoothedRate > 0 ? (smoothedRate * 0.7 + instant * 0.3) : instant
        }

        guard interval >= Self.reportSeconds else { return }
        lastReportUptime = now
        bytesAtLastReport = totalBytesWritten
        onProgress?(makeProgress())
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // **HTTP 状态必须自己检查**：URLSession 不把 404/500 当错误 ——
        // 它会把错误页正文当作"下载成功"存下来。
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(with: .failure(
                ModelDownloadError.badStatus(code: http.statusCode, host: sourceHost)
            ))
            return
        }

        guard let destination else {
            finish(with: .failure(TranscriptionError.modelLoadFailed("缺少目标路径")))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 先落到 .download，体积校验通过后才由调用方改名 —— 避免半截文件被当成完整模型
            let partial = destination.appendingPathExtension(Self.partialExtension)
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            try FileManager.default.moveItem(at: location, to: partial)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            finish(with: .success(destination))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<URL, Error>) {
        guard !isFinished else { return }
        isFinished = true
        watchdogTimer?.cancel()
        watchdogTimer = nil
        onFinish?(result)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }
}
