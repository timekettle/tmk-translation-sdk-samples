import UIKit
import SnapKit
import Combine
import TmkTranslationSDK

final class OneToOneController: UIViewController {
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

    private let viewModel = OneToOneViewModel()
    private let initialSourceLanguage: String?
    private let initialTargetLanguage: String?
    private var state = OneToOneViewState()
    private var cancellables = Set<AnyCancellable>()
    private lazy var tableDriver = ChatTableDriver<OneToOneRowViewData>(tableView: tableView)
    private let pickerMaskView = UIView()
    private let pickerContainerView = UIView()
    private let modePickerView = UIPickerView()
    private var pickerBottomConstraint: Constraint?
    private let allModes = OneToOnePlaybackMode.allCases
    private var supportedSourceLanguageOptions: [LanguageOption] = []
    private let zhLocale = Locale(identifier: "zh-Hans-CN")
    private let sourceLangMaskView = UIView()
    private let sourceLangContainerView = UIView()
    private let sourceLangPickerView = UIPickerView()
    private var sourceLangBottomConstraint: Constraint?
    // 音色选择器：与离线一对一保持一致，左右声道同时选择后统一提交。
    private let speakerMaskView = UIView()
    private let speakerContainerView = UIView()
    private let speakerPickerView = UIPickerView()
    private var speakerBottomConstraint: Constraint?
    private let speakerGenderOptions: [TmkSpeakerGender] = [.male, .female]

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
        installDemoMemoryMonitor(mode: "online_one_to_one", visibleByDefault: false)
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

/// 气泡数量仅属于当前页面实例；滑块草稿在“确定”前不会改变聚合器。
func presentBubbleRetentionLimitPicker(from presenter: UIViewController,
                                      current: Int,
                                      onConfirm: @escaping (Int) -> Void) {
    let alert = UIAlertController(title: "保留气泡数量", message: "仅保留最新的气泡，范围 10～500", preferredStyle: .alert)
    let content = UIViewController()
    let valueLabel = UILabel()
    let slider = UISlider()
    let bounded = min(max(current, DemoConversationBubbleAssembler.minimumMaxRows), DemoConversationBubbleAssembler.maximumMaxRows)
    valueLabel.text = "当前：\(bounded)"
    valueLabel.textAlignment = .center
    slider.minimumValue = Float(DemoConversationBubbleAssembler.minimumMaxRows)
    slider.maximumValue = Float(DemoConversationBubbleAssembler.maximumMaxRows)
    slider.value = Float(bounded)
    slider.addAction(UIAction { _ in valueLabel.text = "当前：\(Int(slider.value.rounded()))" }, for: .valueChanged)
    content.view.addSubview(valueLabel)
    content.view.addSubview(slider)
    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    slider.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        valueLabel.topAnchor.constraint(equalTo: content.view.topAnchor),
        valueLabel.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
        valueLabel.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
        slider.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 12),
        slider.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
        slider.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
        slider.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
        content.view.widthAnchor.constraint(equalToConstant: 240),
    ])
    alert.setValue(content, forKey: "contentViewController")
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
        onConfirm(Int(slider.value.rounded()))
    })
    presenter.present(alert, animated: true)
}

