import UIKit

enum ChatListMutation<Row: Equatable> {
    case reset(rows: [Row])
    case insert(row: Row, index: Int)
    case update(row: Row, index: Int, heightMayChange: Bool)
    case delete(index: Int)
}

final class ChatTableDriver<Row: Equatable> {
    private weak var tableView: UITableView?
    private var displayRows: [Row] = []
    private let latestPinnedThreshold: CGFloat = 48
    private(set) var isPinnedToLatest = true

    init(tableView: UITableView) {
        self.tableView = tableView
        tableView.transform = CGAffineTransform(scaleX: 1, y: -1)
    }

    var count: Int { displayRows.count }

    func row(at index: Int) -> Row {
        displayRows[index]
    }

    func reset(rows: [Row]) {
        displayRows = Array(rows.reversed())
        tableView?.reloadData()
        scrollToLatest(animated: false)
    }

    func apply(_ mutation: ChatListMutation<Row>,
               reconfigureVisibleCell: ((UITableViewCell, Row) -> Void)? = nil) {
        guard let tableView else { return }
        let wasPinnedToLatest = isPinnedToLatest

        switch mutation {
        case .reset(let rows):
            reset(rows: rows)
        case .insert(let row, let index):
            let newCount = displayRows.count + 1
            let displayIndex = displayIndexForModelIndex(index, count: newCount)
            displayRows.insert(row, at: displayIndex)
            tableView.performBatchUpdates({
                tableView.insertRows(at: [IndexPath(row: displayIndex, section: 0)], with: .none)
            }, completion: { _ in
                guard wasPinnedToLatest else { return }
                self.scrollToLatest(animated: false)
            })
        case .update(let row, let index, let heightMayChange):
            guard displayRows.isEmpty == false else { return }
            let displayIndex = displayIndexForModelIndex(index, count: displayRows.count)
            guard displayRows.indices.contains(displayIndex) else { return }
            guard displayRows[displayIndex] != row else { return }
            displayRows[displayIndex] = row
            let indexPath = IndexPath(row: displayIndex, section: 0)
            if let cell = tableView.cellForRow(at: indexPath) {
                reconfigureVisibleCell?(cell, row)
                if heightMayChange {
                    UIView.performWithoutAnimation {
                        tableView.beginUpdates()
                        tableView.endUpdates()
                    }
                }
                if wasPinnedToLatest, displayIndex == 0 {
                    scrollToLatest(animated: false)
                }
            } else {
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        case .delete(let index):
            guard displayRows.isEmpty == false else { return }
            let displayIndex = displayIndexForModelIndex(index, count: displayRows.count)
            guard displayRows.indices.contains(displayIndex) else { return }
            displayRows.remove(at: displayIndex)
            tableView.performBatchUpdates({
                tableView.deleteRows(at: [IndexPath(row: displayIndex, section: 0)], with: .none)
            }, completion: { _ in
                guard wasPinnedToLatest else { return }
                self.scrollToLatest(animated: false)
            })
        }
    }

    func handleDidScroll() {
        guard let tableView else { return }
        let distanceToLatest = abs(tableView.contentOffset.y + tableView.adjustedContentInset.top)
        isPinnedToLatest = distanceToLatest <= latestPinnedThreshold
    }

    func scrollToLatest(animated: Bool) {
        guard let tableView, displayRows.isEmpty == false else { return }
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: animated)
    }

    private func displayIndexForModelIndex(_ modelIndex: Int, count: Int) -> Int {
        max(0, min(count - 1 - modelIndex, max(count - 1, 0)))
    }
}
