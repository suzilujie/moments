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

    var errorDescription: String? {
        switch self {
        case .stalled(let seconds):
            return "下载停滞：已 \(Int(seconds)) 秒没有收到任何数据"
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

/// 模型下载与安装管理（设计文档 5.5）。
///
/// ## 三个刻意的设计决定
/// 1. **下载到 `.download` 临时文件，完成后再原子改名**。
///    否则一个"看起来存在、实际只下了一半"的模型文件会骗过所有存在性检查，
///    最后表现为"加载失败"，而真实原因很难定位。
/// 2. **主站失败自动回退镜像**。本项目交付依赖 GitHub，实测已多次遇到
///    github.com / huggingface.co 不可达（工作日志「阶段十一」）——
///    模型下不下来会直接让转写功能失效，所以必须有第二条路。
/// 3. **不在 App 启动时自动下载**。模型动辄上百 MB，
///    自动下载会消耗用户流量且不可预期；一律由用户显式点击。
@MainActor
final class ModelManager: ObservableObject {

    static let shared = ModelManager()

    /// 各模型的当前状态（界面绑定）
    @Published private(set) var states: [String: ModelDownloadState] = [:]

    /// 最近一次操作结果（供界面提示，非错误也展示，例如"已回退镜像并成功"）
    @Published var lastMessage: String?

    private var downloaders: [String: ModelDownloader] = [:]
    private let fileManager = FileManager.default

    private init() {
        refreshInstalled()
    }

    // MARK: - 路径与状态

    func url(for descriptor: WhisperModelDescriptor) -> URL? {
        (try? AppPaths.modelsDirectory())?.appendingPathComponent(descriptor.fileName)
    }

    /// 已下载模型的文件路径（未下载返回 nil）
    func installedURL(for modelId: String) -> URL? {
        guard let descriptor = WhisperModelCatalog.model(id: modelId),
              let url = url(for: descriptor),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func isInstalled(_ modelId: String) -> Bool {
        installedURL(for: modelId) != nil
    }

    var installedModels: [WhisperModelDescriptor] {
        WhisperModelCatalog.all.filter { isInstalled($0.id) }
    }

    var installedBytes: Int64 {
        installedModels.reduce(0) { partial, descriptor in
            guard let url = url(for: descriptor),
                  let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            else { return partial }
            return partial + size
        }
    }

    /// 重新扫描磁盘，刷新状态。**任何时刻都应能从磁盘还原状态**，
    /// 不依赖内存里的状态机 —— App 被杀后重启，模型仍在。
    func refreshInstalled() {
        for descriptor in WhisperModelCatalog.all {
            if isInstalled(descriptor.id) {
                states[descriptor.id] = .installed
            } else if !(states[descriptor.id]?.isDownloading ?? false) {
                states[descriptor.id] = .notInstalled
            }
        }
        // 清理可能残留的半截下载文件（上次被系统杀掉时留下的）
        cleanupPartialDownloads()
    }

    // MARK: - 下载

    /// 下载模型。若主站失败会自动尝试镜像。
    /// - Parameter preferMirror: 是否优先走镜像（用户在设置里可选，见 AppSettings）
    func download(_ modelId: String, preferMirror: Bool = false) {
        guard let descriptor = WhisperModelCatalog.model(id: modelId) else { return }
        guard !(states[modelId]?.isDownloading ?? false) else { return }
        guard let destination = url(for: descriptor) else {
            states[modelId] = .failed("模型目录不可用")
            return
        }

        let candidates = preferMirror
            ? [descriptor.mirrorURL, descriptor.primaryURL]
            : [descriptor.primaryURL, descriptor.mirrorURL]

        states[modelId] = .downloading(ModelDownloadProgress())
        Log.shared.info(
            .model,
            "开始下载模型｜\(descriptor.displayName)（\(descriptor.sizeText)）"
                + "｜首选 \(candidates[0].host ?? "?")"
                + "｜停滞判定 \(Int(ModelDownloader.stallSeconds))s"
        )

        attemptDownload(
            modelId: modelId,
            descriptor: descriptor,
            candidates: candidates,
            index: 0,
            destination: destination
        )
    }

    /// 依次尝试候选地址。用递归而不是循环，是因为每步都要等回调、
    /// 且失败后的提示要带上"已经试过哪个地址"。
    private func attemptDownload(
        modelId: String,
        descriptor: WhisperModelDescriptor,
        candidates: [URL],
        index: Int,
        destination: URL,
        lastFailure: String? = nil
    ) {
        guard index < candidates.count else {
            // 把最后一个地址的失败原因带进最终提示。只说"下载失败、请检查网络"
            // 会把"服务器无数据返回""域名解析不了""文件被截断"混成一句话，
            // 用户与日志都无法据此判断下一步该做什么。
            let reason = lastFailure ?? "未知原因"
            states[modelId] = .failed("\(candidates.count) 个地址均失败：\(reason)")
            Log.shared.error(
                .model,
                "模型下载失败｜\(descriptor.displayName)｜所有地址均不可用｜最后原因：\(reason)"
            )
            return
        }

        let source = candidates[index]
        let downloader = ModelDownloader()

        // 每次尝试都留一行日志。原先只在**失败时**才记录尝试了哪个地址，
        // 而"第一次尝试就永久挂住"的情况因此完全没有痕迹（真机上的实际死法）。
        Log.shared.info(
            .model,
            "尝试下载地址 \(index + 1)/\(candidates.count)｜\(descriptor.displayName)"
                + "｜\(source.host ?? "?")"
        )

        downloader.start(
            from: source,
            to: destination,
            label: descriptor.displayName,
            onProgress: { [weak self] progress in
                // 下载进度回调来自 URLSession 的后台队列。
                // 这里必须用 `Task { @MainActor in }` 而不是 DispatchQueue.main.async ——
                // 后者不会被编译器识别为主 actor 上下文，直接改 @Published 状态属隔离违规。
                // 这也是本项目既有代码（RecordingSession / AudioEventObserver）的统一范式。
                Task { @MainActor in
                    // 多地址尝试时进度会归零重来，这里如实反映，不假装连续
                    self?.states[modelId] = .downloading(progress)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloaders[modelId] = nil

                    switch result {
                    case .success(let url):
                        guard self.isPlausible(descriptor: descriptor, at: url) else {
                            try? self.fileManager.removeItem(at: url)
                            self.states[modelId] = .failed("下载文件体积异常，已丢弃（可能被网络中间层截断）")
                            Log.shared.error(.model, "模型文件体积异常｜\(descriptor.fileName)")
                            return
                        }
                        self.states[modelId] = .installed
                        let via = index == 0 ? "主站" : "镜像（第 \(index + 1) 个地址）"
                        self.lastMessage = "\(descriptor.displayName) 已下载完成（\(via)）"
                        Log.shared.info(
                            .model,
                            "模型下载完成｜\(descriptor.displayName)｜来源 \(via)"
                                + "｜\(AppPaths.shortPath(url))"
                        )

                    case .failure(let error):
                        let detail = error.localizedDescription
                        Log.shared.warn(
                            .model,
                            "模型下载失败｜\(descriptor.displayName)｜地址 \(source.host ?? "?")"
                                + "｜\(detail)｜尝试下一个地址"
                        )
                        // 把"正在改试另一个地址"显式告诉用户。
                        // 真机上"什么都没发生"正是本次要消灭的症状本身 ——
                        // 界面既无进度也无提示，用户只能干等。
                        if index + 1 < candidates.count {
                            self.lastMessage = "\(descriptor.displayName)：\(detail)，"
                                + "正在改试 \(candidates[index + 1].host ?? "下一个地址")…"
                        }
                        self.attemptDownload(
                            modelId: modelId,
                            descriptor: descriptor,
                            candidates: candidates,
                            index: index + 1,
                            destination: destination,
                            lastFailure: detail
                        )
                    }
                }
            }
        )
        downloaders[modelId] = downloader
    }

    func cancelDownload(_ modelId: String) {
        downloaders[modelId]?.cancel()
        downloaders[modelId] = nil
        states[modelId] = .notInstalled
        Log.shared.info(.model, "模型下载已取消｜\(modelId)")
    }

    // MARK: - 删除

    func delete(_ modelId: String) throws {
        guard let descriptor = WhisperModelCatalog.model(id: modelId),
              let url = url(for: descriptor) else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        states[modelId] = .notInstalled
        Log.shared.info(.model, "已删除模型｜\(descriptor.displayName)")
    }

    // MARK: - 内部

    /// 体积合理性检查。
    ///
    /// 这里**刻意不做哈希校验**：模型几百 MB，哈希要额外读一遍全文件，
    /// 在手机上代价明显；而"体积明显不对"已经能拦住绝大多数失败
    /// （下载被中断、被网络中间层替换成错误页）。
    /// 真正的正确性由加载时验证 —— whisper 初始化失败会给出明确错误。
    private func isPlausible(descriptor: WhisperModelDescriptor, at url: URL) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return false
        }
        // 允许 ±25% 浮动：不同量化版本的实际体积与估算值会有差异
        let lower = Int64(Double(descriptor.approximateBytes) * 0.75)
        return size >= lower
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
        // 大文件：给足超时，避免慢速网络下被误判失败
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        // **刻意关掉 waitsForConnectivity**（原先是 true）。
        //
        // 它为 true 时，路径不可用或被阻断会让请求**静默等待**，
        // 且等待期间 request 超时**不生效** —— 最长可等到
        // timeoutIntervalForResource（此处 1 小时）。
        // 真机上的表现就是"点下载后半天什么都没发生"，日志里亦无一行。
        //
        // 取舍：宁可 60 秒内失败并自动切到下一个地址（主站 ↔ 镜像本来就有两条路），
        // 也不要无声地等一小时。真正"等网络回来"的场景由停滞判定 + 上层重试覆盖。
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

    /// 每 2 秒一次：既写心跳日志，也做停滞判定。
    /// 判死时**不是**只把错误往上抛就完事 —— 上层会据此自动换下一个地址。
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
            // 先 cancel 再 finish：避免 didCompleteWithError 再走一遍收尾
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
        // 于是这类下载在界面上永远是一片空白，用户看到的就是"没反应"。
        totalBytes = max(0, totalBytesExpectedToWrite)

        // 数据刚到，重置停滞判定
        lastDataUptime = now

        // 瞬时速率抖动很大，直接显示会让用户以为网络在抽风 —— 用指数滑动平均
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
        // 这个回调返回后系统会删除临时文件，因此必须**同步**把它搬走。
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
        // error 为 nil 的正常完成已在 didFinishDownloadingTo 中处理
    }

    private func finish(with result: Result<URL, Error>) {
        guard !isFinished else { return }
        isFinished = true
        // 定时器必须停：否则一次下载失败后，每 2 秒仍会有一次 tick 打在
        // 已经结束的任务上（判死分支里的 finish 与自己取消都会回到这里）
        watchdogTimer?.cancel()
        watchdogTimer = nil
        onFinish?(result)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }
}