private extension OneToOneController {
    func setupUI() {
        title = "一对一"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭",
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(onClose))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "设置",
                                                            image: nil,
                                                            primaryAction: nil,
                                                            menu: makeSettingsMenu())
        statusLabel.numberOfLines = 1
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .label
        infoLabel.numberOfLines = 2
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabel

        setupButton(startListeningButton, title: "开始收听", action: #selector(onTapStartListening))
        setupButton(stopListeningButton, title: "停止收听", action: #selector(onTapStopListening))
        speakerMaskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideSpeakerPicker)))

        tableView.register(OneToOneBubbleCell.self, forCellReuseIdentifier: OneToOneBubbleCell.reuseId)
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
                    guard let bubbleCell = cell as? OneToOneBubbleCell else { return }
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

    func render(_ state: OneToOneViewState) {
        statusLabel.text = state.statusText
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        let sourceName = localizedLanguageName(for: state.sourceLanguage)
        let targetName = localizedLanguageName(for: state.targetLanguage)
        infoLabel.text = "房间:\(state.currentRoomNo)  能力:\(state.scenarioOption.title)  语言:\(sourceName)→\(targetName)  采集:\(capture)  回放:\(playback)  播放:\(state.playbackMode.title)"
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

    func configureCell(_ cell: OneToOneBubbleCell, with row: OneToOneRowViewData) {
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        let meta = "sessionId: \(row.sessionId)  bubbleId: \(row.bubbleId)\n房间: \(state.currentRoomNo)  通道: \(state.currentScenario)/\(state.currentMode)\n采样: 配置\(state.configuredSampleRate)Hz/\(state.configuredChannels)ch  采集\(capture)  回放\(playback)"
        cell.configure(metaText: meta,
                       sourceLangCode: row.sourceLangCode,
                       sourceText: row.sourceText,
                       sourceSegments: row.sourceSegments,
                       targetLangCode: row.targetLangCode,
                       translatedText: row.translatedText,
                       translatedSegments: row.translatedSegments,
                       isRightBubble: row.lane == .right,
                       isBubbleEnded: row.isBubbleEnded,
                       timeRangeText: DemoBubbleTimeRangeFormatter.text(isBubbleEnded: row.isBubbleEnded,
                                                                        bOffset: row.bOffset,
                                                                        bDuration: row.bDuration))
    }

    func refreshVisibleCells() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard let cell = tableView.cellForRow(at: indexPath) as? OneToOneBubbleCell,
                  indexPath.row < tableDriver.count else { continue }
            configureCell(cell, with: tableDriver.row(at: indexPath.row))
        }
    }

    func shouldRefreshVisibleCells(from oldState: OneToOneViewState, to newState: OneToOneViewState) -> Bool {
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

    func makeSettingsMenu() -> UIMenu {
        let languageAction = UIAction(title: "切换语言") { [weak self] _ in
            self?.loadSupportedLanguagesAndShowPicker()
        }
        let playbackAction = UIAction(title: "播放音源") { [weak self] _ in
            self?.showPlaybackModePicker()
        }
        let translateEngineAction = UIAction(title: "翻译引擎") { [weak self] _ in
            self?.showTranslateEngineMenu()
        }
        let recognizeEngineAction = UIAction(title: "识别引擎") { [weak self] _ in
            self?.showRecognizeEngineMenu()
        }
        let translateModeAction = UIAction(title: "翻译下发模式") { [weak self] _ in
            self?.showTranslateModeMenu()
        }
        let scenarioAction = UIAction(title: "房间能力") { [weak self] _ in
            self?.showScenarioMenu()
        }
        let channelModeAction = UIAction(title: "通道模式") { [weak self] _ in
            self?.showDialogChannelModeMenu()
        }
        let speakerAction = UIAction(title: "音色") { [weak self] _ in
            self?.showSpeakerPicker()
        }
        let bubbleRetentionAction = UIAction(title: "保留气泡数量：\(viewModel.currentBubbleRetentionLimit())") { [weak self] _ in
            guard let self else { return }
            presentBubbleRetentionLimitPicker(from: self,
                                              current: self.viewModel.currentBubbleRetentionLimit(),
                                              onConfirm: self.viewModel.setBubbleRetentionLimit)
        }
        return UIMenu(title: "", children: [bubbleRetentionAction, languageAction, playbackAction, translateEngineAction, recognizeEngineAction, translateModeAction, scenarioAction, channelModeAction, speakerAction, demoMemoryMonitorMenuAction(visibleByDefault: false)])
    }

    func showScenarioMenu() {
        let alert = UIAlertController(title: "在线一对一房间能力",
                                      message: nil,
                                      preferredStyle: .actionSheet)
        OneToOneScenarioOption.allCases.forEach { option in
            addScenarioAction(option, to: alert)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addScenarioAction(_ option: OneToOneScenarioOption,
                                   to alert: UIAlertController) {
        let displayTitle = state.scenarioOption == option ? "✓ \(option.title)" : option.title
        let action = UIAlertAction(title: displayTitle, style: .default) { [weak self] _ in
            self?.viewModel.updateScenarioOption(option)
        }
        alert.addAction(action)
    }

    func showDialogChannelModeMenu() {
        let alert = UIAlertController(title: "通道模式",
                                      message: nil,
                                      preferredStyle: .actionSheet)
        addDialogChannelModeAction(mode: .standard, to: alert)
        addDialogChannelModeAction(mode: .lowLatency, to: alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private func addDialogChannelModeAction(mode: TmkDialogConversationAudioMode,
                                            to alert: UIAlertController) {
        let isSelected = state.dialogConversationAudioMode == mode
        let title = isSelected ? "\(mode.oneToOneDemoTitle)（当前）" : mode.oneToOneDemoTitle
        let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
            self?.viewModel.updateDialogConversationAudioMode(mode)
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

    func showPlaybackModePicker() {
        guard pickerMaskView.superview == nil else { return }

        pickerMaskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pickerMaskView.alpha = 0
        pickerMaskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hidePlaybackModePicker)))
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
            make.height.equalTo(280)
            pickerBottomConstraint = make.bottom.equalToSuperview().offset(280).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(hidePlaybackModePicker), for: .touchUpInside)
        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmPlaybackMode), for: .touchUpInside)

        let line = UIView()
        line.backgroundColor = .separator

        modePickerView.dataSource = self
        modePickerView.delegate = self
        if let index = allModes.firstIndex(of: state.playbackMode) {
            modePickerView.selectRow(index, inComponent: 0, animated: false)
        }

        pickerContainerView.addSubview(cancelButton)
        pickerContainerView.addSubview(confirmButton)
        pickerContainerView.addSubview(line)
        pickerContainerView.addSubview(modePickerView)

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
        line.snp.makeConstraints { make in
            make.top.equalTo(cancelButton.snp.bottom).offset(8)
            make.left.right.equalToSuperview()
            make.height.equalTo(0.5)
        }
        modePickerView.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom)
            make.left.right.bottom.equalToSuperview()
        }

        view.layoutIfNeeded()
        pickerBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.pickerMaskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    @objc func hidePlaybackModePicker() {
        guard pickerMaskView.superview != nil else { return }
        pickerBottomConstraint?.update(offset: 280)
        UIView.animate(withDuration: 0.25, animations: {
            self.pickerMaskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.modePickerView.delegate = nil
            self.modePickerView.dataSource = nil
            self.pickerContainerView.subviews.forEach { $0.removeFromSuperview() }
            self.pickerContainerView.removeFromSuperview()
            self.pickerMaskView.removeFromSuperview()
        })
    }

    @objc func confirmPlaybackMode() {
        let row = modePickerView.selectedRow(inComponent: 0)
        guard allModes.indices.contains(row) else { return }
        viewModel.setPlaybackMode(allModes[row])
        hidePlaybackModePicker()
    }

    // MARK: - 音色选择器

    func showSpeakerPicker() {
        guard speakerMaskView.superview == nil else { return }

        speakerMaskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        speakerMaskView.alpha = 0
        view.addSubview(speakerMaskView)
        speakerMaskView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        speakerContainerView.backgroundColor = .systemBackground
        speakerContainerView.layer.cornerRadius = 12
        speakerContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        speakerContainerView.clipsToBounds = true
        view.addSubview(speakerContainerView)
        speakerContainerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.height.equalTo(320)
            speakerBottomConstraint = make.bottom.equalToSuperview().offset(320).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(hideSpeakerPicker), for: .touchUpInside)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmSpeakerSelection), for: .touchUpInside)

        let leftLabel = UILabel()
        leftLabel.text = "左声道"
        leftLabel.textAlignment = .center
        leftLabel.font = .systemFont(ofSize: 13, weight: .medium)
        leftLabel.textColor = .secondaryLabel

        let rightLabel = UILabel()
        rightLabel.text = "右声道"
        rightLabel.textAlignment = .center
        rightLabel.font = .systemFont(ofSize: 13, weight: .medium)
        rightLabel.textColor = .secondaryLabel

        let line = UIView()
        line.backgroundColor = .separator
        let midLine = UIView()
        midLine.backgroundColor = .separator

        speakerPickerView.dataSource = self
        speakerPickerView.delegate = self
        speakerPickerView.reloadAllComponents()
        syncSpeakerPickerSelection()

        speakerContainerView.addSubview(cancelButton)
        speakerContainerView.addSubview(confirmButton)
        speakerContainerView.addSubview(leftLabel)
        speakerContainerView.addSubview(rightLabel)
        speakerContainerView.addSubview(line)
        speakerContainerView.addSubview(midLine)
        speakerContainerView.addSubview(speakerPickerView)

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
        leftLabel.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.top.equalTo(cancelButton.snp.bottom).offset(8)
            make.width.equalToSuperview().multipliedBy(0.5)
            make.height.equalTo(24)
        }
        rightLabel.snp.makeConstraints { make in
            make.right.equalToSuperview()
            make.top.equalTo(leftLabel)
            make.width.equalTo(leftLabel)
            make.height.equalTo(leftLabel)
        }
        line.snp.makeConstraints { make in
            make.top.equalTo(leftLabel.snp.bottom).offset(4)
            make.left.right.equalToSuperview()
            make.height.equalTo(0.5)
        }
        midLine.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom)
            make.bottom.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.equalTo(0.5)
        }
        speakerPickerView.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom)
            make.left.right.bottom.equalToSuperview()
        }

        view.layoutIfNeeded()
        speakerBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.speakerMaskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    @objc func hideSpeakerPicker() {
        guard speakerMaskView.superview != nil else { return }
        speakerBottomConstraint?.update(offset: 320)
        UIView.animate(withDuration: 0.25, animations: {
            self.speakerMaskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.speakerPickerView.delegate = nil
            self.speakerPickerView.dataSource = nil
            self.speakerContainerView.subviews.forEach { $0.removeFromSuperview() }
            self.speakerContainerView.removeFromSuperview()
            self.speakerMaskView.removeFromSuperview()
        })
    }

    @objc func confirmSpeakerSelection() {
        let leftRow = speakerPickerView.selectedRow(inComponent: 0)
        let rightRow = speakerPickerView.selectedRow(inComponent: 1)
        guard speakerGenderOptions.indices.contains(leftRow),
              speakerGenderOptions.indices.contains(rightRow) else {
            return
        }
        viewModel.updateSpeakers(left: speakerGenderOptions[leftRow],
                                 right: speakerGenderOptions[rightRow])
        hideSpeakerPicker()
    }

    func syncSpeakerPickerSelection() {
        guard speakerPickerView.numberOfComponents >= 2 else { return }
        let leftIndex = speakerGenderOptions.firstIndex(of: viewModel.currentLeftSpeakerGender) ?? 0
        let rightIndex = speakerGenderOptions.firstIndex(of: viewModel.currentRightSpeakerGender) ?? 0
        speakerPickerView.selectRow(leftIndex, inComponent: 0, animated: false)
        speakerPickerView.selectRow(rightIndex, inComponent: 1, animated: false)
    }

    func localizedLanguageName(for code: String) -> String {
        if let title = supportedSourceLanguageOptions.first(where: { $0.code == code })?.title {
            return title
        }
        return zhLocale.localizedString(forIdentifier: code) ?? code
    }

    func loadSupportedLanguagesAndShowPicker() {
        viewModel.fetchSupportedLanguages { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.supportedSourceLanguageOptions = response.localeOptions
                    .filter { $0.code.lowercased().hasPrefix(self.state.targetLanguage.lowercased()) == false }
                    .map { LanguageOption(code: $0.code, title: self.languageTitle(for: $0)) }
                    .sorted { $0.title < $1.title }
                self.showSourceLanguagePicker()
            case .failure:
                if self.supportedSourceLanguageOptions.isEmpty == false {
                    self.showSourceLanguagePicker()
                }
            }
        }
    }

    func showSourceLanguagePicker() {
        guard sourceLangMaskView.superview == nil else { return }
        guard supportedSourceLanguageOptions.isEmpty == false else { return }

        sourceLangMaskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        sourceLangMaskView.alpha = 0
        sourceLangMaskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideSourceLanguagePicker)))
        view.addSubview(sourceLangMaskView)
        sourceLangMaskView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        sourceLangContainerView.backgroundColor = .systemBackground
        sourceLangContainerView.layer.cornerRadius = 12
        sourceLangContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sourceLangContainerView.clipsToBounds = true
        view.addSubview(sourceLangContainerView)
        sourceLangContainerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.height.equalTo(280)
            sourceLangBottomConstraint = make.bottom.equalToSuperview().offset(280).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(hideSourceLanguagePicker), for: .touchUpInside)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmSourceLanguage), for: .touchUpInside)

        let line = UIView()
        line.backgroundColor = .separator
        sourceLangPickerView.dataSource = self
        sourceLangPickerView.delegate = self
        if let idx = supportedSourceLanguageOptions.firstIndex(where: { $0.code == state.sourceLanguage }) {
            sourceLangPickerView.selectRow(idx, inComponent: 0, animated: false)
        }

        sourceLangContainerView.addSubview(cancelButton)
        sourceLangContainerView.addSubview(confirmButton)
        sourceLangContainerView.addSubview(line)
        sourceLangContainerView.addSubview(sourceLangPickerView)

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
        line.snp.makeConstraints { make in
            make.top.equalTo(cancelButton.snp.bottom).offset(8)
            make.left.right.equalToSuperview()
            make.height.equalTo(0.5)
        }
        sourceLangPickerView.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom)
            make.left.right.bottom.equalToSuperview()
        }

        view.layoutIfNeeded()
        sourceLangBottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.sourceLangMaskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    @objc func hideSourceLanguagePicker() {
        guard sourceLangMaskView.superview != nil else { return }
        sourceLangBottomConstraint?.update(offset: 280)
        UIView.animate(withDuration: 0.25, animations: {
            self.sourceLangMaskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.sourceLangPickerView.delegate = nil
            self.sourceLangPickerView.dataSource = nil
            self.sourceLangContainerView.subviews.forEach { $0.removeFromSuperview() }
            self.sourceLangContainerView.removeFromSuperview()
            self.sourceLangMaskView.removeFromSuperview()
        })
    }

    @objc func confirmSourceLanguage() {
        let row = sourceLangPickerView.selectedRow(inComponent: 0)
        guard supportedSourceLanguageOptions.indices.contains(row) else { return }
        viewModel.applySourceLanguage(supportedSourceLanguageOptions[row].code)
        hideSourceLanguagePicker()
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

extension OneToOneController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tableDriver.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: OneToOneBubbleCell.reuseId, for: indexPath) as? OneToOneBubbleCell else {
            return UITableViewCell()
        }
        let row = tableDriver.row(at: indexPath.row)
        configureCell(cell, with: row)
        return cell
    }
}

extension OneToOneController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tableDriver.handleDidScroll()
    }
}

extension OneToOneController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        pickerView === speakerPickerView ? 2 : 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === modePickerView { return allModes.count }
        if pickerView === speakerPickerView { return speakerGenderOptions.count }
        return supportedSourceLanguageOptions.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === modePickerView {
            guard allModes.indices.contains(row) else { return nil }
            return allModes[row].title
        }
        if pickerView === speakerPickerView {
            guard speakerGenderOptions.indices.contains(row) else { return nil }
            return speakerGenderOptions[row].title
        }
        guard supportedSourceLanguageOptions.indices.contains(row) else { return nil }
        return supportedSourceLanguageOptions[row].title
    }
}

private extension TmkSpeakerGender {
    var title: String {
        switch self {
        case .male:
            return "男声"
        case .female:
            return "女声"
        }
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
