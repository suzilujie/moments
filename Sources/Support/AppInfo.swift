import Foundation
import UIKit

/// 运行环境信息。
///
/// M0 的自检页与后续所有排错都依赖这些数据。这里刻意「从 Info.plist 读回」
/// 而不是直接引用常量 —— 目的是验证声明真的进入了最终产物，
/// 而不是假设它进去了（设计文档 4.14 节）。
enum AppInfo {

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "-"
    }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "-"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    static var deviceModel: String {
        UIDevice.current.model
    }

    static var systemVersion: String {
        UIDevice.current.systemVersion
    }

    /// 从 Info.plist 读回后台模式声明。
    ///
    /// 这项必须能在设备上直接看到：如果它没生效，症状是「锁屏后录音停掉」，
    /// 而那时再去查 plist 已经太晚了（设计文档 3.2 节）。
    static var backgroundModes: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    }

    static var hasAudioBackgroundMode: Bool {
        backgroundModes.contains("audio")
    }

    static var microphoneUsageDescription: String {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String ?? "（未配置）"
    }
}
