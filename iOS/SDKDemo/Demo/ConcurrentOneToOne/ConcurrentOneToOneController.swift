//
//  ConcurrentOneToOneController.swift
//  TmkTranslationSDKDemo
//
//  Created by XiongJinhui on 2026/8/17.
//

import UIKit
import Combine
import SnapKit

/// ConcurrentOneToOne 的 UIKit 页面，仅负责渲染 ViewModel 状态和转发用户操作。
final class ConcurrentOneToOneController: UIViewController {
    private let viewModel: ConcurrentOneToOneViewModel
    private let leftLanguage: String
    private let rightLanguage: String

    /// 离线侧真实生效的 base code（BCP-47 去区域后缀），用于状态卡展示。
    private var offlineLeftCode: String { leftLanguage.components(separatedBy: "-").first ?? leftLanguage }
    private var offlineRightCode: String { rightLanguage.components(separatedBy: "-").first ?? rightLanguage }
    private var cancellables = Set<AnyCancellable>()
    private let onlineStatusCard = UIView()
    private let offlineStatusCard = UIView()
    private let onlineTitleLabel = UILabel()
    private let onlineLangLabel = UILabel()
    private let onlineStatusLabel = UILabel()
    private let offlineTitleLabel = UILabel()
    private let offlineLangLabel = UILabel()
    private let offlineStatusLabel = UILabel()
    private let onlineRetryButton = UIButton(type: .system)
    private let offlineRetryButton = UIButton(type: .system)
    private let modelButton = UIButton(type: .system)
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let collapseButton = UIButton(type: .system)
    private let controlsStack = UIStackView()
    private let statusStack = UIStackView()
    private let modelTtsStack = UIStackView()
    private let actionStack = UIStackView()
    private let onlineListTitle = UILabel()
    private let offlineListTitle = UILabel()
    private let onlineTableView = UITableView(frame: .zero, style: .plain)
    private let offlineTableView = UITableView(frame: .zero, style: .plain)
    private var onlineRows: [ConcurrentConversationMapper.Row] = []
    private var offlineRows: [ConcurrentConversationMapper.Row] = []
    private var currentState = ConcurrentOneToOneViewState()
    private var controlsExpanded = true
    private let settingsMaskView = UIView()
    private let settingsContainerView = UIView()
    private let settingsPickerView = UIPickerView()
    private var settingsBottomConstraint: Constraint?
    private var settingsPickerKind: SettingsPickerKind?

    private enum SettingsPickerKind {
        case ttsSource
        case playbackMode
    }

