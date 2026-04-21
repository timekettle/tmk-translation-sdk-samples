//
//  OfflineListenController.swift
//  TmkTranslationSDKDemo
//
//  Created by Kiro on 2026/1/28.
//

import UIKit
import SnapKit
import Combine
import TmkTranslationSDK

/// 离线现场收听页面。
/// 复用 NowListeningController 的 UI 结构，语言选择使用 SDK 提供的离线支持列表。
final class OfflineListenController: UIViewController {
    private struct LanguageOption {
        let code: String
        let title: String
    }

    private let statusLabel = UILabel()
    private let infoLabel = UILabel()
    private let modelStatusButton = UIButton(type: .system)
    private let modelDetailButton = UIButton(type: .system)
    private let cancelDownloadButton = UIButton(type: .system)
    private let modelPackageListView = OfflineModelPackageListView()
    private let startListeningButton = UIButton(type: .system)
    private let stopListeningButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

    private let viewModel = OfflineListenViewModel()
    private let initialSourceLanguage: String?
    private let initialTargetLanguage: String?
    private var cancellables = Set<AnyCancellable>()
    private var state = NowListeningViewState()
    private lazy var tableDriver = ChatTableDriver<NowListeningRowViewData>(tableView: tableView)
    private var modelButtonState: OfflineModelButtonState = .notDownloaded
    private var supportedLanguageOptions: [LanguageOption] = []

    private let pickerMaskView = UIView()
    private let pickerContainerView = UIView()
    private let languagePickerView = UIPickerView()
    private var pickerBottomConstraint: Constraint?
    private lazy var languageBarButtonItem = UIBarButtonItem(title: "语言",
                                                             style: .plain,
                                                             target: self,
                                                             action: #selector(onTapChangeLanguage))

    init(initialSourceLanguage: String? = nil, initialTargetLanguage: String? = nil) {
        self.initialSourceLanguage = initialSourceLanguage
        self.initialTargetLanguage = initialTargetLanguage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadLocalLanguageOptions()
        bindViewModel()
        viewModel.configureInitialLanguages(source: initialSourceLanguage, target: initialTargetLanguage)
        viewModel.onViewDidLoad()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            viewModel.onViewWillClose()
        }
    }
}

private extension OfflineListenController {
    func setupUI() {
        title = "离线收听"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭",
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(onClose))
        navigationItem.rightBarButtonItem = languageBarButtonItem

        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .label

        infoLabel.numberOfLines = 1
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabel

