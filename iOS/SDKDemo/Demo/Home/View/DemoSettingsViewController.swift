//
//  DemoSettingsViewController.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit
import Combine
import TmkTranslationSDK

final class DemoSettingsViewController: UIViewController {
    private let viewModel: DemoSettingsViewModel
    private var cancellables = Set<AnyCancellable>()

    private let topBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let sectionStackView = UIStackView()
    private let confirmContainer = UIView()
    private let confirmButton = UIButton(type: .system)

    private let diagnosisSwitch = UISwitch()
    private let consoleLogSwitch = UISwitch()
    private let networkButton = UIButton(type: .system)
    private let onlineStatusLabel = UILabel()
    private let onlineStatusHintLabel = UILabel()
    private let offlineStatusLabel = UILabel()
    private let offlineStatusHintLabel = UILabel()
    private let mockSwitch = UISwitch()
    private let tokenStatusLabel = UILabel()
    private let tokenStatusHintLabel = UILabel()
    private let autoRefreshLabel = UILabel()
    private let autoRefreshHintLabel = UILabel()
    private let exportButton = UIButton(type: .system)
    private let versionLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var diagnosisSectionView = UIView()

    init(viewModel: DemoSettingsViewModel = DemoSettingsViewModel()) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindViewModel()
        viewModel.onViewDidLoad()
    }

    private func setupUI() {
        view.backgroundColor = DemoTheme.background

        topBar.backgroundColor = DemoTheme.background

        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(DemoTheme.primaryLight, for: .normal)
        closeButton.addTarget(self, action: #selector(onClose), for: .touchUpInside)

        titleLabel.text = "设置"
        titleLabel.textColor = DemoTheme.text
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false

        confirmContainer.backgroundColor = DemoTheme.background
        confirmContainer.layer.borderColor = DemoTheme.border.cgColor
        confirmContainer.layer.borderWidth = 1 / UIScreen.main.scale

        confirmButton.setTitle("确认", for: .normal)
        confirmButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.backgroundColor = DemoTheme.primary
        confirmButton.layer.cornerRadius = DemoTheme.smallRadius
        confirmButton.addTarget(self, action: #selector(onConfirm), for: .touchUpInside)

        exportButton.setTitle("导出诊断日志", for: .normal)
        exportButton.setTitleColor(DemoTheme.text, for: .normal)
        exportButton.backgroundColor = DemoTheme.card
        exportButton.layer.cornerRadius = 10
        exportButton.layer.borderWidth = 1
        exportButton.layer.borderColor = DemoTheme.border.cgColor
        exportButton.addTarget(self, action: #selector(onExport), for: .touchUpInside)

        networkButton.setTitleColor(DemoTheme.primaryLight, for: .normal)
        networkButton.contentHorizontalAlignment = .right
        networkButton.addTarget(self, action: #selector(onNetworkEnvironment), for: .touchUpInside)

        diagnosisSwitch.onTintColor = DemoTheme.primary
        consoleLogSwitch.onTintColor = DemoTheme.primary
        mockSwitch.onTintColor = DemoTheme.primary
        mockSwitch.isEnabled = false
        mockSwitch.alpha = 0.45

        diagnosisSwitch.addTarget(self, action: #selector(onDiagnosisChanged), for: .valueChanged)
        consoleLogSwitch.addTarget(self, action: #selector(onConsoleLogChanged), for: .valueChanged)

        versionLabel.textColor = DemoTheme.textDim
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textAlignment = .center

        [onlineStatusLabel, offlineStatusLabel, tokenStatusLabel, autoRefreshLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .semibold)
            $0.textAlignment = .right
        }
        [onlineStatusHintLabel, offlineStatusHintLabel, tokenStatusHintLabel, autoRefreshHintLabel].forEach {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = DemoTheme.textDim
            $0.numberOfLines = 2
            $0.textAlignment = .right
        }

        loadingIndicator.hidesWhenStopped = true

        view.addSubview(topBar)
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        view.addSubview(confirmContainer)
        confirmContainer.addSubview(confirmButton)
        confirmContainer.addSubview(loadingIndicator)

        topBar.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
        }
        closeButton.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(16)
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8)
            make.bottom.equalToSuperview().inset(8)
        }
        titleLabel.snp.makeConstraints { make in
            make.centerY.equalTo(closeButton)
            make.centerX.equalToSuperview()
        }
        confirmContainer.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
        }
        confirmButton.snp.makeConstraints { make in
            make.top.equalTo(confirmContainer.snp.top).offset(12)
            make.left.right.equalToSuperview().inset(16)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).inset(12)
            make.height.equalTo(52)
        }
        loadingIndicator.snp.makeConstraints { make in
            make.centerY.equalTo(confirmButton)
            make.right.equalTo(confirmButton.snp.right).inset(16)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.left.right.equalToSuperview()
            make.bottom.equalTo(confirmContainer.snp.top)
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalTo(scrollView)
        }

        let sdkConfigSection = makeSection(title: "SDK 配置", rows: [
            makeToggleRow(title: "诊断模式", hint: "记录详细日志用于排查问题", control: diagnosisSwitch),
            makeToggleRow(title: "控制台日志", hint: "在 Xcode 控制台输出日志", control: consoleLogSwitch),
            makeValueRow(title: "网络环境", hint: "当前 SDK 请求环境", valueView: networkButton)
        ])
        let engineSection = makeSection(title: "引擎状态", rows: [
            makeStatusRow(title: "在线引擎", hint: "LingCast + Agora RTC", statusLabel: onlineStatusLabel, detailLabel: onlineStatusHintLabel),
            makeStatusRow(title: "离线引擎", hint: "离线模型与本地引擎", statusLabel: offlineStatusLabel, detailLabel: offlineStatusHintLabel),
            makeToggleRow(title: "Mock 引擎", hint: "开发测试用，当前仅保留 UI", control: mockSwitch)
        ])
        let authSection = makeSection(title: "鉴权信息", rows: [
            makeStatusRow(title: "Token 状态", hint: "当前鉴权结果", statusLabel: tokenStatusLabel, detailLabel: tokenStatusHintLabel),
            makeStatusRow(title: "自动刷新", hint: "自动续期能力展示占位", statusLabel: autoRefreshLabel, detailLabel: autoRefreshHintLabel)
        ])
        diagnosisSectionView = makeSection(title: "诊断", rows: [makeSingleButtonRow(button: exportButton)])

        sectionStackView.axis = .vertical
        sectionStackView.spacing = 20
        [sdkConfigSection, engineSection, authSection, diagnosisSectionView, versionLabel].forEach {
            sectionStackView.addArrangedSubview($0)
        }
        contentView.addSubview(sectionStackView)

        sectionStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(16)
        }
    }

    private func bindViewModel() {
        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.render(state)
            }
            .store(in: &cancellables)
    }

    private func render(_ state: DemoSettingsViewState) {
        diagnosisSwitch.isOn = state.draftConfig.diagnosisEnabled
        consoleLogSwitch.isOn = state.draftConfig.consoleLogEnabled
        mockSwitch.isOn = state.draftConfig.mockEngineEnabled
        networkButton.setTitle("\(state.draftConfig.networkEnvironment.rawValue.uppercased()) ▾", for: .normal)
        apply(status: state.onlineEngineStatus, to: onlineStatusLabel, detailLabel: onlineStatusHintLabel)
        apply(status: state.offlineEngineStatus, to: offlineStatusLabel, detailLabel: offlineStatusHintLabel)
        tokenStatusLabel.text = state.authInfo.tokenSummary
        tokenStatusHintLabel.text = state.authInfo.tokenDetail
        autoRefreshLabel.text = state.authInfo.autoRefreshSummary
        autoRefreshHintLabel.text = state.authInfo.autoRefreshDetail
        versionLabel.text = state.versionText
        diagnosisSectionView.isHidden = state.draftConfig.diagnosisEnabled == false
        confirmButton.isEnabled = state.isConfirmEnabled
        confirmButton.alpha = state.isConfirmEnabled ? 1 : 0.5
        state.isApplying ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        tokenStatusLabel.textColor = state.authInfo.tokenSummary == "有效" ? DemoTheme.success : DemoTheme.text
        autoRefreshLabel.textColor = state.authInfo.autoRefreshSummary == "暂无数据" ? .white : DemoTheme.text
    }

    private func apply(status: DemoSettingsEngineStatus, to label: UILabel, detailLabel: UILabel) {
        label.text = status.summary
        detailLabel.text = status.detail
        switch status.kind {
        case .checking:
            label.textColor = DemoTheme.warning
        case .available:
            label.textColor = DemoTheme.success
        case .unavailable:
            label.textColor = DemoTheme.danger
        case .placeholder:
            label.textColor = DemoTheme.textDim
        }
    }

    @objc private func onClose() {
        dismiss(animated: true)
    }

    @objc private func onDiagnosisChanged() {
        viewModel.setDiagnosisEnabled(diagnosisSwitch.isOn)
    }

    @objc private func onConsoleLogChanged() {
        viewModel.setConsoleLogEnabled(consoleLogSwitch.isOn)
    }

    @objc private func onNetworkEnvironment() {
        let alert = UIAlertController(title: "网络环境", message: nil, preferredStyle: .actionSheet)
        [.dev, .test, .uat, .pre, .pre_jp, .pre_us].forEach { environment in
            alert.addAction(UIAlertAction(title: environment.rawValue.uppercased(), style: .default) { [weak self] _ in
                self?.viewModel.setNetworkEnvironment(environment)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = networkButton
            popover.sourceRect = networkButton.bounds
        }
        present(alert, animated: true)
    }

    @objc private func onConfirm() {
        viewModel.applyChanges { [weak self] in
            let alert = UIAlertController(title: "设置已生效",
                                          message: "新的 SDK 配置已保存并重新应用。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            self?.present(alert, animated: true)
        }
    }

    @objc private func onExport() {
        guard let diagnosisURL = TmkTranslationSDK.shared.getDiagnosisDirectoryURL() else {
            let alert = UIAlertController(title: "暂无数据",
                                          message: "当前没有可导出的诊断日志。",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        presentShareActivityForDirectoryURL(diagnosisURL, sourceView: exportButton)
    }

    private func makeSection(title: String, rows: [UIView]) -> UIView {
        let container = UIView()
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = DemoTheme.textDim
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 0

        let card = UIView()
        card.backgroundColor = DemoTheme.card
        card.layer.cornerRadius = DemoTheme.radius
        card.layer.borderWidth = 1
        card.layer.borderColor = DemoTheme.border.cgColor
        card.addSubview(stack)

        container.addSubview(titleLabel)
        container.addSubview(card)
        titleLabel.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
        }
        card.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.left.right.bottom.equalToSuperview()
        }
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        return container
    }

    private func makeToggleRow(title: String, hint: String, control: UIView) -> UIView {
        let row = UIView()
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.textColor = DemoTheme.text
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let hintLabel = UILabel()
        hintLabel.text = hint
        hintLabel.textColor = DemoTheme.textDim
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
        stack.axis = .vertical
        stack.spacing = 4
        let separator = UIView()
        separator.backgroundColor = DemoTheme.border
        row.addSubview(stack)
        row.addSubview(control)
        row.addSubview(separator)
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.left.equalToSuperview().offset(14)
            make.bottom.equalToSuperview().inset(16)
            make.right.lessThanOrEqualTo(control.snp.left).offset(-12)
        }
        control.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.right.equalToSuperview().inset(14)
        }
        separator.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
        row.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(76)
        }
        return row
    }

    private func makeValueRow(title: String, hint: String, valueView: UIView) -> UIView {
        makeToggleRow(title: title, hint: hint, control: valueView)
    }

    private func makeStatusRow(title: String, hint: String, statusLabel: UILabel, detailLabel: UILabel) -> UIView {
        let row = UIView()
        let leftTitle = UILabel()
        leftTitle.text = title
        leftTitle.textColor = DemoTheme.text
        leftTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let leftHint = UILabel()
        leftHint.text = hint
        leftHint.textColor = DemoTheme.textDim
        leftHint.font = .systemFont(ofSize: 11)
        leftHint.numberOfLines = 2
        let leftStack = UIStackView(arrangedSubviews: [leftTitle, leftHint])
        leftStack.axis = .vertical
        leftStack.spacing = 4
        let rightStack = UIStackView(arrangedSubviews: [statusLabel, detailLabel])
        rightStack.axis = .vertical
        rightStack.spacing = 4
        rightStack.alignment = .trailing
        row.addSubview(leftStack)
        row.addSubview(rightStack)
        let separator = UIView()
        separator.backgroundColor = DemoTheme.border
        row.addSubview(separator)
        leftStack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.left.equalToSuperview().offset(14)
            make.bottom.equalToSuperview().inset(16)
            make.right.lessThanOrEqualTo(rightStack.snp.left).offset(-12)
        }
        rightStack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(16)
            make.bottom.equalToSuperview().inset(16)
            make.right.equalToSuperview().inset(14)
            make.width.lessThanOrEqualTo(180)
        }
        separator.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
        row.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(76)
        }
        return row
    }

    private func makeSingleButtonRow(button: UIButton) -> UIView {
        let row = UIView()
        row.addSubview(button)
        button.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalTo(60)
        }
        row.snp.makeConstraints { make in
            make.height.equalTo(60)
        }
        return row
    }
}
