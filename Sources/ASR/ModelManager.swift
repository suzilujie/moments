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

/// 模型下载与安装管理（设计文档 5.5）。
///
/// ## 三个刻意的设计决定
/// 1. **下载到 `.download` 临时文件，完成后再原子改名**。
///    否则一个"看起来存在、实际只下了一半"的模型文件会骗过所有存在性检查，
///    最后表现为"加载失败"，而真实原因很难定位。
/// 2. **主站失败自动回退镜像**。本项目交付依赖 GitHub，实测已多次遇到
///    github.com / huggingface.co 不可达（工作日志「阶段十一」）——
///    模型下不下来会直接让转写功能失效，所以必须有第二条路。
/// 3. **首次使用时自动准备默认实时模型**（2026-09-24 改，此前是"一律由用户显式点击"）。
///    原决定的理由是"上百 MB 不该替用户决定消耗流量"。真机验收推翻了这个前提：
///    用户面对 Tiny/Base/Small/Medium 四个名字**根本不知道该下哪个** ——
///    结果不是"省了流量"，而是**核心功能一直不可用**（设备日志里 32 分钟零字节）。
///    现改为：自动下载默认实时模型（Base），但**仅在非计费网络下**；
///    移动网络下不静默下载，只留说明与一次点击的入口。其余模型仍由用户自选。
@MainActor
final class ModelManager: ObservableObject {

    static let shared = ModelManager()

    /// 各模型的当前状态（界面绑定）
    @Published private(set) var states: [String: ModelDownloadState] = [:]

    /// 最近一次操作结果（供界面提示，非错误也展示，例如"已回退镜像并成功"）
    @Published var lastMessage: String?

    private var downloaders: [String: ModelDownloader] = [:]
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

    // MARK: - 首次使用自动准备