        setupButton(startListeningButton, title: "开始收听", action: #selector(onTapStartListening))
        setupButton(stopListeningButton, title: "停止收听", action: #selector(onTapStopListening))
        setupButton(modelStatusButton, title: "下载模型", action: #selector(onTapModelStatus))
        setupButton(modelDetailButton, title: modelPackageListView.detailButtonTitle(), action: #selector(onTapModelDetail))
        setupButton(cancelDownloadButton, title: "取消", action: #selector(onTapCancelDownload))
        cancelDownloadButton.isHidden = true

        tableView.register(NowListeningBubbleCell.self, forCellReuseIdentifier: NowListeningBubbleCell.reuseId)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.separatorStyle = .none

        view.addSubview(statusLabel)
        view.addSubview(infoLabel)
        view.addSubview(modelStatusButton)
        view.addSubview(modelDetailButton)
        view.addSubview(cancelDownloadButton)
        view.addSubview(modelPackageListView)
        view.addSubview(startListeningButton)
        view.addSubview(stopListeningButton)
        view.addSubview(tableView)

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8)
            make.left.right.equalToSuperview().inset(12)
        }
        infoLabel.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(4)
            make.left.right.equalToSuperview().inset(16)
        }
        modelStatusButton.snp.makeConstraints { make in
            make.top.equalTo(infoLabel.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(12)
            make.right.lessThanOrEqualTo(modelDetailButton.snp.left).offset(-8)
            make.height.equalTo(32)
        }
        cancelDownloadButton.snp.makeConstraints { make in
            make.top.equalTo(modelStatusButton)
            make.left.equalTo(modelStatusButton.snp.right).offset(8)
            make.right.lessThanOrEqualTo(modelDetailButton.snp.left).offset(-8)
            make.height.equalTo(modelStatusButton)
        }
        modelDetailButton.snp.makeConstraints { make in
            make.top.equalTo(modelStatusButton)
            make.right.equalToSuperview().inset(12)
            make.height.equalTo(modelStatusButton)
        }
        modelPackageListView.snp.makeConstraints { make in
            make.top.equalTo(modelStatusButton.snp.bottom).offset(4)
            make.left.right.equalToSuperview().inset(12)
        }
        startListeningButton.snp.makeConstraints { make in
            make.top.equalTo(modelPackageListView.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(12)
            make.height.equalTo(32)
            make.width.equalTo(stopListeningButton)
        }
        stopListeningButton.snp.makeConstraints { make in
            make.top.equalTo(startListeningButton)
            make.left.equalTo(startListeningButton.snp.right).offset(8)
            make.height.equalTo(startListeningButton)
            make.right.lessThanOrEqualToSuperview().inset(12)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(startListeningButton.snp.bottom).offset(8)
            make.left.right.bottom.equalToSuperview()
        }
    }

    func setupButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// 从 ViewModel 当前语言列表刷新语言选项。
    func loadLocalLanguageOptions() {
        supportedLanguageOptions = viewModel.supportedLanguages.map {
            LanguageOption(code: $0.code, title: $0.name)
        }
    }

    func bindViewModel() {
        viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let oldState = self.state
                self.state = state
                self.render(state)
                if self.shouldRefreshVisibleCells(from: oldState, to: state) {
                    self.refreshVisibleCells()
                }
            }
            .store(in: &cancellables)

        viewModel.rowMutation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mutation in
                guard let self else { return }
                self.tableDriver.apply(mutation) { cell, row in
                    guard let bubbleCell = cell as? NowListeningBubbleCell else { return }
                    self.configureCell(bubbleCell, with: row)
                }
            }
            .store(in: &cancellables)

        viewModel.$downloadButtonState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] buttonState in
                guard let self else { return }
                self.modelButtonState = buttonState
                self.modelStatusButton.setTitle(self.displayButtonTitle(for: buttonState), for: .normal)
                self.modelStatusButton.isEnabled = buttonState.isEnabled
                self.refreshModelDetailButtonTitle()
                self.startListeningButton.isEnabled = (buttonState == .ready) && self.state.canStartListening
            }
            .store(in: &cancellables)

