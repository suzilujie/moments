//
//  SherpaBridge.h
//  时刻 App —— 桥接头，把 sherpa-onnx 的 C API 暴露给 Swift。
//
//  为什么需要它：sherpa-onnx 官方只提供「自行构建」这一条路
//  （release 里没有 iOS 预编译产物），CI 里用 CMake 构建出静态库后，
//  Swift 无法直接 import，必须经桥接头引入 C 接口。
//
//  为什么用 __has_include 双分支：本机是 Windows、无法查看产物内部布局，
//  而 C API 头文件可能位于 install/include/sherpa-onnx/c-api/（官方构建脚本的
//  安装路径），也可能被平铺到别处。双分支 + 明确的 #error 可以让第一次编译
//  就给出可读的失败原因，而不是一堆"找不到符号"。
//

#ifndef MOMENTS_SHERPA_BRIDGE_H
#define MOMENTS_SHERPA_BRIDGE_H

#if __has_include(<sherpa-onnx/c-api/c-api.h>)
#include <sherpa-onnx/c-api/c-api.h>
#elif __has_include("c-api.h")
#include "c-api.h"
#else
#error "找不到 sherpa-onnx 的 c-api.h —— 请确认 CI 已构建 third_party/sherpa-onnx 并设置 HEADER_SEARCH_PATHS 指向其 install/include"
#endif

#endif /* MOMENTS_SHERPA_BRIDGE_H */
