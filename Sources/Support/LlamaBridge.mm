//
//  LlamaBridge.mm
//  时刻 App —— llama.cpp 薄封装的 Objective-C++ 实现。
//
//  POC 临时层：只做「加载 GGUF → 贪婪采样生成一段」这一件事，够探针测延迟/内存。
//  进业务后若保留 LLM，此层会被更完整的封装取代（流式、KV cache 复用、Metal 后端等）。
//
//  依赖 llama.cpp 的 C API（llama.h），较新版本（llama_init_from_model /
//  llama_sampler 系列）。若 CI 报「no member / undeclared」，说明 clone 到的
//  llama.cpp 版本与这里写的 API 有出入，按报错对齐即可。
//

#include "LlamaBridge.h"
#include "llama.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct LlamaHandle {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
};

/// 把 prompt 编码成 token 序列。
bool tokenizePrompt(const llama_vocab* vocab, const std::string& text,
                    std::vector<llama_token>& tokens) {
    // 第一次调用只取长度（llama_tokenize 返回负数表示「还需要 |n| 个」）。
    int n = llama_tokenize(vocab, text.c_str(), static_cast<int>(text.size()),
                           nullptr, 0, true, true);
    if (n < 0) {
        n = -n;
    }
    if (n <= 0) {
        return false;
    }
    tokens.resize(static_cast<size_t>(n));
    int got = llama_tokenize(vocab, text.c_str(), static_cast<int>(text.size()),
                             tokens.data(), n, true, true);
    return got > 0;
}

}  // namespace

void* lbr_load(const char* model_path) {
    if (model_path == nullptr) {
        return nullptr;
    }

    auto* handle = new (std::nothrow) LlamaHandle();
    if (handle == nullptr) {
        return nullptr;
    }

    llama_model_params mp = llama_model_default_params();
    handle->model = llama_model_load_from_file(model_path, mp);
    if (handle->model == nullptr) {
        delete handle;
        return nullptr;
    }
    handle->vocab = llama_model_get_vocab(handle->model);

    // 纠错 prompt 很短（~100 tokens），512 的 KV cache 足够，也省内存。
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = 512;
    cp.n_batch = 512;
    cp.n_threads = 4;  // iPhone 性能核数左右；纯 CPU 下 4 线程是常见甜点

    handle->ctx = llama_init_from_model(handle->model, cp);
    if (handle->ctx == nullptr) {
        llama_model_free(handle->model);
        delete handle;
        return nullptr;
    }

    return handle;
}

int lbr_correct(void* handle, const char* prompt,
                char* out_buf, int out_size,
                int* gen_ms, int* prompt_toks, int* gen_toks) {
    auto* h = static_cast<LlamaHandle*>(handle);
    if (h == nullptr || h->model == nullptr || h->ctx == nullptr ||
        prompt == nullptr || out_buf == nullptr || out_size <= 0) {
        return 0;
    }

    const auto t0 = std::chrono::steady_clock::now();

    std::vector<llama_token> tokens;
    if (!tokenizePrompt(h->vocab, prompt, tokens)) {
        return 0;
    }
    if (prompt_toks != nullptr) {
        *prompt_toks = static_cast<int>(tokens.size());
    }

    // 解码 prompt。
    llama_batch batch = llama_batch_get_one(tokens.data(),
                                            static_cast<int32_t>(tokens.size()));
    if (llama_decode(h->ctx, batch) != 0) {
        return 0;
    }

    // 贪婪采样生成，直到 EOS 或达到上限。
    llama_token eos = llama_token_eos(h->vocab);
    const int max_new_tokens = 256;

    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sp);
    llama_sampler* greedy = llama_sampler_init_greedy();
    llama_sampler_chain_add(chain, greedy);

    std::string out;
    int generated = 0;
    for (int i = 0; i < max_new_tokens; ++i) {
        llama_token token = llama_sampler_sample(chain, h->ctx, -1);
        llama_sampler_accept(chain, token);
        ++generated;
        if (token == eos) {
            break;
        }

        char piece[512];
        int len = llama_token_to_piece(h->vocab, token, piece,
                                       static_cast<int32_t>(sizeof(piece)), 0, true);
        if (len < 0) {
            break;
        }
        out.append(piece, static_cast<size_t>(len));

        // 单 token 自回归：每个新 token 都要再 decode 一次。
        llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(h->ctx, next) != 0) {
            break;
        }
    }

    llama_sampler_free(chain);

    const auto t1 = std::chrono::steady_clock::now();
    const int elapsed =
        static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count());

    if (gen_toks != nullptr) {
        *gen_toks = generated;
    }
    if (gen_ms != nullptr) {
        *gen_ms = elapsed;
    }

    // 拷出结果（截断到 out_size-1，留 '\0'）。
    std::snprintf(out_buf, static_cast<size_t>(out_size), "%s", out.c_str());
    return 1;
}

void lbr_free(void* handle) {
    auto* h = static_cast<LlamaHandle*>(handle);
    if (h == nullptr) {
        return;
    }
    if (h->ctx != nullptr) {
        llama_free(h->ctx);
    }
    if (h->model != nullptr) {
        llama_model_free(h->model);
    }
    delete h;
}
