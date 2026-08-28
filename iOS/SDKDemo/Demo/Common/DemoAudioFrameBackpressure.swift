//
//  DemoAudioFrameBackpressure.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/13.
//

import Foundation

/// 为 Demo 音频处理串行队列提供有界的待处理字节额度。
/// 正常负载下所有帧都会进入队列；仅在消费者落后时拒绝新增帧，避免闭包持有 Data 造成内存持续增长。
final class DemoAudioFrameBackpressure {
    struct Reservation {
        fileprivate let generation: UInt64
        fileprivate let bytes: Int
    }

    private let maximumPendingBytes: Int
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingBytes = 0

    init(maxPendingBytes: Int) {
        self.maximumPendingBytes = max(1, maxPendingBytes)
    }

    /// 预留一帧的内存额度；超过上限时返回 nil，由调用方丢弃该帧。
    func reserve(bytes: Int) -> Reservation? {
        guard bytes > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard bytes <= maximumPendingBytes,
              pendingBytes + bytes <= maximumPendingBytes else {
            return nil
        }
        pendingBytes += bytes
        return Reservation(generation: generation, bytes: bytes)
    }

    /// 音频帧处理完成后归还额度；旧会话的 reservation 不得影响新会话。
    func complete(_ reservation: Reservation) {
        lock.lock()
        defer { lock.unlock() }
        guard reservation.generation == generation else { return }
        pendingBytes = max(0, pendingBytes - reservation.bytes)
    }

    /// 仅当前会话持有的 reservation 可以继续处理，避免停止后排队的旧帧穿透到下一次启动。
    func isCurrent(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reservation.generation == generation
    }

    /// 停止或重建会话时让所有旧任务失效，并立即释放其占用额度。
    func invalidate() {
        lock.lock()
        generation &+= 1
        pendingBytes = 0
        lock.unlock()
    }
}