    init(initialLeftLanguage: String, initialRightLanguage: String) {
        leftLanguage = initialLeftLanguage
        rightLanguage = initialRightLanguage
        viewModel = ConcurrentOneToOneViewModel(leftLanguage: initialLeftLanguage, rightLanguage: initialRightLanguage)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "一对一对话"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "设置",
                                                            image: nil,
                                                            primaryAction: nil,
                                                            menu: makeSettingsMenu())
        settingsMaskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideSettingsPicker)))
        setupStatusCard(onlineStatusCard, titleLabel: onlineTitleLabel, langLabel: onlineLangLabel, statusLabel: onlineStatusLabel, retry: onlineRetryButton, accent: .systemBlue)
        setupStatusCard(offlineStatusCard, titleLabel: offlineTitleLabel, langLabel: offlineLangLabel, statusLabel: offlineStatusLabel, retry: offlineRetryButton, accent: .systemOrange)
        onlineRetryButton.addTarget(self, action: #selector(retryOnline), for: .touchUpInside)
        offlineRetryButton.addTarget(self, action: #selector(retryOffline), for: .touchUpInside)
        setupButton(modelButton, title: "下载离线模型", action: #selector(downloadModels))
        setupButton(startButton, title: "开始并发翻译", action: #selector(start))
        setupButton(stopButton, title: "停止", action: #selector(stop))
        collapseButton.setTitle("收起控制区", for: .normal)
        collapseButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        collapseButton.contentHorizontalAlignment = .right
        collapseButton.addTarget(self, action: #selector(toggleControls), for: .touchUpInside)
        controlsStack.axis = .vertical
        controlsStack.spacing = 8
        controlsStack.alignment = .fill
        controlsStack.distribution = .fill
        statusStack.axis = .horizontal
        statusStack.spacing = 8
        statusStack.alignment = .fill
        statusStack.distribution = .fillEqually
        modelTtsStack.axis = .horizontal
        modelTtsStack.spacing = 8
        modelTtsStack.alignment = .center
        modelTtsStack.distribution = .fill
        modelTtsStack.addArrangedSubview(modelButton)
        actionStack.axis = .horizontal
        actionStack.spacing = 8
        actionStack.distribution = .fillEqually
        actionStack.addArrangedSubview(startButton)
        actionStack.addArrangedSubview(stopButton)
        setupBubbleList(onlineTableView)
        setupBubbleList(offlineTableView)
        setupListTitle(onlineListTitle, title: "在线气泡", color: .systemBlue)
        setupListTitle(offlineListTitle, title: "离线气泡", color: .systemOrange)
        statusStack.addArrangedSubview(onlineStatusCard)
        statusStack.addArrangedSubview(offlineStatusCard)
        controlsStack.addArrangedSubview(statusStack)
        controlsStack.addArrangedSubview(modelTtsStack)
        controlsStack.addArrangedSubview(actionStack)
        view.addSubview(collapseButton)
        view.addSubview(controlsStack)
        view.addSubview(onlineListTitle); view.addSubview(offlineListTitle)
        view.addSubview(onlineTableView); view.addSubview(offlineTableView)
        installConstraints()
        viewModel.$state.receive(on: DispatchQueue.main).sink { [weak self] in self?.render($0) }.store(in: &cancellables)
        viewModel.prepare()
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed || navigationController?.isBeingDismissed == true { viewModel.release() } }
    private func installConstraints() {
        collapseButton.snp.makeConstraints {
            $0.top.equalTo(view.safeAreaLayoutGuide).offset(6)
            $0.left.right.equalToSuperview().inset(12)
            $0.height.equalTo(28)
        }
        controlsStack.snp.makeConstraints {
            $0.top.equalTo(collapseButton.snp.bottom).offset(4)
            $0.left.right.equalToSuperview().inset(12)
        }
        statusStack.snp.makeConstraints { $0.height.equalTo(96) }
        onlineStatusCard.snp.makeConstraints { $0.height.equalTo(96) }
        onlineTitleLabel.snp.makeConstraints {
            $0.top.equalToSuperview().offset(8)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalTo(onlineRetryButton.snp.left).offset(-8)
        }
        onlineLangLabel.snp.makeConstraints {
            $0.top.equalTo(onlineTitleLabel.snp.bottom).offset(2)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalToSuperview().inset(8)
        }
        onlineStatusLabel.snp.makeConstraints {
            $0.top.equalTo(onlineLangLabel.snp.bottom).offset(2)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalToSuperview().inset(8)
            $0.bottom.lessThanOrEqualToSuperview().inset(8)
        }
        onlineRetryButton.snp.makeConstraints {
            $0.centerY.equalTo(onlineTitleLabel)
            $0.right.equalToSuperview().inset(12)
            $0.width.equalTo(52)
            $0.height.equalTo(30)
        }
        offlineStatusCard.snp.makeConstraints { $0.height.equalTo(96) }
        offlineTitleLabel.snp.makeConstraints {
            $0.top.equalToSuperview().offset(8)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalTo(offlineRetryButton.snp.left).offset(-8)
        }
        offlineLangLabel.snp.makeConstraints {
            $0.top.equalTo(offlineTitleLabel.snp.bottom).offset(2)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalToSuperview().inset(8)
        }
        offlineStatusLabel.snp.makeConstraints {
            $0.top.equalTo(offlineLangLabel.snp.bottom).offset(2)
            $0.left.equalToSuperview().offset(14)
            $0.right.equalToSuperview().inset(8)
            $0.bottom.lessThanOrEqualToSuperview().inset(8)
        }
        offlineRetryButton.snp.makeConstraints {
            $0.centerY.equalTo(offlineTitleLabel)
            $0.right.equalToSuperview().inset(12)
            $0.width.equalTo(52)
            $0.height.equalTo(30)
        }
        modelButton.snp.makeConstraints {
            $0.width.equalTo(132)
            $0.height.equalTo(34)
        }
        actionStack.snp.makeConstraints {
            $0.height.equalTo(42)
        }
        onlineListTitle.snp.makeConstraints {
            $0.top.equalTo(controlsStack.snp.bottom).offset(8)
            $0.left.equalToSuperview().offset(12)
            $0.right.equalTo(view.snp.centerX).offset(-4)
            $0.height.equalTo(24)
        }
        offlineListTitle.snp.makeConstraints {
            $0.top.equalTo(controlsStack.snp.bottom).offset(8)
            $0.left.equalTo(view.snp.centerX).offset(4)
            $0.right.equalToSuperview().inset(12)
            $0.height.equalTo(24)
        }
        onlineTableView.snp.makeConstraints {
            $0.top.equalTo(onlineListTitle.snp.bottom).offset(4)
            $0.left.equalToSuperview().offset(8)
            $0.right.equalTo(view.snp.centerX).offset(-4)
            $0.bottom.equalToSuperview()
        }
        offlineTableView.snp.makeConstraints {
            $0.top.equalTo(offlineListTitle.snp.bottom).offset(4)
            $0.left.equalTo(view.snp.centerX).offset(4)
            $0.right.equalToSuperview().inset(8)
            $0.bottom.equalToSuperview()
        }
    }
    private func setupStatusCard(_ card: UIView, titleLabel: UILabel, langLabel: UILabel, statusLabel: UILabel, retry: UIButton, accent: UIColor) {
        card.backgroundColor = accent.withAlphaComponent(0.10)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1
        card.layer.borderColor = accent.withAlphaComponent(0.22).cgColor
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = accent
        langLabel.font = .systemFont(ofSize: 12, weight: .medium)
        langLabel.textColor = .label
        statusLabel.numberOfLines = 2
        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .label
        card.addSubview(titleLabel)
        card.addSubview(langLabel)
        card.addSubview(statusLabel)
        retry.setTitle("重试", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        retry.tintColor = accent
        retry.backgroundColor = accent.withAlphaComponent(0.14)
        retry.layer.cornerRadius = 8
        card.addSubview(retry)
    }

    private func setupButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        button.layer.cornerRadius = 9
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
    }
    private func setupBubbleList(_ tableView: UITableView) {
        tableView.register(ConcurrentBubbleCell.self, forCellReuseIdentifier: ConcurrentBubbleCell.reuseID)
        tableView.dataSource = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 96
        tableView.separatorStyle = .none
        tableView.backgroundColor = .secondarySystemBackground
        tableView.layer.cornerRadius = 10
    }
    private func setupListTitle(_ label: UILabel, title: String, color: UIColor) {
        label.text = title
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.textColor = color
    }
    private func render(_ state: ConcurrentOneToOneViewState) {
        currentState = state
        onlineTitleLabel.text = "在线"
        offlineTitleLabel.text = "离线"
        onlineLangLabel.text = "\(rightLanguage) ↔ \(leftLanguage)"
        offlineLangLabel.text = "\(offlineRightCode) ↔ \(offlineLeftCode)"
        onlineStatusLabel.text = state.onlineStatus
        let totalProgress = state.modelTotalProgressText.isEmpty ? "" : "\n\(state.modelTotalProgressText)"
        offlineStatusLabel.text = "\(state.offlineStatus) · \(state.modelStatus)\(totalProgress)"
        onlineRetryButton.isHidden = false
        offlineRetryButton.isHidden = false
        onlineRetryButton.isEnabled = state.onlineCanRetry
        offlineRetryButton.isEnabled = state.offlineCanRetry
        onlineRetryButton.alpha = state.onlineCanRetry ? 1 : 0.45
        offlineRetryButton.alpha = state.offlineCanRetry ? 1 : 0.45
        modelButton.isHidden = !state.needsModelDownload
        modelTtsStack.isHidden = !state.needsModelDownload
        modelButton.isEnabled = state.needsModelDownload && !state.isModelDownloading
        modelButton.setTitle(state.isModelDownloading ? "下载中..." : "下载离线模型", for: .normal)
        startButton.isEnabled = state.canStart && !state.isRunning
        stopButton.isEnabled = state.isRunning
        startButton.alpha = startButton.isEnabled ? 1 : 0.45
        stopButton.alpha = stopButton.isEnabled ? 1 : 0.45
        onlineRows = state.rows.filter { $0.runtime == .online }
        offlineRows = state.rows.filter { $0.runtime == .offline }
        onlineTableView.reloadData()
        offlineTableView.reloadData()
        scrollBubbleListsToLatest()
    }
    @objc private func start() { viewModel.start() }
    @objc private func stop() { viewModel.stop() }
    @objc private func retryOnline() { viewModel.retryOnline() }
    @objc private func retryOffline() { viewModel.retryOffline() }
    @objc private func downloadModels() { viewModel.downloadModels() }
    @objc private func toggleControls() {
        controlsExpanded.toggle()
        controlsStack.arrangedSubviews.forEach { $0.isHidden = !controlsExpanded }
        modelButton.isHidden = !controlsExpanded || !currentState.needsModelDownload
        collapseButton.setTitle(controlsExpanded ? "收起控制区" : "展开控制区", for: .normal)
        UIView.performWithoutAnimation { self.view.layoutIfNeeded() }
    }
    private func makeSettingsMenu() -> UIMenu {
        let ttsSourceAction = UIAction(title: "TTS 来源") { [weak self] _ in
            self?.showTtsSourcePicker()
        }
        let playbackAction = UIAction(title: "播放音源") { [weak self] _ in
            self?.showPlaybackModePicker()
        }
        return UIMenu(title: "", children: [ttsSourceAction, playbackAction])
    }

    private func showTtsSourcePicker() {
        showSettingsPicker(.ttsSource)
    }

    private func showPlaybackModePicker() {
        showSettingsPicker(.playbackMode)
    }

    private func showSettingsPicker(_ kind: SettingsPickerKind) {
        guard settingsMaskView.superview == nil else { return }
        settingsPickerKind = kind
        settingsPickerView.dataSource = self
        settingsPickerView.delegate = self
        settingsPickerView.reloadAllComponents()
        settingsPickerView.selectRow(selectedPickerRow(for: kind), inComponent: 0, animated: false)

        settingsMaskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        settingsMaskView.alpha = 0
        view.addSubview(settingsMaskView)
        settingsMaskView.snp.makeConstraints { $0.edges.equalToSuperview() }

        settingsContainerView.backgroundColor = .systemBackground
        settingsContainerView.layer.cornerRadius = 12
        settingsContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        settingsContainerView.clipsToBounds = true
        view.addSubview(settingsContainerView)
        settingsContainerView.snp.makeConstraints {
            $0.left.right.equalToSuperview()
            $0.height.equalTo(280)
            settingsBottomConstraint = $0.bottom.equalToSuperview().offset(280).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(hideSettingsPicker), for: .touchUpInside)
        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmSettingsPicker), for: .touchUpInside)
        let line = UIView()
        line.backgroundColor = .separator

        // 先把子视图加入容器，再安装约束，避免 equalToSuperview 时容器尚未建立层级。
        settingsContainerView.addSubview(cancelButton)
        settingsContainerView.addSubview(confirmButton)
        settingsContainerView.addSubview(line)
        settingsContainerView.addSubview(settingsPickerView)

        cancelButton.snp.makeConstraints {
            $0.left.equalToSuperview().offset(16)
            $0.top.equalToSuperview().offset(8)
            $0.height.equalTo(36)
        }
        confirmButton.snp.makeConstraints {
            $0.right.equalToSuperview().inset(16)
            $0.top.equalTo(cancelButton)
            $0.height.equalTo(cancelButton)
        }
        line.snp.makeConstraints {
            $0.top.equalTo(cancelButton.snp.bottom).offset(8)
            $0.left.right.equalToSuperview()
            $0.height.equalTo(0.5)
        }
        settingsPickerView.snp.makeConstraints {
            $0.top.equalTo(line.snp.bottom)
            $0.left.right.bottom.equalToSuperview()
        }

        view.layoutIfNeeded()
        settingsBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.settingsMaskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func selectedPickerRow(for kind: SettingsPickerKind) -> Int {
        switch kind {
        case .ttsSource:
            return viewModel.currentTtsSourceForSettings() == .online ? 0 : 1
        case .playbackMode:
            return viewModel.currentPlaybackModeForSettings() == .left ? 0 : 1
        }
    }

    @objc private func hideSettingsPicker() {
        guard settingsMaskView.superview != nil else { return }
        settingsBottomConstraint?.update(offset: 280)
        UIView.animate(withDuration: 0.25, animations: {
            self.settingsMaskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.settingsPickerView.delegate = nil
            self.settingsPickerView.dataSource = nil
            self.settingsPickerKind = nil
            self.settingsContainerView.subviews.forEach { $0.removeFromSuperview() }
            self.settingsContainerView.removeFromSuperview()
            self.settingsMaskView.removeFromSuperview()
        })
    }

    @objc private func confirmSettingsPicker() {
        let row = settingsPickerView.selectedRow(inComponent: 0)
        switch settingsPickerKind {
        case .ttsSource where row == 0:
            viewModel.selectTtsSource(.online)
        case .ttsSource where row == 1:
            viewModel.selectTtsSource(.offline)
        case .playbackMode where row == 0:
            viewModel.selectPlaybackMode(.left)
        case .playbackMode where row == 1:
            viewModel.selectPlaybackMode(.right)
        default:
            break
        }
        hideSettingsPicker()
    }
    private func scrollBubbleListsToLatest() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollBubbleListToLatest(self.onlineTableView, rowCount: self.onlineRows.count)
            self.scrollBubbleListToLatest(self.offlineTableView, rowCount: self.offlineRows.count)
        }
    }

    private func scrollBubbleListToLatest(_ tableView: UITableView, rowCount: Int) {
        guard rowCount > 0 else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: rowCount - 1, section: 0), at: .bottom, animated: false)
    }
    @objc private func close() { viewModel.release(); dismiss(animated: true) }

}

