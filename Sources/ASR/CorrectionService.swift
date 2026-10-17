import Foundation

/// LLM 纠错服务（形态 A：识别 → 纠正 → 翻译 → 展示纠正文本）。
///
/// ## 职责边界（与识别、翻译基本解耦）
///   · 本类**只负责**「把识别句交给 LLM 纠正、把结果回写进 segment」；
///   · 不碰实时识别链路（`LiveTranscriber` 只提供 `applyCorrection` 回写口）；
///   · 除「纠正完成后对该句单点补翻」外不碰翻译 —— 补翻是形态 A 的必要编排：
///     纠正结果晚于出句，必须显式触发该句翻译，不能只等 suffix(30) 窗口（会漏翻）。
///
/// ## 为什么拆成两个类（@MainActor 外层 + 非隔离 Store）
/// llama 句柄不是线程安全的，必须收敛到单一串行队列上使用（与 `SenseVoiceEngine` /
/// `SherpaVad` 同一约定，见 `LlamaRunner.swift`）。若让 `@MainActor` 的类直接持有
/// 句柄并在后台队列上访问，会触发跨 actor 访问的并发检查。因此把「句柄 + 队列」
/// 隔离到非 actor 的 `LlamaCorrectionStore`，与探针页 `LlamaProbeStore` 同一模式。
@MainActor
final class CorrectionService: ObservableObject {

    static let shared = CorrectionService()

    /// 纠错模型的下载状态（界面绑定，复用 `ModelDownloadState`）。
    @Published private(set) var state: ModelDownloadState = .notInstalled
    /// 最近一次操作结果（供设置页提示，与 `ModelManager.lastMessage` 同理）。
    @Published var lastMessage: String?
    /// 本次会话已回写的纠正句数（日志与界面观察用）。
    @Published private(set) var correctedCount = 0

    private let store = LlamaCorrectionStore()
    private var downloader: ModelDownloader?
    private var submittedIds: Set<String> = []
    private let fileManager = FileManager.default
    private let settings = AppSettings.shared

    private init() {
        refreshInstalled()
    }

    // MARK: - 路径与状态

    var modelURL: URL? {
        (try? AppPaths.modelsDirectory())?.appendingPathComponent(LlamaModel.modelFileName)
    }

    var isInstalled: Bool {
        guard let modelURL else { return false }
        return fileManager.fileExists(atPath: modelURL.path)
    }

    /// 纠错是否生效：开关开 && 模型已下载。翻译层据此决定「等纠正」还是「直翻原文」。
    var isCorrectionActive: Bool { settings.llmCorrectionEnabled && isInstalled }