    /// 首次使用时静默备好默认实时模型（Base）。
    ///
    /// **只在非计费网络下自动下载**：57 MB 不该由我们替用户决定花在移动流量上。
    /// 计费网络下不静默下载，但会留下说明、由界面给一次点击的入口 ——
    /// 这与"什么都不做、还让用户自己去猜该下哪个"是两回事。
    ///
    /// 重复调用安全：已装或有下载在进行中都会直接返回（每次启动都会调一次）。
    func autoPrepareIfNeeded() {
        guard settings.autoPrepareModel else { return }

        let modelId = WhisperModelCatalog.realtimeDefaultId
        guard let descriptor = WhisperModelCatalog.model(id: modelId) else { return }
        guard !isInstalled(modelId), !(states[modelId]?.isDownloading ?? false) else { return }

        NetworkReach.checkUnmetered { [weak self] unmetered in
            guard let self else { return }
            guard unmetered || self.settings.autoPrepareOnCellular else {
                self.autoPrepareNote = "默认模型「\(descriptor.displayName)」"
                    + "（\(descriptor.sizeText)）尚未下载。"
                    + "当前是移动网络，未自动下载以免消耗你的流量 —— "
                    + "可直接在下方点「下载」，或在上面打开「允许在移动网络下自动下载」。"
                Log.shared.info(
                    .model,
                    "自动准备｜跳过｜当前为计费网络，且未允许移动网络自动下载"
                )
                return
            }

            Log.shared.info(
                .model,
                "自动准备｜开始静默下载 \(descriptor.displayName)"
                    + "（\(descriptor.sizeText)）"
                    + "｜网络 \(unmetered ? "非计费（Wi-Fi/有线）" : "计费（用户已允许）")"
            )
            self.download(modelId, preferMirror: self.settings.preferModelMirror)
        }
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
                    // 有了结果，"为何没自动下载"的说明就该消失
                    //（否则会出现"已经装好了，提示还说没下"）
                    self.autoPrepareNote = nil

                    switch result {
                    case .success(let url):
                        if let problem = self.validate(descriptor: descriptor, at: url) {
                            // 校验不过**不是终点**：它同样意味着"这个地址没给对东西"，
                            // 必须继续尝试下一个地址 —— 否则一个错地址就会让整条回退链断掉。
                            // 真机上正是如此：镜像返回 404，回退链就此中断，
                            // 用户只看到一句与真实原因不相干的"体积异常"。
                            try? self.fileManager.removeItem(at: url)
                            Log.shared.warn(
                                .model,
                                "模型文件校验未通过｜\(descriptor.displayName)"
                                    + "｜\(problem)｜尝试下一个地址"
                            )
                            if index + 1 < candidates.count {
                                self.lastMessage = "\(descriptor.displayName)：\(problem)，"
                                    + "正在改试 \(candidates[index + 1].host ?? "下一个地址")…"
                            }
                            self.attemptDownload(
                                modelId: modelId,
                                descriptor: descriptor,
                                candidates: candidates,
                                index: index + 1,
                                destination: destination,
                                lastFailure: problem
                            )
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

    /// 校验下载到的文件。返回 nil 表示通过，否则返回一句**可读的原因**。
    ///
    /// **两道检查各管一件事，都不能省**：
    /// · **头部魔数**：一次识破"根本不是模型"的东西（错误页、HTML、任意内容）。
    ///   真机上就是被这一步救的 —— 服务器 404 的正文是 15 字节的
    ///   `Entry not found`，只看体积只会觉得"小了点"，看不出"完全不是模型"。
    /// · **体积下界**：识破"头部对但内容被截断"。
    ///
    /// 返回字符串而不是 Bool：失败原因必须能写进日志与界面。
    /// 原先只报一句"体积异常"，把"服务器 404""被截断""格式不对"混成一句，
    /// 排查时被误导了整整一轮。
    ///
    /// 仍然**刻意不做哈希校验**：模型几百 MB，哈希要额外读一遍全文件，
    /// 手机上代价明显；而这两道检查已能覆盖全部已知失败形态，
    /// 最终正确性由加载时验证（whisper 初始化失败会给出明确错误）。
    private func validate(descriptor: WhisperModelDescriptor, at url: URL) -> String? {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return "无法读取文件体积"
        }

        guard let header = readHeader(at: url) else {
            return "无法读取文件头部（\(size) 字节）"
        }
        guard Self.knownMagics.contains(header.value) else {
            return "下载到的不是模型文件（头部 0x\(String(format: "%08X", header.value))"
                + "＝「\(header.ascii)」，共 \(size) 字节）"
        }

        let lower = Int64(Double(descriptor.approximateBytes) * 0.75)
        guard size >= lower else {
            return "文件被截断（\(size) 字节，至少应有 \(lower) 字节）"
        }
        return nil
    }

    /// 已知的模型文件魔数。
    ///
    /// ## ⚠️ 必须按**小端 uint32** 比较，不能拿 ASCII 字符串比（2026-09-24 踩过）
    /// ggml 把魔数写成 uint32，所以文件里的字节是**反的**：
    /// 「ggml」(0x67676D6C) 在磁盘上是 `6C 6D 67 67`，按 ASCII 看是 **lmgg**。
    ///
    /// 第一版实现拿 ASCII 的 `"ggml" / "ggmf" / "ggjt"` 去比，
    /// 结果在一个**完全正常**的 59,707,625 字节模型上误报"不是模型文件"，
    /// 白白花掉一轮构建。教训：**新增的判据必须先在真实文件上核对过** ——
    /// 当时我验证了下载地址是对的，却没有拿真实文件头核对这条新校验。
    ///
    /// 实测证据（ggml-base-q5_1.bin 的前 16 字节）：
    ///   `6C 6D 67 67 99 CA 00 00 DC 05 00 00 00 02 00 00`
    ///   → 魔数 0x67676D6C，其后依次是 n_vocab=51865 / n_audio_ctx=1500 /
    ///     n_audio_state=512，与 whisper base 的实际结构一致。
    private static let knownMagics: Set<UInt32> = [
        0x67676D6C,  // ggml（whisper.cpp 的 .bin 用的就是它；磁盘字节 lmgg）
        0x67676D66,  // ggmf（ggml v2；磁盘字节 fmgg）
        0x67676A74,  // ggjt（ggml v3；磁盘字节 tjgg）
        0x46554747,  // GGUF（新格式；磁盘字节恰好就是 ASCII 的 GGUF）
    ]

    /// 读文件前 4 字节：按小端解释的数值 + 它的 ASCII 呈现。
    ///
    /// 两者一起报是为了排查 —— 数值能对上常量表，ASCII 能让人一眼看出
    /// "这是文本错误页"（例如 `Entry not found` 的头 4 字节是 `Entr`）。
    private func readHeader(at url: URL) -> (value: UInt32, ascii: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }

        let bytes = [UInt8](data)
        // 手写小端拼装，而不用 loadUnaligned：字节序在这里是**语义的一部分**，
        // 显式写出来比依赖平台默认更不容易被改错。
        let value = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let ascii = bytes
            .map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "·" }
            .joined()
        return (value, ascii)
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
        // **HTTP 状态必须自己检查**：URLSession 不把 404/500 当错误 ——
        // 它会把错误页正文当作"下载成功"存下来。真机上正是这样被误导的：
        // 镜像对不存在的文件名返回 404、正文是 15 字节的 `Entry not found`，
        // 结果被当成模型文件存下，最后报成"体积异常（可能被网络中间层截断）"——
        // 提示与真实原因毫不相干，而且换地址的回退链在此中断。
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(with: .failure(
                ModelDownloadError.badStatus(code: http.statusCode, host: sourceHost)
            ))
            return
        }

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
