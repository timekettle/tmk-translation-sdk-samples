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
    private let captureLabel = UILabel()
    private let captureSwitch = UISwitch()
    private let startListeningButton = UIButton(type: .system)
    private let stopListeningButton = UIButton(type: .system)
    private let sharePCMButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)

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

private extension OneToOneController {
    func setupUI() {
        title = "一对一"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭",
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(onClose))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "播放音源", style: .plain, target: self, action: #selector(onTapPlaybackMode)),
            UIBarButtonItem(title: "语言", style: .plain, target: self, action: #selector(onTapChangeLanguage))
        ]
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

        tableView.register(OneToOneBubbleCell.self, forCellReuseIdentifier: OneToOneBubbleCell.reuseId)
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
                    guard let bubbleCell = cell as? OneToOneBubbleCell else { return }
                    self.configureCell(bubbleCell, with: row)
                }
            }
            .store(in: &cancellables)
    }

    func render(_ state: OneToOneViewState) {
        statusLabel.text = state.statusText
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        let sourceName = localizedLanguageName(for: state.sourceLanguage)
        let targetName = localizedLanguageName(for: state.targetLanguage)
        infoLabel.text = "房间:\(state.currentRoomNo)  语言:\(sourceName)→\(targetName)  采集:\(capture)  回放:\(playback)  播放:\(state.playbackMode.title)"
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

    func configureCell(_ cell: OneToOneBubbleCell, with row: OneToOneRowViewData) {
        let capture = state.captureChannels > 0 ? "\(state.captureSampleRate)Hz/\(state.captureChannels)ch" : "-"
        let playback = state.playbackChannels > 0 ? "\(state.playbackChannels)ch" : "-"
        let meta = "sessionId: \(row.sessionId)  bubbleId: \(row.bubbleId)\n房间: \(state.currentRoomNo)  通道: \(state.currentScenario)/\(state.currentMode)\n采样: 配置\(state.configuredSampleRate)Hz/\(state.configuredChannels)ch  采集\(capture)  回放\(playback)"
        cell.configure(metaText: meta,
                       sourceLangCode: row.sourceLangCode,
                       sourceText: row.sourceText,
                       targetLangCode: row.targetLangCode,
                       translatedText: row.translatedText,
                       isRightBubble: row.lane == .right)
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
        viewModel.startListening()
    }

    @objc func onTapStopListening() {
        viewModel.stopListening()
    }

    @objc func onTapSharePCM() {
        let urls = viewModel.currentPCMURLs
        guard urls.isEmpty == false else { return }
        presentShareActivityForFileURLs(urls, sourceView: sharePCMButton)
    }

    @objc func onCaptureSwitchChanged() {
        viewModel.setCaptureEnabled(captureSwitch.isOn)
    }

    @objc func onTapPlaybackMode() {
        showPlaybackModePicker()
    }

    @objc func onTapChangeLanguage() {
        loadSupportedLanguagesAndShowPicker()
    }

    @objc func onClose() {
        viewModel.onViewWillClose()
        dismiss(animated: true)
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
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === modePickerView { return allModes.count }
        return supportedSourceLanguageOptions.count
    }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === modePickerView {
            guard allModes.indices.contains(row) else { return nil }
            return allModes[row].title
        }
        guard supportedSourceLanguageOptions.indices.contains(row) else { return nil }
        return supportedSourceLanguageOptions[row].title
    }
}
