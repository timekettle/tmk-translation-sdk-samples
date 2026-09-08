import UIKit
import SnapKit
import Combine
import TmkTranslationSDK

final class NowListeningController: UIViewController {
    private struct LanguageOption {
        let code: String
        let title: String
    }

    private let statusLabel = UILabel()
    private let infoLabel = UILabel()
    private let startListeningButton = UIButton(type: .system)
    private let stopListeningButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let networkOverlayView = NetworkQualityOverlayView()
    private var networkOverlayTopConstraint: Constraint?
    private var networkOverlayRightConstraint: Constraint?
    private var networkOverlayPanStartFrame: CGRect = .zero

    private let viewModel = NowListeningViewModel()
    private let initialSourceLanguage: String?
    private let initialTargetLanguage: String?
    private var cancellables = Set<AnyCancellable>()
    private var state = NowListeningViewState()
    private lazy var tableDriver = ChatTableDriver<NowListeningRowViewData>(tableView: tableView)
    private var supportedLanguageOptions: [LanguageOption] = []
    private let zhLocale = Locale(identifier: "zh-Hans-CN")

    private let pickerMaskView = UIView()
    private let pickerContainerView = UIView()
    private let languagePickerView = UIPickerView()
    private var pickerBottomConstraint: Constraint?
    private lazy var settingsBarButtonItem = UIBarButtonItem(title: "设置",
                                                             image: nil,
                                                             primaryAction: nil,
                                                             menu: makeSettingsMenu())
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
        installDemoMemoryMonitor(mode: "online_listen", visibleByDefault: false)
        bindViewModel()
        viewModel.configureInitialLanguages(source: initialSourceLanguage, target: initialTargetLanguage)
        viewModel.onViewDidLoad()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            demoMemoryPageExit()
            viewModel.onViewWillClose()
        }
    }
}

private extension NowListeningController {
    func setupUI() {
        title = "在线收听"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭",
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(onClose))
        navigationItem.rightBarButtonItem = settingsBarButtonItem

        statusLabel.numberOfLines = 1
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .label
        infoLabel.numberOfLines = 1
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabel

