import SnapKit
import TmkTranslationSDK
import UIKit

final class OfflineModelPackageListView: UIView {
    private let contentView = UIView()
    private let summaryLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var tableHeightConstraint: Constraint?
    private var isExpanded = false
    private var packages: [TmkOfflineModelPackageInfo] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateSummary(_ text: String) {
        _ = text
        refreshSummaryLabel()
    }

    func render(packages: [TmkOfflineModelPackageInfo]) {
        self.packages = packages
        refreshSummaryLabel()
        updateExpandedState()
        updateTableHeight()
        tableView.reloadData()
    }

    func currentSummaryText() -> String {
        summaryLabel.text ?? ""
    }

    func detailButtonTitle() -> String {
        let arrow = isExpanded ? "▴" : "▾"
        return "离线资源详情（\(packages.count)）\(arrow)"
    }

    func toggleExpanded() {
        isExpanded.toggle()
        updateExpandedState()
    }
}

private extension OfflineModelPackageListView {
    func setupUI() {
        summaryLabel.numberOfLines = 0
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.textColor = .label

        tableView.register(
            OfflineModelPackageTableCell.self,
            forCellReuseIdentifier: OfflineModelPackageTableCell.reuseId
        )
        tableView.dataSource = self
        tableView.rowHeight = 44
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.isScrollEnabled = true

        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 10
        contentView.clipsToBounds = true
        contentView.addSubview(summaryLabel)
        contentView.addSubview(tableView)

        let rootStackView = UIStackView(arrangedSubviews: [contentView])
        rootStackView.axis = .vertical
        rootStackView.spacing = 0
        addSubview(rootStackView)
        rootStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        summaryLabel.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview().inset(10)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(summaryLabel.snp.bottom).offset(10)
            make.left.right.equalToSuperview().inset(10)
            make.bottom.equalToSuperview().inset(10)
            tableHeightConstraint = make.height.equalTo(44).constraint
        }

        updateExpandedState()
        updateTableHeight()
    }

    func updateExpandedState() {
        contentView.isHidden = !isExpanded
    }

    func updateTableHeight() {
        let rows = max(packages.count, 1)
        let height = min(CGFloat(rows) * 44, 220)
        tableHeightConstraint?.update(offset: height)
    }

    func refreshSummaryLabel() {
        let totalCount = packages.count
        let finishedCount = packages.filter { $0.state == .ready }.count
        let totalProgress = packages.isEmpty ? 0 : packages
            .map(packageProgress)
            .reduce(0, +) / Float(packages.count)
        let progressText = String(format: "%.1f%%", totalProgress * 100)
        summaryLabel.text = "总进度：\(progressText)（\(finishedCount)/\(totalCount)）"
    }

    func packageProgress(_ package: TmkOfflineModelPackageInfo) -> Float {
        switch package.state {
        case .ready:
            return 1
        case .downloading:
            guard package.totalBytes > 0 else { return 0 }
            let ratio = Double(package.downloadedBytes) / Double(package.totalBytes)
            return Float(min(max(ratio, 0), 1))
        case .unzipping:
            return Float(min(max(package.unzipProgress, 0), 1))
        case .needsDownload, .needsUpdate, .resumable, .failed, .cancelled:
            return 0
        }
    }

}

extension OfflineModelPackageListView: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        packages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: OfflineModelPackageTableCell.reuseId,
            for: indexPath
        ) as? OfflineModelPackageTableCell else {
            return UITableViewCell()
        }
        cell.render(package: packages[indexPath.row])
        return cell
    }
}

private final class OfflineModelPackageTableCell: UITableViewCell {
    static let reuseId = "OfflineModelPackageTableCell"

    private let titleLabel = UILabel()
    private let stateLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(package: TmkOfflineModelPackageInfo) {
        titleLabel.text = package.packageKey
        stateLabel.text = stateText(for: package)
        progressView.setProgress(progressValue(for: package), animated: false)
    }
}

private extension OfflineModelPackageTableCell {
    func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabel
        stateLabel.textAlignment = .right
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        progressView.trackTintColor = .systemGray5
        progressView.setProgress(0, animated: false)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, stateLabel])
        textStack.axis = .horizontal
        textStack.spacing = 8

        let cellStack = UIStackView(arrangedSubviews: [textStack, progressView])
        cellStack.axis = .vertical
        cellStack.spacing = 6

        contentView.addSubview(cellStack)
        cellStack.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        progressView.snp.makeConstraints { make in
            make.height.equalTo(3)
        }
    }

    func stateText(for package: TmkOfflineModelPackageInfo) -> String {
        switch package.state {
        case .ready:
            return "已就绪"
        case .needsDownload:
            return "待下载"
        case .needsUpdate:
            return "需更新"
        case .resumable:
            return "可续传"
        case .downloading:
            let percent = Float(progressValue(for: package) * 100)
            let percentStr = String(format: "%.1f", percent)
            let current = formatBytes(package.downloadedBytes)
            let total = package.totalBytes > 0 ? formatBytes(package.totalBytes) : "未知"
            return "下载中 \(percentStr)%  \(current)/\(total)"
        case .unzipping:
            let percent = Int(min(max(package.unzipProgress, 0), 1) * 100)
            return "解压中 \(percent)%"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    func progressValue(for package: TmkOfflineModelPackageInfo) -> Float {
        switch package.state {
        case .ready:
            return 1
        case .downloading:
            guard package.totalBytes > 0 else { return 0 }
            let ratio = Double(package.downloadedBytes) / Double(package.totalBytes)
            return Float(min(max(ratio, 0), 1))
        case .unzipping:
            return Float(min(max(package.unzipProgress, 0), 1))
        case .needsDownload, .needsUpdate, .resumable, .failed, .cancelled:
            return 0
        }
    }

    func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0.0 MB" }
        return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
    }
}
