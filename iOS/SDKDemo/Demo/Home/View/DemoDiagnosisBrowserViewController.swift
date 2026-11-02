import UIKit
import Combine
import SnapKit

/// QA 只读目录浏览页，文件系统访问全部委托后台服务。
final class DemoDiagnosisBrowserViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let viewModel: DemoDiagnosisBrowserViewModel
    private var cancellables = Set<AnyCancellable>()
    private var renderedEntries: [DemoDiagnosisFileEntry] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let totalUsageLabel = UILabel()
    private let savedSessionsLabel = UILabel()
    private let rootLabel = UILabel()
    private let pathLabel = UILabel()
    private let statusLabel = UILabel()
    private let indicator = UIActivityIndicatorView(style: .medium)
    private lazy var upButton = UIBarButtonItem(title: "上级", style: .plain, target: self, action: #selector(onUp))
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(viewModel: DemoDiagnosisBrowserViewModel = DemoDiagnosisBrowserViewModel()) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "诊断目录"
        view.backgroundColor = DemoTheme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(onClose))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(onRefresh)), upButton]
        [totalUsageLabel, savedSessionsLabel, rootLabel, pathLabel, statusLabel].forEach {
            $0.font = .systemFont(ofSize: 12)
            $0.numberOfLines = 0
            $0.textColor = DemoTheme.textDim
        }
        totalUsageLabel.textColor = DemoTheme.text
        savedSessionsLabel.textColor = DemoTheme.text
        totalUsageLabel.accessibilityIdentifier = "diagnosis.browser.totalUsage"
        savedSessionsLabel.accessibilityIdentifier = "diagnosis.browser.savedSessions"
        rootLabel.accessibilityIdentifier = "diagnosis.browser.root"
        pathLabel.accessibilityIdentifier = "diagnosis.browser.path"
        statusLabel.accessibilityIdentifier = "diagnosis.browser.status"
        let header = UIStackView(arrangedSubviews: [totalUsageLabel, savedSessionsLabel, rootLabel, pathLabel, statusLabel, indicator])
        header.axis = .vertical
        header.spacing = 8
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = DemoTheme.background
        tableView.separatorColor = DemoTheme.border
        tableView.accessibilityIdentifier = "diagnosis.browser.entries"
        view.addSubview(header)
        view.addSubview(tableView)
        header.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(12)
            $0.left.right.equalToSuperview().inset(16)
        }
        tableView.snp.makeConstraints {
            $0.top.equalTo(header.snp.bottom).offset(12)
            $0.left.right.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        viewModel.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            if let root = state.rootURL {
                let name = state.relativePath.split(separator: "/").last.map(String.init) ?? root.lastPathComponent
                self.title = "当前目录：\(name)"
            } else {
                self.title = "诊断目录"
            }
            let total = state.isLoading ? "统计中…" : state.totalBytes.map(DemoDiagnosisFileEntry.formatBytes) ?? "暂不可用"
            let sessions = state.isLoading ? "统计中…" : state.savedSessionCount.map { "\($0) 次" } ?? "暂不可用"
            self.totalUsageLabel.text = "诊断总占用：\(total)"
            self.savedSessionsLabel.text = "已保存对话：\(sessions)"
            self.rootLabel.text = "当前/最后已应用根目录：\n\(state.rootURL?.path ?? "未初始化")"
            self.pathLabel.text = "当前路径：/\(state.relativePath)"
            self.statusLabel.text = state.message ?? (state.isLoading ? "读取中…" : "只读浏览 · 符号链接不可进入 · 大小为当前元数据快照")
            self.upButton.isEnabled = !state.relativePath.isEmpty
            state.isLoading ? self.indicator.startAnimating() : self.indicator.stopAnimating()
            self.renderedEntries = state.entries
            self.tableView.reloadData()
        }.store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); viewModel.refresh() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); viewModel.cancel() }
    @objc private func onClose() { viewModel.cancel(); dismiss(animated: true) }
    @objc private func onRefresh() { viewModel.refresh() }
    @objc private func onUp() { viewModel.goUp() }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { renderedEntries.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard renderedEntries.indices.contains(indexPath.row) else { return UITableViewCell() }
        let entry = renderedEntries[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "entry")
        cell.backgroundColor = DemoTheme.card
        cell.textLabel?.text = entry.name
        if entry.kind == .directory {
            cell.textLabel?.textColor = UIColor(red: 100 / 255, green: 181 / 255, blue: 246 / 255, alpha: 1)
        } else {
            cell.textLabel?.textColor = DemoTheme.text
        }
        cell.detailTextLabel?.textColor = DemoTheme.textDim
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = "\(entry.kind.rawValue) · \(entry.formattedSize) · \(dateFormatter.string(from: entry.modifiedAt))"
        cell.accessoryType = entry.kind == .directory ? .disclosureIndicator : .none
        cell.selectionStyle = entry.kind == .directory ? .default : .none
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard renderedEntries.indices.contains(indexPath.row) else { return }
        viewModel.enter(renderedEntries[indexPath.row])
    }
}
