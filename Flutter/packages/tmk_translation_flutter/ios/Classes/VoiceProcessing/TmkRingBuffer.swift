//
//  TmkRingBuffer.swift
//  TmkTranslationSDKDemo
//
//  简单环形缓冲区（Int16）
//  用于保存播放队列中的 PCM 数据，支持写入覆盖、读取消费
//

import Foundation

final class TmkRingBuffer {
    // 最大容量（样本数）
    private let capacity: Int
    // 实际存储区
    private var buffer: UnsafeMutablePointer<Int16>
    // 写指针
    private var writeIndex: Int = 0
    // 读指针
    private var readIndex: Int = 0
    // 当前缓存数量
    private var count: Int = 0
    // 线程锁
    private let lock = NSLock()

    // capacity: 以“样本数”为单位（非字节）
    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.buffer = UnsafeMutablePointer<Int16>.allocate(capacity: self.capacity)
        self.buffer.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    // 清空缓冲
    func reset() {
        lock.lock()
        writeIndex = 0
        readIndex = 0
        count = 0
        lock.unlock()
    }

    // 写入样本（超出容量时丢弃新数据，保证已入队的旧音频先播放）
    func write(_ input: UnsafePointer<Int16>, count inputCount: Int) {
        guard inputCount > 0 else { return }
        lock.lock()
        let freeSpace = max(capacity - count, 0)
        let acceptedCount = min(inputCount, freeSpace)
        if acceptedCount <= 0 {
            lock.unlock()
            return
        }
        var remaining = acceptedCount
        var inputOffset = 0
        while remaining > 0 {
            let writableUntilEnd = capacity - writeIndex
            let writeCount = min(remaining, writableUntilEnd)
            buffer.advanced(by: writeIndex).update(from: input.advanced(by: inputOffset), count: writeCount)
            writeIndex = (writeIndex + writeCount) % capacity
            inputOffset += writeCount
            remaining -= writeCount
        }
        count += acceptedCount
        lock.unlock()
    }

    // 读取样本（返回实际读取数量）
    func read(_ output: UnsafeMutablePointer<Int16>, count outputCount: Int) -> Int {
        guard outputCount > 0 else { return 0 }
        lock.lock()
        let toRead = min(outputCount, count)
        if toRead == 0 {
            lock.unlock()
            return 0
        }
        let readableUntilEnd = capacity - readIndex
        let firstReadCount = min(toRead, readableUntilEnd)
        output.update(from: buffer.advanced(by: readIndex), count: firstReadCount)
        let remain = toRead - firstReadCount
        if remain > 0 {
            output.advanced(by: firstReadCount).update(from: buffer, count: remain)
        }
        readIndex = (readIndex + toRead) % capacity
        count -= toRead
        lock.unlock()
        return toRead
    }
}
