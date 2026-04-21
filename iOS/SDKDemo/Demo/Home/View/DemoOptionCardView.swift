//
//  DemoOptionCardView.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit

final class DemoOptionCardView: UIButton {
    private let iconLabel = UILabel()
    private let cardTitleLabel = UILabel()
    private let cardSubtitleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let checkView = UIView()
    private let mainStack = UIStackView()

    private var isCardSelected = false
    private var baseTintColor = DemoTheme.primary
    private var selectedTintColor = DemoTheme.primary
    private var badgeTintColor = DemoTheme.primaryLight
    private var badgeBackgroundColor = DemoTheme.primary.withAlphaComponent(0.14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(icon: String,
                   title: String,
                   subtitle: String,
                   badge: String? = nil,
                   showsCheck: Bool = false,
                   enabled: Bool = true,
                   tintColor: UIColor = DemoTheme.primary,
                   badgeTextColor: UIColor = DemoTheme.primaryLight,
                   badgeBackgroundColor: UIColor = DemoTheme.primary.withAlphaComponent(0.14)) {
        iconLabel.text = icon
        cardTitleLabel.text = title
        cardSubtitleLabel.text = subtitle
        badgeLabel.text = badge
        badgeLabel.isHidden = (badge == nil)
        checkView.isHidden = showsCheck == false
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1 : 0.45
        baseTintColor = tintColor
        selectedTintColor = tintColor
        badgeTintColor = badgeTextColor
        self.badgeBackgroundColor = badgeBackgroundColor
        updateAppearance()
    }

    func applySelectedState(_ selected: Bool) {
        isCardSelected = selected
        updateAppearance()
    }

    private func setupUI() {
        adjustsImageWhenHighlighted = false
        layer.cornerRadius = DemoTheme.radius
        layer.borderWidth = 1.5
        backgroundColor = DemoTheme.card
        clipsToBounds = true

        iconLabel.font = .systemFont(ofSize: 28)
        iconLabel.textAlignment = .center
        iconLabel.isUserInteractionEnabled = false

        cardTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        cardTitleLabel.textColor = DemoTheme.text
        cardTitleLabel.numberOfLines = 1
        cardTitleLabel.isUserInteractionEnabled = false

        cardSubtitleLabel.font = .systemFont(ofSize: 11)
        cardSubtitleLabel.textColor = DemoTheme.textDim
        cardSubtitleLabel.numberOfLines = 2
        cardSubtitleLabel.isUserInteractionEnabled = false

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.layer.cornerRadius = 6
        badgeLabel.clipsToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.isUserInteractionEnabled = false

        checkView.layer.cornerRadius = 10
        checkView.layer.borderWidth = 2
        checkView.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [cardTitleLabel, cardSubtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4

        let headerStack = UIStackView(arrangedSubviews: [iconLabel, textStack, checkView])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 12
        iconLabel.snp.makeConstraints { make in
            make.width.equalTo(36)
        }

        mainStack.axis = .vertical
        mainStack.spacing = 10
        mainStack.addArrangedSubview(headerStack)
        mainStack.addArrangedSubview(badgeLabel)
        mainStack.isUserInteractionEnabled = false

        addSubview(mainStack)

        checkView.snp.makeConstraints { make in
            make.width.height.equalTo(20)
        }
        mainStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
        }
        badgeLabel.snp.makeConstraints { make in
            make.height.equalTo(22)
            make.width.greaterThanOrEqualTo(68)
        }
    }

    private func updateAppearance() {
        layer.borderColor = (isCardSelected ? selectedTintColor : DemoTheme.border).cgColor
        backgroundColor = isCardSelected ? selectedTintColor.withAlphaComponent(0.12) : DemoTheme.card
        badgeLabel.textColor = badgeTintColor
        badgeLabel.backgroundColor = badgeBackgroundColor
        checkView.layer.borderColor = (isCardSelected ? selectedTintColor : DemoTheme.border).cgColor
        checkView.backgroundColor = isCardSelected ? selectedTintColor : .clear
    }
}
