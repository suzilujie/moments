import Foundation
import Network

/// 当前网络是否"不计流量"（Wi-Fi / 有线）。
///
/// ## 为什么需要它
/// 首次使用自动下载模型必须区分 Wi-Fi 与移动网络：上百 MB 不该由 App
/// 替用户决定花在移动流量上。**静默下载的边界就止于"可能让用户多付钱"这一条** ——
/// 越过它，静默下载就从"省事"变成"失礼"。
///
/// ## 实现取舍
/// - `NWPathMonitor` 而不是 `SCNetworkReachability`：后者已废弃，
///   且 NWPathMonitor 能直接回答 `usesInterfaceType(.wifi)` 这个我们真正关心的问题
///   （"有没有网"不是重点，"计不计流量"才是）。
/// - **异步回调、不阻塞**：首次路径回调通常几十毫秒，但绝不能假设它一定很快 ——
///   在启动路径上同步等待是拿主线程当赌注。
/// - 取不到结果时**按"计费网络"处理**：宁可少下一会儿，也不要替用户多花钱。
enum NetworkReach {

    /// 回调在主线程。`unmetered` 为 true 表示当前走的是 Wi-Fi / 有线。
    static func checkUnmetered(_ completion: @escaping (Bool) -> Void) {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.xfish.moments.reach")
        var hasDelivered = false

        monitor.pathUpdateHandler = { path in
            // 只认第一次回调：我们要的是"此刻"，不是持续监听
            guard !hasDelivered else { return }
            hasDelivered = true

            let unmetered = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            monitor.cancel()

            DispatchQueue.main.async { completion(unmetered) }
        }
        monitor.start(queue: queue)

        // 兜底：万一首次回调迟迟不来（极少见），按计费网络处理，不让调用方永远等下去
        queue.asyncAfter(deadline: .now() + 3) {
            guard !hasDelivered else { return }
            hasDelivered = true
            monitor.cancel()
            DispatchQueue.main.async { completion(false) }
        }
    }
}
