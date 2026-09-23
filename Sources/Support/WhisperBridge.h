//
//  WhisperBridge.h
//  时刻 App —— 桥接头，把 whisper.cpp 的 C API 暴露给 Swift。
//
//  为什么需要它：whisper.cpp 官方已移除 SwiftPM 支持，CI 里用官方
//  build-xcframework.sh 构建出静态 xcframework。静态库没有 Swift module map，
//  Swift 无法直接 import，必须经桥接头引入 C 接口。
//
//  为什么用 __has_include 双分支而不是写死一种：xcframework 内部布局
//  （framework 风格 <whisper/whisper.h> 还是扁平 "whisper.h"）取决于构建方式，
//  而本机是 Windows、无法预先查看产物。用双分支 + 明确的 #error 提示，
//  可以让第一次编译就给出可读的失败原因，而不是一堆找不到符号。
//

#ifndef MOMENTS_WHISPER_BRIDGE_H
#define MOMENTS_WHISPER_BRIDGE_H

#if __has_include(<whisper/whisper.h>)
#include <whisper/whisper.h>
#elif __has_include("whisper.h")
#include "whisper.h"
#else
#error "找不到 whisper.h —— 请确认 CI 已构建 third_party/whisper.cpp/build-apple/whisper.xcframework 并链接到本 target"
#endif

#endif /* MOMENTS_WHISPER_BRIDGE_H */
