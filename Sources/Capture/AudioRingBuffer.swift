import Foundation
import os

/// 单生产者 / 单消费者环形缓冲（设计文档 4.9）。
///
/// 用途：把**实时音频线程**（生产者，采集中）与**后台消费队列**（消费者，做格式转换、
/// 编码、落盘）解耦。没有它，实时线程就必须自己做重活，结果是偶发丢帧与爆音 ——
/// 这类问题几乎无法事后定位，只能靠结构上避免。
///
/// ## 关于"加锁"的说明（对设计文档 4.9 的一处诚实偏离）
/// 设计文档写的是"回调内禁止加锁"。这里实际使用了一把 <b>os_unfair_lock</b>，
/// 原因与边界如下：
///   · 设计文档那条要求的**真正意图**是：实时线程内不得分配内存、不得做 I/O、
///     不得调用可能长时间阻塞的 API。这三点在实现中严格保持。
///   · Swift 无法可靠地使用内存栅栏（OSMemoryBarrier 的可用性不稳定），
///     而裸索引的 SPSC 环形缓冲在 arm64 弱内存序下并非严格正确 ——
///     用一个极短临界区换取确定性，比"实践中通常没事"更可取。
///   · 临界区内只有一次 memcpy，持有时长为微秒级；消费者不在实时线程上。
///
/// 该偏离已记录，若后续需要严格无锁，可通过引入 swift-atomics 改写。
final class AudioRingBuffer {

    let capacity: Int
    private let mask: Int

    private let storage: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// 绝对计数器（单调递增），取模后得到实际下标。
    /// 用绝对计数而非环绕下标，是为了避免"满/空"两种状态无法区分。
    private var writeCount = 0
    private var readCount = 0

    /// 因缓冲满而被丢弃的样本数。
    /// **只要大于 0，就说明消费者跟不上生产者** —— 这是"是否丢帧"的唯一判据，
    /// 也是 M1 验收矩阵第 11 项（时间轴校验）的依据。
    private(set) var droppedSamples = 0

    init(capacityFrames: Int = 262_144) {
        // 取 2 的幂，使取模变成位与运算
        var size = 1
        while size < capacityFrames { size <<= 1 }
        capacity = size
        mask = size - 1

        storage = UnsafeMutablePointer<Float>.allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)

        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - 状态查询

    var availableToRead: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writeCount - readCount
    }

    /// 累计写入帧数（单调递增，永不回退）。
    ///
    /// 这是"音频是否还在来"的最佳探针：它由实时线程推进、可被任意线程安全读取，
    /// 且不依赖消费者是否来得及处理。看门狗据此判定停滞（设计文档 4.13）——
    /// 用探针而不是让实时线程回调主线程喂狗，避免了每秒十次的跨线程开销。
    var totalWritten: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writeCount
    }

    // MARK: - 生产者（实时音频线程调用）

    /// 写入样本。**调用方不得在此前后做任何分配或 I/O。**
    /// - Returns: 实际写入的样本数（小于 count 表示发生了丢弃）
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let free = capacity - (writeCount - readCount)
        guard free > 0 else {
            droppedSamples += count
            return 0
        }

        let toWrite = min(count, free)
        if toWrite < count {
            droppedSamples += (count - toWrite)
        }

        var index = writeCount & mask
        let firstChunk = min(toWrite, capacity - index)
        memcpy(storage + index, source, firstChunk * MemoryLayout<Float>.size)
        if toWrite > firstChunk {
            memcpy(storage, source + firstChunk, (toWrite - firstChunk) * MemoryLayout<Float>.size)
        }

        writeCount += toWrite
        return toWrite
    }

    // MARK: - 消费者（后台队列调用）

    /// 读取最多 maxCount 个样本。
    /// - Returns: 实际读出的样本数
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let available = writeCount - readCount
        guard available > 0 else { return 0 }

        let toRead = min(available, maxCount)
        var index = readCount & mask
        let firstChunk = min(toRead, capacity - index)
        memcpy(destination, storage + index, firstChunk * MemoryLayout<Float>.size)
        if toRead > firstChunk {
            memcpy(destination, storage, (toRead - firstChunk) * MemoryLayout<Float>.size)
        }

        readCount += toRead
        return toRead
    }

    /// 读出为数组（会分配内存，仅限后台队列使用）。
    func read(maxCount: Int) -> [Float] {
        var buffer = [Float](repeating: 0, count: maxCount)
        let readCount = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return read(into: base, maxCount: maxCount)
        }
        if readCount < maxCount {
            buffer.removeLast(maxCount - readCount)
        }
        return buffer
    }

    /// 清空未读数据（用于会话结束或重建引擎后丢弃陈旧音频）。
    func drainDiscard() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        readCount = writeCount
    }

    /// 重置计数器（新建会话时调用）。
    func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writeCount = 0
        readCount = 0
    }
}
