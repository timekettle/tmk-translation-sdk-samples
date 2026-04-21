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
    private let captureLabel = UILabel()
    private let captureSwitch = UISwitch()
    private let startListeningButton = UIButton(type: .system)
    private let stopListeningButton = UIButton(type: .system)
    private let sharePCMButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

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

private extension NowListeningController {
    func setupUI() {
        title = "在线收听"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭",
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(onClose))
        navigationItem.rightBarButtonItem = languageBarButtonItem

        statusLabel.numberOfLines = 1
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .label
        infoLabel.numberOfLines = 1
        infoLabel.font = .systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabel
        captureLabel.text = "翻译音频采集"
        captureLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captureLabel.textColor = .secondaryLabel
        captureSwitch.addTarget(self, action: #selector(onCaptureSwitchChanged), for: .valueChanged)

        setupButton(startListeningButton, title: "开始收听", action: #selector(onTapStartListening))
        setupButton(stopListeningButton, title: "停止收听", action: #selector(onTapStopListening))
        setupButton(sharePCMButton, title: "分享PCM", action: #selector(onTapSharePCM))

        tableView.register(NowListeningBubbleCell.self, forCellReuseIdentifier: NowListeningBubbleCell.reuseId)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.separatorStyle = .none

        view.addSubview(statusLabel)
        view.addSubview(infoLabel)
        view.addSubview(captureLabel)
        view.addSubview(captureSwitch)
        view.addSubview(startListeningButton)
        view.addSubview(stopListeningButton)
        view.addSubview(sharePCMButton)
        view.addSubview(tableView)

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(8)
            make.left.right.equalToSuperview().inset(12)
        }
        infoLabel.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom).offset(4)
            make.left.right.equalToSuperview().inset(16)
        }
        captureLabel.snp.makeConstraints { make in
            make.top.equalTo(infoLabel.snp.bottom).offset(8)
            make.left.equalToSuperview().offset(12)
            make.height.equalTo(32)
        }
        captureSwitch.snp.makeConstraints { make in
            make.centerY.equalTo(captureLabel)
            make.left.equalTo(captureLabel.snp.right).offset(6)
        }
        startListeningButton.snp.makeConstraints { make in
            make.top.equalTo(captureLabel)
            make.left.equalTo(captureSwitch.snp.right).offset(8)
            make.height.equalTo(captureLabel)
            make.width.equalTo(stopListeningButton)
        }
        stopListeningButton.snp.makeConstraints { make in
            make.top.equalTo(captureLabel)
            make.left.equalTo(startListeningButton.snp.right).offset(8)
            make.height.equalTo(captureLabel)
            make.width.equalTo(sharePCMButton)
        }
        sharePCMButton.snp.makeConstraints { make in
            make.top.equalTo(captureLabel)
            make.left.equalTo(stopListeningButton.snp.right).offset(8)
            make.right.equalToSuperview().inset(12)
            make.height.equalTo(captureLabel)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(captureLabel.snp.bottom).offset(8)
            make.left.right.bottom.equalToSuperview()
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
    }

    func render(_ state: NowListeningViewState) {
        statusLabel.text = state.statusText
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        infoLabel.text = "房间:\(state.currentRoomNo)  语言:\(localizedLanguageName(for: state.sourceLanguage))→\(localizedLanguageName(for: state.targetLanguage))  采集:\(capture)  回放:\(playback)"
        captureSwitch.isOn = state.isCaptureEnabled
        startListeningButton.isEnabled = state.canStartListening
        stopListeningButton.isEnabled = state.canStopListening
        sharePCMButton.isEnabled = state.canSharePCM
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
        viewModel.startListening()
    }

    @objc func onTapStopListening() {
        viewModel.stopListening()
    }

    @objc func onTapSharePCM() {
        guard let url = viewModel.currentPCMURL else { return }
        presentShareActivityForFileURLs([url], sourceView: sharePCMButton)
    }

    @objc func onCaptureSwitchChanged() {
        viewModel.setCaptureEnabled(captureSwitch.isOn)
    }

    @objc func onTapChangeLanguage() {
        loadSupportedLanguagesAndShowPicker()
    }

    @objc func onClose() {
        viewModel.onViewWillClose()
        dismiss(animated: true)
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

    func languageTitle(for locale: TmkSupportedLocale) -> String {
        let uiLang = locale.uiLang.trimmingCharacters(in: .whitespacesAndNewlines)
        let uiAccent = locale.uiAccent.trimmingCharacters(in: .whitespacesAndNewlines)
        if uiLang.isEmpty == false, uiAccent.isEmpty == false {
            return "\(uiLang)（\(uiAccent)）"
        }
        if uiLang.isEmpty == false {
            return uiLang
        }
        return zhLocale.localizedString(forIdentifier: locale.code) ?? locale.code
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
