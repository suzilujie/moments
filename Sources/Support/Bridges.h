//
//  Bridges.h
//  时刻 App —— **唯一的桥接头**。
//
//  为什么需要这个文件：Xcode 的 SWIFT_OBJC_BRIDGING_HEADER 只能指定一个文件。
//  项目现有 SherpaBridge.h（sherpa-onnx，SenseVoice 识别 + VAD + 降噪），
//  收口到这一个文件里 include —— 而不是把第三方库的头直接散落各处。
//
//  注意 include 用的是引号形式：它优先在本文件所在目录查找，
//  因此不需要额外的搜索路径就能找到同目录下的桥接头。
//

#ifndef MOMENTS_BRIDGES_H
#define MOMENTS_BRIDGES_H

#include "SherpaBridge.h"
#include "LlamaBridge.h"

#endif /* MOMENTS_BRIDGES_H */