        viewModel.$supportedLanguages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadLocalLanguageOptions()
                self.languagePickerView.reloadAllComponents()
                self.syncLanguagePickerSelection()
                self.render(self.state)
            }
            .store(in: &cancellables)

        viewModel.$downloadStatusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.modelPackageListView.updateSummary(text)
                self?.applyDownloadButtonStatusText(text)
            }
            .store(in: &cancellables)

        viewModel.$showCancelButton
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                self?.cancelDownloadButton.isHidden = !show
            }
            .store(in: &cancellables)

        viewModel.$modelPackageInfos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] packages in
                guard let self else { return }
                self.modelPackageListView.render(packages: packages)
                self.refreshModelDetailButtonTitle()
                self.applyDownloadButtonStatusText(self.modelPackageListView.currentSummaryText())
            }
            .store(in: &cancellables)
    }

    func render(_ state: NowListeningViewState) {
        statusLabel.text = state.statusText
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        let sourceName = localizedLanguageName(for: state.sourceLanguage)
        let targetName = localizedLanguageName(for: state.targetLanguage)
        infoLabel.text = "语言:\(sourceName)→\(targetName)  采集:\(capture)  回放:\(playback)"
        startListeningButton.isEnabled = state.canStartListening && modelButtonState == .ready
        stopListeningButton.isEnabled = state.canStopListening
    }

    func applyDownloadButtonStatusText(_ text: String) {
        if modelButtonState == .downloading {
            let summaryText = modelPackageListView.currentSummaryText()
            let sourceText = summaryText.isEmpty ? text : summaryText
            modelStatusButton.setTitle(displayButtonTitle(for: .downloading, statusText: sourceText), for: .normal)
        }
    }

    func refreshModelDetailButtonTitle() {
        modelDetailButton.setTitle(modelPackageListView.detailButtonTitle(), for: .normal)
    }

    func displayButtonTitle(for state: OfflineModelButtonState, statusText: String? = nil) -> String {
        guard state == .downloading else { return state.buttonTitle }
        guard let statusText else { return state.buttonTitle }
        for prefix in ["总进度：", "下载进度："] {
            guard let range = statusText.range(of: prefix) else { continue }
            let suffix = statusText[range.upperBound...]
            let progress = suffix.split(separator: "（", maxSplits: 1, omittingEmptySubsequences: true).first
                .map { String($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let progress, progress.isEmpty == false {
                return "下载中 \(progress)"
            }
        }
        return state.buttonTitle
    }

    func configureCell(_ cell: NowListeningBubbleCell, with row: NowListeningRowViewData) {
        cell.configure(row: row,
                       roomNo: state.currentRoomNo,
                       scenario: state.currentScenario,
                       mode: state.currentMode,
                       configuredSampleRate: state.configuredSampleRate,
                       configuredChannels: state.configuredChannels,
                       captureSampleRate: state.captureSampleRate,
                       captureChannels: state.captureChannels,
                       playbackChannels: state.playbackChannels)
    }

    func refreshVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? NowListeningBubbleCell,
                  indexPath.row < tableDriver.count else { continue }
            configureCell(cell, with: tableDriver.row(at: indexPath.row))
        }
    }

    func shouldRefreshVisibleCells(from oldState: NowListeningViewState, to newState: NowListeningViewState) -> Bool {
        oldState.currentRoomNo != newState.currentRoomNo ||
        oldState.currentScenario != newState.currentScenario ||
        oldState.currentMode != newState.currentMode ||
        oldState.configuredSampleRate != newState.configuredSampleRate ||
        oldState.configuredChannels != newState.configuredChannels ||
        oldState.captureSampleRate != newState.captureSampleRate ||
        oldState.captureChannels != newState.captureChannels ||
        oldState.playbackChannels != newState.playbackChannels
    }

    func localizedLanguageName(for code: String) -> String {
        if let option = supportedLanguageOptions.first(where: { $0.code == code }) {
            return option.title
        }
        return Locale(identifier: "zh-Hans-CN").localizedString(forIdentifier: code) ?? code
    }

    func syncLanguagePickerSelection() {
        guard supportedLanguageOptions.isEmpty == false else { return }
        guard languagePickerView.numberOfComponents >= 2 else { return }

        let maxRow = supportedLanguageOptions.count - 1
        let sourceIndex = supportedLanguageOptions.firstIndex(where: { $0.code == state.sourceLanguage }) ?? 0
        let targetIndex = supportedLanguageOptions.firstIndex(where: { $0.code == state.targetLanguage }) ?? min(1, maxRow)

        languagePickerView.selectRow(min(sourceIndex, maxRow), inComponent: 0, animated: false)
        languagePickerView.selectRow(min(targetIndex, maxRow), inComponent: 1, animated: false)
    }

    @objc func onTapStartListening() {
        viewModel.startListening()
    }

    @objc func onTapStopListening() {
        viewModel.stopListening()
    }

    @objc func onTapModelStatus() {
        viewModel.downloadModel()
    }

    @objc func onTapModelDetail() {
        modelPackageListView.toggleExpanded()
        refreshModelDetailButtonTitle()
    }

    @objc func onTapCancelDownload() {
        viewModel.cancelDownload()
    }

    @objc func onTapChangeLanguage() {
        showLanguagePicker()
    }

    @objc func onClose() {
        viewModel.onViewWillClose()
        dismiss(animated: true)
    }

    func showLanguagePicker() {
        guard pickerMaskView.superview == nil else { return }
        guard supportedLanguageOptions.count >= 2 else { return }

        pickerMaskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pickerMaskView.alpha = 0
        pickerMaskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideLanguagePicker)))
        view.addSubview(pickerMaskView)
        pickerMaskView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        pickerContainerView.backgroundColor = .systemBackground
        pickerContainerView.layer.cornerRadius = 12
        pickerContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        pickerContainerView.clipsToBounds = true
        view.addSubview(pickerContainerView)
        pickerContainerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.height.equalTo(320)
            pickerBottomConstraint = make.bottom.equalToSuperview().offset(320).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(hideLanguagePicker), for: .touchUpInside)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmLanguageSelection), for: .touchUpInside)

        let sourceLabel = UILabel()
        sourceLabel.text = "源语言"
        sourceLabel.textAlignment = .center
        sourceLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sourceLabel.textColor = .secondaryLabel

        let targetLabel = UILabel()
        targetLabel.text = "目标语言"
        targetLabel.textAlignment = .center
        targetLabel.font = .systemFont(ofSize: 13, weight: .medium)
        targetLabel.textColor = .secondaryLabel

        languagePickerView.dataSource = self
        languagePickerView.delegate = self
        languagePickerView.reloadAllComponents()

        let topLine = UIView()
        topLine.backgroundColor = .separator
        let midLine = UIView()
        midLine.backgroundColor = .separator

        pickerContainerView.addSubview(cancelButton)
        pickerContainerView.addSubview(confirmButton)
        pickerContainerView.addSubview(sourceLabel)
        pickerContainerView.addSubview(targetLabel)
        pickerContainerView.addSubview(topLine)
        pickerContainerView.addSubview(midLine)
        pickerContainerView.addSubview(languagePickerView)

        cancelButton.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(8)
            make.height.equalTo(36)
        }
        confirmButton.snp.makeConstraints { make in
            make.right.equalToSuperview().inset(16)
            make.top.equalTo(cancelButton)
            make.height.equalTo(cancelButton)
        }
        sourceLabel.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.top.equalTo(cancelButton.snp.bottom).offset(6)
            make.width.equalToSuperview().multipliedBy(0.5)
        }
        targetLabel.snp.makeConstraints { make in
            make.right.equalToSuperview()
            make.top.equalTo(sourceLabel)
            make.width.equalTo(sourceLabel)
        }
        topLine.snp.makeConstraints { make in
            make.top.equalTo(sourceLabel.snp.bottom).offset(6)
            make.left.right.equalToSuperview()
            make.height.equalTo(0.5)
        }
        midLine.snp.makeConstraints { make in
            make.top.equalTo(topLine)
            make.bottom.equalToSuperview()
            make.width.equalTo(0.5)
            make.centerX.equalToSuperview()
        }
        languagePickerView.snp.makeConstraints { make in
            make.top.equalTo(topLine.snp.bottom)
            make.left.right.bottom.equalToSuperview()
        }

        syncLanguagePickerSelection()

        view.layoutIfNeeded()
        pickerBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.pickerMaskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    @objc func hideLanguagePicker() {
        guard pickerMaskView.superview != nil else { return }
        pickerBottomConstraint?.update(offset: 320)
        UIView.animate(withDuration: 0.25, animations: {
            self.pickerMaskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.languagePickerView.delegate = nil
            self.languagePickerView.dataSource = nil
            self.pickerContainerView.subviews.forEach { $0.removeFromSuperview() }
            self.pickerContainerView.removeFromSuperview()
            self.pickerMaskView.removeFromSuperview()
        })
    }

    @objc func confirmLanguageSelection() {
        guard supportedLanguageOptions.count >= 2 else { return }
        let sourceRow = languagePickerView.selectedRow(inComponent: 0)
        let targetRow = languagePickerView.selectedRow(inComponent: 1)
        guard supportedLanguageOptions.indices.contains(sourceRow),
              supportedLanguageOptions.indices.contains(targetRow) else {
            return
        }
        let sourceCode = supportedLanguageOptions[sourceRow].code
        let targetCode = supportedLanguageOptions[targetRow].code
        hideLanguagePicker()
        viewModel.applyLanguages(source: sourceCode, target: targetCode)
    }
}

extension OfflineListenController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableDriver.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: NowListeningBubbleCell.reuseId,
                                                       for: indexPath) as? NowListeningBubbleCell else {
            return UITableViewCell()
        }
        let row = tableDriver.row(at: indexPath.row)
        configureCell(cell, with: row)
        return cell
    }
}

extension OfflineListenController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tableDriver.handleDidScroll()
    }
}

extension OfflineListenController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        2
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        supportedLanguageOptions.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        guard supportedLanguageOptions.indices.contains(row) else { return nil }
        return supportedLanguageOptions[row].title
    }

    func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
        pickerView.bounds.width / 2
    }
}
