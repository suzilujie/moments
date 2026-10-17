import Darwin
import Foundation

/// llama.cpp 的最小 Swift 封装（POC 临时）。
///
/// 只服务「LLM 纠错可行性探针」：加载 Qwen GGUF → 用 prompt 跑一次纠错 →
/// 返回纠正句 + 耗时 / token 数 / 常驻内存。**不接实时链路、不做流式**。
///
/// ## 线程约定
/// 持有 C 指针（llama 句柄），**不是线程安全的**。必须在单一线程/队列上使用，
/// 与 `SenseVoiceEngine` / `SherpaVad` / `SherpaDenoiser` 同一约定。
final class LlamaRunner {

    /// 一次纠错的观测结果。
    struct Outcome {
        let correctedText: String
        /// 端到端耗时（毫秒）：含 tokenize + decode + 采样生成。
        let elapsedMs: Int
        let promptTokens: Int
        let generatedTokens: Int
        /// 生成后进程常驻内存（MB），反映「模型 + KV cache」的占用量级。
        let residentMB: Int
    }

    private var handle: UnsafeMutableRawPointer?

    /// 加载 GGUF 模型。失败（文件不存在 / 加载失败）返回 nil。
    init?(modelPath: String) {
        let loaded = modelPath.withCString { ptr -> UnsafeMutableRawPointer? in
            lbr_load(ptr)
        }
        guard let loaded else { return nil }
        handle = loaded
    }

    deinit {
        if let handle {
            lbr_free(handle)
        }
    }

    /// 用「前文上下文 + 当前句」跑一次纠错。
    func correct(sentence: String, context: [String]) -> Outcome? {
        guard let handle else { return nil }
        let prompt = Self.makePrompt(sentence: sentence, context: context)
        let beforeMB = Self.residentMB()

        let result: (String, Int, Int, Int)? = prompt.withCString { pptr in
            var out = [CChar](repeating: 0, count: 4096)
            var genMs: Int32 = 0
            var promptToks: Int32 = 0
            var genToks: Int32 = 0

            let ok: Int32 = out.withUnsafeMutableBufferPointer { obuf in
                lbr_correct(handle, pptr, obuf.baseAddress!, Int32(obuf.count),
                            &genMs, &promptToks, &genToks)
            }
            guard ok != 0 else { return nil }

            let text = String(cString: out)
            return (text, Int(genMs), Int(promptToks), Int(genToks))
        }

        guard let (text, ms, pt, gt) = result else { return nil }
        let afterMB = Self.residentMB()

        return Outcome(
            correctedText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            elapsedMs: ms,
            promptTokens: pt,
            generatedTokens: gt,
            residentMB: max(beforeMB, afterMB)
        )
    }

    // MARK: - Prompt

    private static func makePrompt(sentence: String, context: [String]) -> String {
        let ctx = context.suffix(3).joined(separator: "\n")
        return """
        你是中文语音识别纠错助手。根据上下文，纠正下面句子中的同音字和识别错误。只输出纠正后的句子，不要解释，不要加任何多余内容。
        上下文：
        \(ctx)

        待纠正句子：
        \(sentence)

        纠正后的句子：
        """
    }

    // MARK: - 内存观测

    /// 当前进程常驻内存（MB）。用 `task_info` 的 resident_size，反映真实物理占用。
    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
    }
}
