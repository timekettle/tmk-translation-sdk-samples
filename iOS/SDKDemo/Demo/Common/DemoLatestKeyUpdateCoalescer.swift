//
//  DemoLatestKeyUpdateCoalescer.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/13.
//

import Foundation

/// 合并一个刷新窗口内的重复 key，仅向 UI 下发每个 key 的最新状态。
/// 调用方负责在同一串行上下文使用；在线一对一固定在主线程调用。
final class DemoLatestKeyUpdateCoalescer<Key: Hashable> {
    typealias Scheduler = (_ interval: TimeInterval, _ action: @escaping () -> Void) -> Void

    private let interval: TimeInterval
    private let scheduler: Scheduler
    private let onFlush: ([Key]) -> Void
    private var pendingKeys: [Key] = []
    private var pendingKeySet = Set<Key>()
    private var generation: UInt64 = 0
    private var scheduledGeneration: UInt64?

    init(interval: TimeInterval,
         scheduler: @escaping Scheduler,
         onFlush: @escaping ([Key]) -> Void) {
        self.interval = max(0, interval)
        self.scheduler = scheduler
        self.onFlush = onFlush
    }

    /// 保留 key 的首次顺序，同一窗口内的重复提交只刷新一次。
    func submit(_ key: Key) {
        if pendingKeySet.insert(key).inserted {
            pendingKeys.append(key)
        }
        guard scheduledGeneration == nil else { return }
        let scheduledGeneration = generation
        self.scheduledGeneration = scheduledGeneration
        scheduler(interval) { [weak self] in
            self?.flushScheduled(generation: scheduledGeneration)
        }
    }

    /// 立即下发指定 key；用于 bubble_end 等必须及时呈现的最终状态。
    func flush(_ key: Key) {
        guard pendingKeySet.remove(key) != nil else { return }
        pendingKeys.removeAll { $0 == key }
        onFlush([key])
    }

    /// 立即下发全部待刷新 key；用于停止收听前保留界面上的最新业务结果。
    func flushAll() {
        guard pendingKeys.isEmpty == false else { return }
        let keys = pendingKeys
        pendingKeys.removeAll(keepingCapacity: true)
        pendingKeySet.removeAll(keepingCapacity: true)
        onFlush(keys)
    }

    /// 会话结束或重建时清空待刷新项，并让已调度的旧任务失效。
    func cancelAll() {
        generation &+= 1
        scheduledGeneration = nil
        pendingKeys.removeAll(keepingCapacity: false)
        pendingKeySet.removeAll(keepingCapacity: false)
    }

    private func flushScheduled(generation scheduledGeneration: UInt64) {
        guard self.scheduledGeneration == scheduledGeneration,
              generation == scheduledGeneration else { return }
        self.scheduledGeneration = nil
        flushAll()
    }
}
