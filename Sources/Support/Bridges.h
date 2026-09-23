//
//  Bridges.h
//  时刻 App —— **唯一的桥接头**。
//
//  为什么需要这个文件：Xcode 的 SWIFT_OBJC_BRIDGING_HEADER 只能指定一个文件。
//  项目已有 WhisperBridge.h（M2），M3 又要引入 SherpaBridge.h，
//  因此收口到这一个文件里 #include 两者 —— 而不是把两个第三方库的头
//  直接混在一起写，那样任一库升级都会牵扯到另一个。
//
//  注意 include 用的是引号形式：它优先在本文件所在目录查找，
//  因此不需要额外的搜索路径就能找到同目录下的两个桥接头。
//

#ifndef MOMENTS_BRIDGES_H
#define MOMENTS_BRIDGES_H

#include "WhisperBridge.h"
#include "SherpaBridge.h"

#endif /* MOMENTS_BRIDGES_H */