        setupButton(startListeningButton, title: "开始收听", action: #selector(onTapStartListening))
        setupButton(stopListeningButton, title: "停止收听", action: #selector(onTapStopListening))

        tableView.register(NowListeningBubbleCell.self, forCellReuseIdentifier: NowListeningBubbleCell.reuseId)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.separatorStyle = .none

        view.addSubview(statusLabel)
        view.addSubview(infoLabel)
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
        startListeningButton.snp.makeConstraints { make in
            make.top.equalTo(infoLabel.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(12)
            make.height.equalTo(32)
            make.width.equalTo(stopListeningButton)
        }
        stopListeningButton.snp.makeConstraints { make in
            make.top.equalTo(startListeningButton)
            make.left.equalTo(startListeningButton.snp.right).offset(8)
            make.right.equalToSuperview().inset(12)
            make.height.equalTo(startListeningButton)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(startListeningButton.snp.bottom).offset(8)
            make.left.right.bottom.equalToSuperview()
        }

        view.addSubview(networkOverlayView)
        networkOverlayView.snp.makeConstraints { make in
            networkOverlayTopConstraint = make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8).constraint
            networkOverlayRightConstraint = make.right.equalToSuperview().inset(12).constraint
            make.width.lessThanOrEqualTo(240)
        }
        networkOverlayView.setContentHuggingPriority(.required, for: .vertical)
        networkOverlayView.setContentCompressionResistancePriority(.required, for: .vertical)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onNetworkOverlayPan(_:)))
        networkOverlayView.addGestureRecognizer(pan)
        networkOverlayView.isUserInteractionEnabled = true
    }

    @objc func onNetworkOverlayPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            // 拖动中只用 transform，避免 Auto Layout / 文案变高导致“不跟手”。
            networkOverlayView.transform = .identity
            networkOverlayPanStartFrame = networkOverlayView.frame
        case .changed:
            let translation = gesture.translation(in: view)
            networkOverlayView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
        case .ended, .cancelled, .failed:
            let translation = gesture.translation(in: view)
            networkOverlayView.transform = .identity

            let startFrame = networkOverlayPanStartFrame
            let proposed = CGRect(
                x: startFrame.origin.x + translation.x,
                y: startFrame.origin.y + translation.y,
                width: startFrame.width,
                height: startFrame.height
            )
            let safeTop = view.safeAreaInsets.top
            let safeBottom = view.safeAreaInsets.bottom
            let minX: CGFloat = 8
            let maxX = max(minX, view.bounds.width - proposed.width - 8)
            let minY = safeTop
            let maxY = max(minY, view.bounds.height - safeBottom - proposed.height - 8)
            let clampedX = min(max(proposed.minX, minX), maxX)
            let clampedY = min(max(proposed.minY, minY), maxY)

            // top 相对 safeArea；right 用 inset（与初始 .inset(12) 同向，勿用 offset）。
            let topOffset = max(0, clampedY - safeTop)
            let rightInset = max(8, view.bounds.maxX - (clampedX + proposed.width))
            networkOverlayTopConstraint?.update(offset: topOffset)
            networkOverlayRightConstraint?.update(inset: rightInset)
            view.layoutIfNeeded()
            gesture.setTranslation(.zero, in: view)
        default:
            break
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

        viewModel.remoteCloseRoomPrompt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                self?.presentConversationPrompt(prompt)
            }
            .store(in: &cancellables)

        viewModel.dismissReconnectTimeoutPrompt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let alert = self?.presentedViewController as? UIAlertController,
                      alert.title == "连接恢复超时" else { return }
                alert.dismiss(animated: true)
            }
            .store(in: &cancellables)
    }

    func render(_ state: NowListeningViewState) {
        statusLabel.text = state.statusText
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        infoLabel.text = "房间:\(state.currentRoomNo)  能力:\(state.scenarioOption.title)  语言:\(localizedLanguageName(for: state.sourceLanguage))→\(localizedLanguageName(for: state.targetLanguage))  采集:\(capture)  回放:\(playback)"
        startListeningButton.isEnabled = state.canStartListening
        if state.canStartListening { demoMemoryRuntimeReady() }
        stopListeningButton.isEnabled = state.canStopListening
        networkOverlayView.update(network: state.networkStats, bootstrap: state.bootstrapStats, wifiSpeed: state.wifiSpeed)
    }

    func setupButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
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

    @objc func onTapStartListening() {
        demoMemoryRunStarted()
        viewModel.startListening()
    }

    @objc func onTapStopListening() {
        demoMemoryRunStopped()
        viewModel.stopListening()
    }

    @objc func onTapChangeLanguage() {
        loadSupportedLanguagesAndShowPicker()
    }

    func makeSettingsMenu() -> UIMenu {
        UIMenu(title: "", children: [
            UIAction(title: "保留气泡数量：\(viewModel.currentBubbleRetentionLimit())") { [weak self] _ in
                guard let self else { return }
                presentBubbleRetentionLimitPicker(from: self,
                                                  current: self.viewModel.currentBubbleRetentionLimit(),
                                                  onConfirm: self.viewModel.setBubbleRetentionLimit)
            },
            UIAction(title: "切换语言") { [weak self] _ in
                self?.loadSupportedLanguagesAndShowPicker()
            },
            UIAction(title: "房间能力") { [weak self] _ in
                self?.showScenarioMenu()
            },
            UIAction(title: "翻译引擎") { [weak self] _ in
                self?.showTranslateEngineMenu()
            },
            UIAction(title: "识别引擎") { [weak self] _ in
                self?.showRecognizeEngineMenu()
            },
            UIAction(title: "翻译下发模式") { [weak self] _ in
                self?.showTranslateModeMenu()
            },
            UIAction(title: "音色") { [weak self] _ in
                self?.showSpeakerMenu()
            },
            demoMemoryMonitorMenuAction(visibleByDefault: false)
        ])
    }

    func showScenarioMenu() {
        let alert = UIAlertController(title: "在线收听房间能力",
                                      message: "选择后将在下次创建房间时生效。",
                                      preferredStyle: .actionSheet)
        NowListeningScenarioOption.allCases.forEach { option in
            addScenarioAction(option, to: alert)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addScenarioAction(_ option: NowListeningScenarioOption,
                                   to alert: UIAlertController) {
        let displayTitle = state.scenarioOption == option ? "✓ \(option.title)" : option.title
        let action = UIAlertAction(title: displayTitle, style: .default) { [weak self] _ in
            self?.viewModel.updateScenarioOption(option)
        }
        alert.addAction(action)
    }

    func showTranslateEngineMenu() {
        let alert = UIAlertController(title: "翻译引擎",
                                      message: nil,
                                      preferredStyle: .actionSheet)
        addTranslateEngineAction(title: "默认", engine: .automatic, to: alert)
        addTranslateEngineAction(title: "快速", engine: .fast, to: alert)
        addTranslateEngineAction(title: "精准", engine: .accurate, to: alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addTranslateEngineAction(title: String,
                                          engine: TmkOnlineTranslateEngine,
                                          to alert: UIAlertController) {
        let displayTitle = state.translateEngine == engine ? "✓ \(title)" : title
        let action = UIAlertAction(title: displayTitle, style: .default) { [weak self] _ in
            self?.viewModel.updateTranslateEngine(engine)
        }
        alert.addAction(action)
    }

    func showRecognizeEngineMenu() {
        let alert = UIAlertController(title: "识别引擎",
                                      message: "切换后将重新创建房间和通道。",
                                      preferredStyle: .actionSheet)
        addRecognizeEngineAction(title: "默认", engine: .default, to: alert)
        addRecognizeEngineAction(title: "端到端", engine: .endToEnd, to: alert)
        addRecognizeEngineAction(title: "三段式", engine: .threeStage, to: alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addRecognizeEngineAction(title: String,
                                          engine: TmkOnlineRecognizeEngine,
                                          to alert: UIAlertController) {
        let displayTitle = state.recognizeEngine == engine ? "✓ \(title)" : title
        let action = UIAlertAction(title: displayTitle, style: .default) { [weak self] _ in
            self?.viewModel.updateRecognizeEngine(engine)
        }
        alert.addAction(action)
    }

    func showTranslateModeMenu() {
        let alert = UIAlertController(title: "翻译下发模式",
                                      message: "切换后将重新创建房间和通道。",
                                      preferredStyle: .actionSheet)
        addTranslateModeAction(mode: .default, to: alert)
        addTranslateModeAction(mode: .partial, to: alert)
        addTranslateModeAction(mode: .stable, to: alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addTranslateModeAction(mode: TmkTranslateDeliveryMode,
                                        to alert: UIAlertController) {
        let title = mode == state.translateMode ? "\(mode.onlineDemoTitle)（当前）" : mode.onlineDemoTitle
        let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
            self?.viewModel.updateTranslateMode(mode)
        }
        alert.addAction(action)
    }

    func showSpeakerMenu() {
        let alert = UIAlertController(title: "在线收听音色",
                                      message: "现场收听仅设置 left 声道音色，下一次 TTS 合成生效。",
                                      preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "男声", style: .default) { [weak self] _ in
            self?.viewModel.updateSpeaker(gender: .male)
        })
        alert.addAction(UIAlertAction(title: "女声", style: .default) { [weak self] _ in
            self?.viewModel.updateSpeaker(gender: .female)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    @objc func onClose() {
        viewModel.onViewWillClose()
        dismiss(animated: true)
    }

    func presentConversationPrompt(_ prompt: DemoConversationPrompt) {
        if let alert = presentedViewController as? UIAlertController,
           alert.title == "连接恢复超时",
           prompt.style != .reconnectTimeout {
            alert.dismiss(animated: true) { [weak self] in
                self?.presentConversationPrompt(prompt)
            }
            return
        }
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: prompt.title,
                                      message: prompt.message,
                                      preferredStyle: .alert)
        if prompt.style == .reconnectTimeout {
            alert.addAction(UIAlertAction(title: "继续等待", style: .cancel) { [weak self] _ in
                self?.viewModel.continueWaitingAfterReconnectTimeout()
            })
            alert.addAction(UIAlertAction(title: "重新创建", style: .default) { [weak self] _ in
                self?.viewModel.recreateAfterReconnectTimeout()
            })
        } else {
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                self?.onClose()
            })
        }
        if prompt.style == .restart {
            alert.addAction(UIAlertAction(title: "重新创建", style: .default) { [weak self] _ in
                self?.viewModel.recreateAfterRemoteClose()
            })
        }
        present(alert, animated: true)
    }

    func localizedLanguageName(for code: String) -> String {
        if let title = supportedLanguageOptions.first(where: { $0.code == code })?.title {
            return title
        }
        return zhLocale.localizedString(forIdentifier: code) ?? code
    }

    func loadSupportedLanguagesAndShowPicker() {
        viewModel.fetchSupportedLanguages { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.supportedLanguageOptions = response.localeOptions
                    .map { LanguageOption(code: $0.code, title: self.languageTitle(for: $0)) }
                    .sorted { $0.title < $1.title }
                self.showLanguagePicker()
            case .failure:
                if self.supportedLanguageOptions.isEmpty == false {
                    self.showLanguagePicker()
                }
            }
        }
    }

    func showLanguagePicker() {
        guard pickerMaskView.superview == nil else { return }
        guard supportedLanguageOptions.isEmpty == false else { return }

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
            make.height.equalTo(20)
            make.width.equalToSuperview().multipliedBy(0.5)
        }
        targetLabel.snp.makeConstraints { make in
            make.right.equalToSuperview()
            make.top.equalTo(sourceLabel)
            make.height.equalTo(sourceLabel)
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

        if let sourceIndex = supportedLanguageOptions.firstIndex(where: { $0.code == state.sourceLanguage }) {
            languagePickerView.selectRow(sourceIndex, inComponent: 0, animated: false)
        }
        if let targetIndex = supportedLanguageOptions.firstIndex(where: { $0.code == state.targetLanguage }) {
            languagePickerView.selectRow(targetIndex, inComponent: 1, animated: false)
        }

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
        guard supportedLanguageOptions.isEmpty == false else { return }
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

    func languageTitle(for locale: TmkLocaleItem) -> String {
        let code = locale.code
        var name = locale.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = zhLocale.localizedString(forIdentifier: code) ?? code
        }
        // 语言名称之外补充语言 code,方便区分同名语言的不同地区变体
        guard name != code else { return code }
        return "\(name) (\(code))"
    }
}

extension NowListeningController: UITableViewDataSource {
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

extension NowListeningController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tableDriver.handleDidScroll()
    }
}

extension NowListeningController: UIPickerViewDataSource, UIPickerViewDelegate {
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

private final class NetworkQualityOverlayView: UIView {
    private let lossLabel = UILabel()
    private let wifiLabel = UILabel()
    private let totalLabel = UILabel()
    private let summaryLabel = UILabel()
    private var tickTimer: Timer?
    private var latestNetwork = DemoOnlineNetworkStatsSnapshot()
    private var latestBootstrap = DemoBootstrapSnapshot()
    private var latestWifi = DemoWifiSpeedSnapshot()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        layer.cornerRadius = 10
        clipsToBounds = true

        lossLabel.font = .systemFont(ofSize: 11, weight: .medium)
        lossLabel.textColor = .white
        lossLabel.numberOfLines = 1

        wifiLabel.font = .systemFont(ofSize: 11, weight: .medium)
        wifiLabel.textColor = UIColor(red: 184/255, green: 190/255, blue: 207/255, alpha: 1)
        wifiLabel.numberOfLines = 2

        totalLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        totalLabel.textColor = UIColor(red: 184/255, green: 190/255, blue: 207/255, alpha: 1)
        totalLabel.numberOfLines = 1

        summaryLabel.font = .systemFont(ofSize: 10, weight: .regular)
        summaryLabel.textColor = UIColor(red: 184/255, green: 190/255, blue: 207/255, alpha: 1)
        summaryLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [lossLabel, wifiLabel, totalLabel, summaryLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTimer?.invalidate()
    }

    func update(network: DemoOnlineNetworkStatsSnapshot,
                bootstrap: DemoBootstrapSnapshot,
                wifiSpeed: DemoWifiSpeedSnapshot) {
        latestNetwork = network
        latestBootstrap = bootstrap
        latestWifi = wifiSpeed
        refreshLabels()
        syncTickTimer()
    }

    private func refreshLabels() {
        let nowMs = DemoBootstrapPipelineTracker.nowMs()
        lossLabel.text = "上丢（\(latestNetwork.formatLoss(latestNetwork.txLossRate))）  下丢（\(latestNetwork.formatLoss(latestNetwork.rxLossRate))）"
        wifiLabel.text = latestWifi.displayLine()
        if latestWifi.status == .failed || latestWifi.isBandwidthPoor {
            wifiLabel.textColor = UIColor(red: 231/255, green: 76/255, blue: 60/255, alpha: 1)
        } else if latestWifi.status == .running {
            wifiLabel.textColor = UIColor(red: 241/255, green: 196/255, blue: 15/255, alpha: 1)
        } else if latestWifi.status == .done {
            wifiLabel.textColor = UIColor(red: 46/255, green: 204/255, blue: 113/255, alpha: 1)
        } else {
            wifiLabel.textColor = UIColor(red: 184/255, green: 190/255, blue: 207/255, alpha: 1)
        }

        totalLabel.text = latestBootstrap.totalLine(nowMs: nowMs)
        summaryLabel.text = latestBootstrap.summaryLine(nowMs: nowMs)

        if latestBootstrap.failed {
            totalLabel.textColor = UIColor(red: 231/255, green: 76/255, blue: 60/255, alpha: 1)
        } else if latestBootstrap.totalMs != nil {
            totalLabel.textColor = UIColor(red: 46/255, green: 204/255, blue: 113/255, alpha: 1)
        } else if latestBootstrap.isRunning {
            totalLabel.textColor = UIColor(red: 241/255, green: 196/255, blue: 15/255, alpha: 1)
        } else {
            totalLabel.textColor = UIColor(red: 184/255, green: 190/255, blue: 207/255, alpha: 1)
        }
    }

    private func syncTickTimer() {
        if latestBootstrap.isRunning {
            guard tickTimer == nil else { return }
            tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.refreshLabels()
            }
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }
}