    /// 已安装模型的磁盘占用（字节）。未安装返回 0。
    var installedBytes: Int64 {
        guard let modelURL,
              let size = (try? fileManager.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value
        else { return 0 }
        return size
    }

    func refreshInstalled() {
        state = isInstalled ? .installed : .notInstalled
    }

    // MARK: - 下载（与 ModelManager 同一套：主站失败回退镜像 + 体积校验）

    func download(preferMirror: Bool = false) {
        guard !state.isDownloading else { return }
        guard let destination = modelURL else {
            state = .failed("模型目录不可用")
            return
        }
        let candidates = preferMirror
            ? [LlamaModel.mirrorURL, LlamaModel.primaryURL]
            : [LlamaModel.primaryURL, LlamaModel.mirrorURL]

        state = .downloading(ModelDownloadProgress())
        Log.shared.info(
            .model,
            "开始下载纠错模型｜\(LlamaModel.displayName)（\(LlamaModel.sizeText)）"
                + "｜首选 \(candidates[0].host ?? "?")"
        )
        attemptDownload(candidates: candidates, index: 0, destination: destination)
    }

    private func attemptDownload(
        candidates: [URL],
        index: Int,
        destination: URL,
        lastFailure: String? = nil
    ) {
        guard index < candidates.count else {
            let reason = lastFailure ?? "未知原因"
            state = .failed("\(candidates.count) 个地址均失败：\(reason)")
            Log.shared.error(.model, "纠错模型下载失败｜所有地址均不可用｜最后原因：\(reason)")
            return
        }

        let source = candidates[index]
        let downloader = ModelDownloader()
        downloader.start(
            from: source,
            to: destination,
            label: LlamaModel.displayName,
            onProgress: { [weak self] progress in
                Task { @MainActor in self?.state = .downloading(progress) }
            },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloader = nil
                    switch result {
                    case .success(let url):
                        if let problem = self.validate(at: url) {
                            try? self.fileManager.removeItem(at: url)
                            Log.shared.warn(.model, "纠错模型校验未通过｜\(problem)｜尝试下一个地址")
                            self.attemptDownload(
                                candidates: candidates,
                                index: index + 1,
                                destination: destination,
                                lastFailure: problem
                            )
                            return
                        }
                        self.state = .installed
                        self.lastMessage = "\(LlamaModel.displayName) 已下载完成"
                        Log.shared.info(.model, "纠错模型下载完成｜\(LlamaModel.displayName)")
                    case .failure(let error):
                        let detail = error.localizedDescription
                        Log.shared.warn(.model, "纠错模型下载失败｜\(detail)｜尝试下一个地址")
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
    }

    func delete() throws {
        guard let modelURL else { return }
        if fileManager.fileExists(atPath: modelURL.path) {
            try fileManager.removeItem(at: modelURL)
        }
        state = .notInstalled
        Log.shared.info(.model, "已删除纠错模型｜\(LlamaModel.displayName)")
    }

    /// 校验下载到的文件（体积下界）。GGUF 无固定魔数，最终正确性由 `LlamaRunner` 加载时验证。
    private func validate(at url: URL) -> String? {
        guard let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return "无法读取文件体积"
        }
        let lower = Int64(Double(LlamaModel.approximateBytes) * 0.75)
        guard size >= lower else {
            return "文件被截断（\(size) 字节，至少应有 \(lower) 字节）"
        }
        return nil
    }

    // MARK: - 纠错入队（录音页每出一句调用一次，传最新字幕即可，内部去重）

    func enqueueLive(_ segments: [TranscriptSegment]) {
        guard isCorrectionActive else { return }
        guard let modelPath = modelURL?.path else { return }
        for segment in segments {
            // 只纠错「定型句」：provisional 句会被反复改写，纠正了也会被下一版推翻。
            // （SenseVoice 时代「成句即定稿」，实时句 isProvisional 恒为 false，此守卫为防御性保留。）
            guard !segment.isProvisional else { continue }
            // 音乐标注段不是真实语音内容。
            guard !segment.isMusicMarker else { continue }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // 去重：同一句只提交一次（录音页每次 onChange 都传整份列表）。
            guard !submittedIds.contains(segment.id) else { continue }
            submittedIds.insert(segment.id)

            // 上下文在主线程算好，跨线程只传值，避免后台队列反查 UI 数据。
            let context = recentContext(before: segment, in: segments)
            store.correct(modelPath: modelPath, sentence: segment.text, context: context) { [weak self] corrected in
                Task { @MainActor in
                    guard let self else { return }
                    // 失败 / 空结果时用原文兜底回写：保证该句仍能被翻译（形态 A 下翻译等 correctedText）。
                    let final = Self.nonEmpty(corrected) ?? segment.text
                    LiveTranscriber.shared.applyCorrection(id: segment.id, correctedText: final)
                    // 单点补翻：不依赖 onChange 的 suffix(30) 窗口，避免慢纠错时该句滑出窗口而漏翻。
                    // enqueueLive 内部按 id 去重，与 onChange 的 suffix(30) 补翻不会重复。
                    var correctedSegment = segment
                    correctedSegment.correctedText = final
                    TranslationService.shared.enqueueLive([correctedSegment])
                    self.correctedCount += 1
                }
            }
        }
    }

    /// 取该句之前最近 3 句作为纠错上下文（优先用已纠正文本，没有则用原文）。
    private func recentContext(before segment: TranscriptSegment, in segments: [TranscriptSegment]) -> [String] {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return [] }
        let start = max(0, index - 3)
        return segments[start..<index].map { $0.correctedText ?? $0.text }
    }

    /// 清空本会话的纠错状态（开始新录音时调，防止跨会话 id 残留导致漏纠错）。
    func reset() {
        submittedIds.removeAll()
        correctedCount = 0
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 非隔离：持有 llama 句柄与后台队列（句柄非线程安全，收敛到单一串行队列）。
///
/// 与探针页 `LlamaProbeStore` 同一模式：把「跨线程访问句柄」的必要之恶隔离在
/// 这个非 actor 的小类里，外层 `CorrectionService`（@MainActor）只做编排与回写。
final class LlamaCorrectionStore {

    private let queue = DispatchQueue(label: "com.xfish.moments.llm-correction", qos: .userInitiated)
    private var runner: LlamaRunner?

    func correct(
        modelPath: String,
        sentence: String,
        context: [String],
        completion: @escaping (String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            var runner = self.runner
            if runner == nil {
                runner = LlamaRunner(modelPath: modelPath)
                self.runner = runner
            }
            guard let runner else {
                completion(nil)
                return
            }
            let outcome = runner.correct(sentence: sentence, context: context)
            completion(outcome?.correctedText)
        }
    }
}
