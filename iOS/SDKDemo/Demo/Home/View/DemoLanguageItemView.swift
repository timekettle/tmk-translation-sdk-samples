//
//  DemoLanguageItemView.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit

final class DemoLanguageItemView: UIButton {
    private let captionLabel = UILabel()
    private let valueLabel = UILabel()
    private let codeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(caption: String, value: String, code: String?) {
        captionLabel.text = caption
        valueLabel.text = value
        codeLabel.text = code ?? ""
        codeLabel.isHidden = (code?.isEmpty ?? true)
    }

    private func setupUI() {
        adjustsImageWhenHighlighted = false
        backgroundColor = DemoTheme.card
        layer.cornerRadius = DemoTheme.smallRadius
        layer.borderWidth = 1.5
        layer.borderColor = DemoTheme.border.cgColor
        clipsToBounds = true

        captionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        captionLabel.textColor = DemoTheme.textDim
        captionLabel.textAlignment = .center
        captionLabel.isUserInteractionEnabled = false

        valueLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        valueLabel.textColor = DemoTheme.text
        valueLabel.textAlignment = .center
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.8
        valueLabel.isUserInteractionEnabled = false

        codeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        codeLabel.textColor = DemoTheme.text
        codeLabel.textAlignment = .center
        codeLabel.isUserInteractionEnabled = false

        let stack = UIStackView(arrangedSubviews: [captionLabel, valueLabel, codeLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false

        addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
        }
    }
}
