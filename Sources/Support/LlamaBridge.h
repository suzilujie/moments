//
//  LlamaBridge.h
//  时刻 App —— llama.cpp 的纯 C 薄封装（供 Swift 桥接头与 LlamaBridge.mm 共用）。
//
//  为什么需要这层封装：llama.cpp 的 `llama.h` 顶部 include 了 C++ 头 `ggml.h`，
//  不能直接塞进 Swift 桥接头（Objective-C/C 编译器会因 C++ 语法而失败）。
//  因此这里只暴露 POC 需要的**最小 C 接口**，实现放在 LlamaBridge.mm（Objective-C++，
//  内部才 #include "llama.h"）。这是「POC 用后即删」的临时层，进业务时再评估
//  是否需要把封装收进正式的、带完整能力的桥接。
//
//  注意 extern "C" 必须用 #ifdef __cplusplus 包裹：C++ 下保证不换名（name mangling），
//  纯 C 下则直接忽略（C 没有 extern "C" 语法）。
//

#ifndef MOMENTS_LLAMA_BRIDGE_H
#define MOMENTS_LLAMA_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 加载 GGUF 模型，返回不透明句柄；失败返回 NULL。
void* lbr_load(const char* model_path);

/// 用 prompt 跑一次生成，把输出（UTF-8、以 '\0' 结尾）写入 out_buf，返回是否成功。
/// gen_ms / prompt_toks / gen_toks 为观测用输出（可传 NULL）：
///   · gen_ms      端到端耗时（毫秒）
///   · prompt_toks prompt 的 token 数
///   · gen_toks    生成的 token 数
int lbr_correct(void* handle, const char* prompt,
                char* out_buf, int out_size,
                int* gen_ms, int* prompt_toks, int* gen_toks);

/// 释放句柄（模型 + 上下文）。
void lbr_free(void* handle);

#ifdef __cplusplus
}
#endif

#endif /* MOMENTS_LLAMA_BRIDGE_H */
