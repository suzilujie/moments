import Foundation

/// 单个模型的下载状态（界面直接绑定它）。
enum ModelDownloadState: Equatable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isInstalled: Bool { self == .installed }

    var progressValue: Double {
        if case .downloading(let value) = self { return value }
        return 0
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

        states[modelId] = .downloading(progress: 0)
        Log.shared.info(
            .model,
            "开始下载模型｜\(descriptor.displayName)（\(descriptor.sizeText)）"
                + "｜首选 \(candidates[0].host ?? "?")"
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
        destination: URL
    ) {
        guard index < candidates.count else {
            states[modelId] = .failed("主站与镜像均下载失败，请检查网络后重试")
            Log.shared.error(.model, "模型下载失败｜\(descriptor.displayName)｜所有地址均不可用")
            return
        }

        let source = candidates[index]
        let downloader = ModelDownloader()

        downloader.start(
            from: source,
            to: destination,
            onProgress: { [weak self] progress in
                // 下载进度回调来自 URLSession 的后台队列。
                // 这里必须用 `Task { @MainActor in }` 而不是 DispatchQueue.main.async ——
                // 后者不会被编译器识别为主 actor 上下文，直接改 @Published 状态属隔离违规。
                // 这也是本项目既有代码（RecordingSession / AudioEventObserver）的统一范式。
                Task { @MainActor in
                    // 多地址尝试时进度会归零重来，这里如实反映，不假装连续
                    self?.states[modelId] = .downloading(progress: progress)
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
                        Log.shared.warn(
                            .model,
                            "模型下载失败｜\(descriptor.displayName)｜地址 \(source.host ?? "?")"
                                + "｜\(error.localizedDescription)｜尝试下一个地址"
                        )
                        self.attemptDownload(
                            modelId: modelId,
                            descriptor: descriptor,
                            candidates: candidates,
                            index: index + 1,
                            destination: destination
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

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var onProgress: ((Double) -> Void)?
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var isFinished = false

    func start(
        from source: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void,
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish

        let configuration = URLSessionConfiguration.default
        // 大文件：给足超时，避免慢速网络下被误判失败
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.downloadTask(with: source)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        finish(with: .failure(TranscriptionError.cancelled))
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(min(1.0, max(0.0, progress)))
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
        onFinish?(result)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }
}