extension ConcurrentOneToOneController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableView === onlineTableView ? onlineRows.count : offlineRows.count
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: ConcurrentBubbleCell.reuseID, for: indexPath) as? ConcurrentBubbleCell else {
            return UITableViewCell()
        }
        let rows = tableView === onlineTableView ? onlineRows : offlineRows
        guard rows.indices.contains(indexPath.row) else { return cell }
        cell.configure(rows[indexPath.row])
        return cell
    }
}

extension ConcurrentOneToOneController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        2
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        switch settingsPickerKind {
        case .ttsSource:
            return row == 0 ? "在线" : "离线"
        case .playbackMode:
            return row == 0 ? "左路翻译" : "右路翻译"
        case .none:
            return nil
        }
    }
}

private final class ConcurrentBubbleCell: UITableViewCell {
    static let reuseID = "ConcurrentBubbleCell"
    private let bubbleView = UIView()
    private let text = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        text.numberOfLines = 0
        text.font = .systemFont(ofSize: 8)
        bubbleView.layer.cornerRadius = 12
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(text)
        text.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: ConcurrentConversationMapper.Row) {
        text.text = "ASR：\(row.asr)\nMT：\(row.mt)"
        bubbleView.backgroundColor = row.lane == .left
            ? UIColor.systemBlue.withAlphaComponent(0.18)
            : UIColor.systemPurple.withAlphaComponent(0.18)
        bubbleView.snp.remakeConstraints {
            $0.top.bottom.equalToSuperview().inset(6)
            $0.width.lessThanOrEqualToSuperview().multipliedBy(0.78)
            if row.lane == .left {
                $0.left.equalToSuperview().inset(12)
            } else {
                $0.right.equalToSuperview().inset(12)
            }
        }
    }
}
