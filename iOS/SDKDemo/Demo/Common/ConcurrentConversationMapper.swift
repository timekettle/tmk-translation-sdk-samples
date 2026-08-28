//
//  ConcurrentConversationMapper.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/17.
//

import Foundation

/// Concurrent 页面只负责把两套一对一气泡快照投影成页面行。
/// 在线和离线各自持有独立的 DemoConversationBubbleAssembler，不建立跨 Runtime 关联。
final class ConcurrentConversationMapper {
    enum Runtime: Hashable { case online, offline }
    enum Kind: Hashable { case asr, mt }
    enum Lane: Hashable { case left, right }

    struct Row: Equatable {
        let id: String
        let bubbleId: String
        let lane: Lane
        let runtime: Runtime
        let asr: String
        let mt: String
    }

    private struct RowKey: Hashable {
        let runtime: Runtime
        let bubbleId: String
        let lane: Lane
    }

    private let onlineAssembler = DemoConversationBubbleAssembler(maxRows: 200)
    private let offlineAssembler = DemoConversationBubbleAssembler(maxRows: 200)
    /// 仅用于合并两个独立列表的展示顺序，不参与结果匹配。
    private var rowOrder: [RowKey: Int] = [:]
    private var nextOrder = 0

    /// 将 SDK 结果事件投递到所属 Runtime 的独立气泡聚合器。
    /// 调用方负责使用在线/离线一对一页面相同的 DemoConversationEventAdapter 生成 event。
    @discardableResult
    func consume(runtime: Runtime, event: DemoConversationEvent) -> [Row] {
        _ = assembler(for: runtime).consume(event)
        return rows()
    }

    func rows() -> [Row] {
        var current: [RowKey: Row] = [:]
        addSnapshots(runtime: .online, snapshots: onlineAssembler.snapshots(), into: &current)
        addSnapshots(runtime: .offline, snapshots: offlineAssembler.snapshots(), into: &current)

        for key in current.keys where rowOrder[key] == nil {
            rowOrder[key] = nextOrder
            nextOrder += 1
        }
        rowOrder = rowOrder.filter { current[$0.key] != nil }
        return rowOrder
            .sorted { $0.value < $1.value }
            .compactMap { current[$0.key] }
    }

    func clear() {
        onlineAssembler.reset()
        offlineAssembler.reset()
        rowOrder.removeAll()
        nextOrder = 0
    }

    private func assembler(for runtime: Runtime) -> DemoConversationBubbleAssembler {
        runtime == .online ? onlineAssembler : offlineAssembler
    }

    private func addSnapshots(runtime: Runtime,
                              snapshots: [DemoConversationBubbleSnapshot],
                              into target: inout [RowKey: Row]) {
        for snapshot in snapshots {
            let lane: Lane = snapshot.lane == .right ? .right : .left
            let key = RowKey(runtime: runtime, bubbleId: snapshot.bubbleId, lane: lane)
            target[key] = Row(id: "\(runtime)-\(snapshot.bubbleId)-\(lane)",
                              bubbleId: snapshot.bubbleId,
                              lane: lane,
                              runtime: runtime,
                              asr: snapshot.sourceText,
                              mt: snapshot.translatedText)
        }
    }
}
