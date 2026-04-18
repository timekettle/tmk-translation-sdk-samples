//
//  ViewController.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit
import Combine

final class ViewController: UIViewController {
    private let viewModel = DemoHomeViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var state = DemoHomeViewState()

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let actionContainer = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let scenarioStack = UIStackView()
    private let modeGrid = UIStackView()
    private let modeTopRow = UIStackView()
    private let modeBottomRow = UIStackView()
    private let languageRow = UIStackView()
    private let listenCard = DemoOptionCardView()
    private let oneToOneCard = DemoOptionCardView()
    private let onlineCard = DemoOptionCardView()
    private let offlineCard = DemoOptionCardView()
    private let autoCard = DemoOptionCardView()
    private let mixCard = DemoOptionCardView()
    private let sourceLanguageButton = DemoLanguageItemView()
    private let targetLanguageButton = DemoLanguageItemView()
    private let swapButton = UIButton(type: .system)
    private let footerLabel = UILabel()
    private let startButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigationBar()
        setupUI()
        bindViewModel()
        viewModel.onViewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.onViewWillAppear()
    }

    private func setupUI() {
        view.backgroundColor = DemoTheme.background

        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        view.addSubview(actionContainer)

        scrollView.snp.makeConstraints { make in
            make.top.left.right.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(actionContainer.snp.top)
        }
        contentView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.width.equalTo(scrollView)
        }

        titleLabel.text = "翻译中台"
        titleLabel.textColor = DemoTheme.text
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        subtitleLabel.text = "先选场景，再选模式"
        subtitleLabel.textColor = DemoTheme.textDim
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textAlignment = .center

        listenCard.configure(icon: DemoHomeScenario.listen.icon,
                             title: DemoHomeScenario.listen.title,
                             subtitle: DemoHomeScenario.listen.subtitle,
                             showsCheck: true,
                             tintColor: DemoTheme.accent,
                             badgeTextColor: DemoTheme.accent,
                             badgeBackgroundColor: DemoTheme.accent.withAlphaComponent(0.14))
        oneToOneCard.configure(icon: DemoHomeScenario.oneToOne.icon,
                               title: DemoHomeScenario.oneToOne.title,
                               subtitle: DemoHomeScenario.oneToOne.subtitle,
                               showsCheck: true,
                               tintColor: DemoTheme.accent,
                               badgeTextColor: DemoTheme.accent,
                               badgeBackgroundColor: DemoTheme.accent.withAlphaComponent(0.14))
        onlineCard.configure(icon: DemoHomeMode.online.icon,
                             title: DemoHomeMode.online.title,
                             subtitle: DemoHomeMode.online.subtitle,
                             badge: DemoHomeMode.online.badgeText,
                             enabled: true,
                             tintColor: DemoTheme.online,
                             badgeTextColor: DemoTheme.online,
                             badgeBackgroundColor: DemoTheme.online.withAlphaComponent(0.15))
        offlineCard.configure(icon: DemoHomeMode.offline.icon,
                              title: DemoHomeMode.offline.title,
                              subtitle: DemoHomeMode.offline.subtitle,
                              badge: DemoHomeMode.offline.badgeText,
                              enabled: true,
                              tintColor: DemoTheme.offline,
                              badgeTextColor: DemoTheme.offline,
                              badgeBackgroundColor: DemoTheme.offline.withAlphaComponent(0.15))
        autoCard.configure(icon: DemoHomeMode.auto.icon,
                           title: DemoHomeMode.auto.title,
                           subtitle: DemoHomeMode.auto.subtitle,
                           badge: DemoHomeMode.auto.badgeText,
                           enabled: false,
                           tintColor: DemoTheme.auto,
                           badgeTextColor: DemoTheme.auto,
                           badgeBackgroundColor: DemoTheme.auto.withAlphaComponent(0.15))
        mixCard.configure(icon: DemoHomeMode.mix.icon,
                          title: DemoHomeMode.mix.title,
                          subtitle: DemoHomeMode.mix.subtitle,
                          badge: DemoHomeMode.mix.badgeText,
                          enabled: false,
                          tintColor: DemoTheme.mix,
                          badgeTextColor: DemoTheme.mix,
                          badgeBackgroundColor: DemoTheme.mix.withAlphaComponent(0.15))

        [listenCard, oneToOneCard].forEach { card in
            card.addTarget(self, action: #selector(onScenarioCardTap(_:)), for: .touchUpInside)
        }
        [onlineCard, offlineCard, autoCard, mixCard].forEach { card in
            card.addTarget(self, action: #selector(onModeCardTap(_:)), for: .touchUpInside)
        }

        sourceLanguageButton.addTarget(self, action: #selector(onChangeSourceLanguage), for: .touchUpInside)
        targetLanguageButton.addTarget(self, action: #selector(onChangeTargetLanguage), for: .touchUpInside)
        sourceLanguageButton.configure(caption: "源语言", value: "请选择", code: nil)
        targetLanguageButton.configure(caption: "目标语言", value: "请选择", code: nil)

        swapButton.setTitle("⇄", for: .normal)
        swapButton.setTitleColor(.white, for: .normal)
        swapButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        swapButton.backgroundColor = DemoTheme.primary
        swapButton.layer.cornerRadius = 22
        swapButton.addTarget(self, action: #selector(onSwapLanguage), for: .touchUpInside)

        footerLabel.textColor = DemoTheme.textDim
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.numberOfLines = 0
        footerLabel.textAlignment = .center

        startButton.setTitle("开始翻译", for: .normal)
        startButton.setTitleColor(.white, for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        startButton.backgroundColor = DemoTheme.primary
        startButton.layer.cornerRadius = DemoTheme.smallRadius
        startButton.addTarget(self, action: #selector(onStartTranslation), for: .touchUpInside)

        let heroView = UIView()
        let scenarioTitle = makeSectionTitle("① 使用场景")
        let modeTitle = makeSectionTitle("② 翻译模式")
        let modeHint = UILabel()
        modeHint.text = "智能切换和双引擎竞速暂不支持，已保留入口样式"
        modeHint.textColor = DemoTheme.accent
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.numberOfLines = 0
        let languageTitle = makeSectionTitle("③ 语言设置")

        contentView.addSubview(heroView)
        heroView.addSubview(titleLabel)
        heroView.addSubview(subtitleLabel)

        scenarioStack.axis = .vertical
        scenarioStack.spacing = 10
        scenarioStack.distribution = .fillEqually
        scenarioStack.addArrangedSubview(listenCard)
        scenarioStack.addArrangedSubview(oneToOneCard)

        modeTopRow.axis = .horizontal
        modeTopRow.spacing = 12
        modeTopRow.distribution = .fillEqually
        modeTopRow.addArrangedSubview(onlineCard)
        modeTopRow.addArrangedSubview(offlineCard)

        modeBottomRow.axis = .horizontal
        modeBottomRow.spacing = 12
        modeBottomRow.distribution = .fillEqually
        modeBottomRow.addArrangedSubview(autoCard)
        modeBottomRow.addArrangedSubview(mixCard)

        modeGrid.axis = .vertical
        modeGrid.spacing = 12
        modeGrid.addArrangedSubview(modeTopRow)
        modeGrid.addArrangedSubview(modeBottomRow)

        languageRow.axis = .horizontal
        languageRow.spacing = 12
        languageRow.alignment = .center
        languageRow.addArrangedSubview(sourceLanguageButton)
        languageRow.addArrangedSubview(swapButton)
        languageRow.addArrangedSubview(targetLanguageButton)

        [scenarioTitle, scenarioStack, modeTitle, modeHint, modeGrid, languageTitle, languageRow, footerLabel].forEach {
            contentView.addSubview($0)
        }
        actionContainer.addSubview(startButton)

        heroView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(24)
            make.left.right.equalToSuperview().inset(16)
        }
        titleLabel.snp.makeConstraints { make in
            make.top.centerX.equalToSuperview()
        }
        subtitleLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(8)
            make.left.right.bottom.equalToSuperview()
        }

        scenarioTitle.snp.makeConstraints { make in
            make.top.equalTo(heroView.snp.bottom).offset(28)
            make.left.right.equalToSuperview().inset(16)
        }
        scenarioStack.snp.makeConstraints { make in
            make.top.equalTo(scenarioTitle.snp.bottom).offset(12)
            make.left.right.equalToSuperview().inset(16)
        }
        listenCard.snp.makeConstraints { make in
            make.height.equalTo(94)
        }

        modeTitle.snp.makeConstraints { make in
            make.top.equalTo(scenarioStack.snp.bottom).offset(28)
            make.left.right.equalToSuperview().inset(16)
        }
        modeHint.snp.makeConstraints { make in
            make.top.equalTo(modeTitle.snp.bottom).offset(8)
            make.left.right.equalToSuperview().inset(16)
        }
        modeGrid.snp.makeConstraints { make in
            make.top.equalTo(modeHint.snp.bottom).offset(12)
            make.left.right.equalToSuperview().inset(16)
        }
        [onlineCard, offlineCard, autoCard, mixCard].forEach { card in
            card.snp.makeConstraints { make in
                make.height.equalTo(146)
            }
        }

        languageTitle.snp.makeConstraints { make in
            make.top.equalTo(modeGrid.snp.bottom).offset(28)
            make.left.right.equalToSuperview().inset(16)
        }
        languageRow.snp.makeConstraints { make in
            make.top.equalTo(languageTitle.snp.bottom).offset(12)
            make.left.right.equalToSuperview().inset(16)
        }
        swapButton.snp.makeConstraints { make in
            make.width.height.equalTo(44)
        }
        sourceLanguageButton.snp.makeConstraints { make in
            make.width.equalTo(targetLanguageButton)
            make.height.equalTo(92)
        }
        targetLanguageButton.snp.makeConstraints { make in
            make.height.equalTo(sourceLanguageButton)
        }
        footerLabel.snp.makeConstraints { make in
            make.top.equalTo(languageRow.snp.bottom).offset(16)
            make.left.right.equalToSuperview().inset(24)
            make.bottom.equalToSuperview().inset(24)
        }

        actionContainer.backgroundColor = DemoTheme.background
        actionContainer.layer.borderWidth = 1 / UIScreen.main.scale
        actionContainer.layer.borderColor = DemoTheme.border.cgColor
        actionContainer.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
        }
        startButton.snp.makeConstraints { make in
            make.top.equalTo(actionContainer.snp.top).offset(12)
            make.left.right.equalToSuperview().inset(16)
            make.height.equalTo(56)
            make.bottom.equalTo(view.safeAreaLayoutGuide.snp.bottom).inset(12)
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

    private func render(_ state: DemoHomeViewState) {
        self.state = state
        listenCard.applySelectedState(state.selectedScenario == .listen)
        oneToOneCard.applySelectedState(state.selectedScenario == .oneToOne)
        onlineCard.applySelectedState(state.selectedMode == .online)
        offlineCard.applySelectedState(state.selectedMode == .offline)
        autoCard.applySelectedState(false)
        mixCard.applySelectedState(false)
        updateLanguageButton(sourceLanguageButton, option: state.sourceLanguage)
        updateLanguageButton(targetLanguageButton, option: state.targetLanguage)
        footerLabel.text = state.footerText
        startButton.isEnabled = state.isStartEnabled
        startButton.alpha = state.isStartEnabled ? 1 : 0.5
    }

    private func configureNavigationBar() {
        title = ""
        navigationItem.titleView = UIView(frame: .zero)
        navigationController?.navigationBar.prefersLargeTitles = false
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = DemoTheme.background
        appearance.titleTextAttributes = [.foregroundColor: DemoTheme.text]
        appearance.largeTitleTextAttributes = [.foregroundColor: DemoTheme.text]
        appearance.shadowColor = DemoTheme.border
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
        navigationController?.navigationBar.tintColor = DemoTheme.primaryLight
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: makeNavigationButton(title: "设置",
                                                                                              action: #selector(onOpenSettings)))
    }

    private func makeNavigationButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(DemoTheme.primaryLight, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.backgroundColor = DemoTheme.card
        button.layer.cornerRadius = 10
        button.layer.borderWidth = 1
        button.layer.borderColor = DemoTheme.border.cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func updateLanguageButton(_ button: DemoLanguageItemView, option: DemoLanguageOption?) {
        let label = button === sourceLanguageButton ? "源语言" : "目标语言"
        button.configure(caption: label,
                         value: option?.title ?? "请选择",
                         code: option?.actualCode)
    }

    private func makeSectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = DemoTheme.textDim
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func presentLanguagePicker(title: String,
                                       selectedCode: String?,
                                       selectionHandler: @escaping (DemoLanguageOption) -> Void) {
        let controller = DemoLanguagePickerViewController(title: title,
                                                          options: state.languages,
                                                          selectedCode: selectedCode,
                                                          onConfirm: selectionHandler)
        present(controller, animated: true)
    }

    @objc private func onScenarioCardTap(_ sender: DemoOptionCardView) {
        if sender === listenCard {
            viewModel.selectScenario(.listen)
        } else {
            viewModel.selectScenario(.oneToOne)
        }
    }

    @objc private func onModeCardTap(_ sender: DemoOptionCardView) {
        switch sender {
        case onlineCard:
            viewModel.selectMode(.online)
        case offlineCard:
            viewModel.selectMode(.offline)
        default:
            break
        }
    }

    @objc private func onChangeSourceLanguage() {
        guard state.languages.isEmpty == false else { return }
        presentLanguagePicker(title: "选择源语言",
                              selectedCode: state.sourceLanguage?.actualCode) { [weak self] option in
            self?.viewModel.selectSourceLanguage(option)
        }
    }

    @objc private func onChangeTargetLanguage() {
        guard state.languages.isEmpty == false else { return }
        presentLanguagePicker(title: "选择目标语言",
                              selectedCode: state.targetLanguage?.actualCode) { [weak self] option in
            self?.viewModel.selectTargetLanguage(option)
        }
    }

    @objc private func onSwapLanguage() {
        viewModel.swapLanguages()
    }

    @objc private func onOpenSettings() {
        let controller = DemoSettingsViewController()
        present(controller, animated: true)
    }

    @objc private func onStartTranslation() {
        guard let sourceLanguage = state.sourceLanguage?.actualCode,
              let targetLanguage = state.targetLanguage?.actualCode else { return }
        switch (state.selectedScenario, state.selectedMode) {
        case (.listen, .online):
            let controller = NowListeningController(initialSourceLanguage: sourceLanguage,
                                                    initialTargetLanguage: targetLanguage)
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case (.oneToOne, .online):
            let controller = OneToOneController(initialSourceLanguage: sourceLanguage,
                                                initialTargetLanguage: targetLanguage)
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case (.listen, .offline):
            let controller = OfflineListenController(initialSourceLanguage: sourceLanguage,
                                                     initialTargetLanguage: targetLanguage)
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case (.oneToOne, .offline):
            let controller = Offline1V1Controller(initialSourceLanguage: sourceLanguage,
                                                  initialTargetLanguage: targetLanguage)
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .fullScreen
            present(nav, animated: true)
        case (_, .auto), (_, .mix):
            break
        }
    }
}
