//
//  OfflineBubbleSettingsViewController.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit

/// 离线收听与离线一对一共用的气泡设置窗口。
final class OfflineBubbleSettingsViewController: UIViewController {
    private let lengthSplitEnabled: Bool
    private let onLengthSplitEnabledChange: (Bool) -> Void
    private let thresholdUnits: Int
    private let onThresholdUnitsChange: (Int) -> Void
    private let lengthSplitSwitch = UISwitch()
    private let thresholdSlider = UISlider()
    private let thresholdTitleLabel = UILabel()
    private let thresholdLabel = UILabel()

    init(lengthSplitEnabled: Bool, thresholdUnits: Int, onLengthSplitEnabledChange: @escaping (Bool) -> Void,
         onThresholdUnitsChange: @escaping (Int) -> Void) {
        self.lengthSplitEnabled = lengthSplitEnabled
        self.thresholdUnits = min(max(thresholdUnits, 10), 500)
        self.onLengthSplitEnabledChange = onLengthSplitEnabledChange
        self.onThresholdUnitsChange = onThresholdUnitsChange
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "气泡设置"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: self,
            action: #selector(close)
        )

        lengthSplitSwitch.isOn = lengthSplitEnabled
        lengthSplitSwitch.addTarget(self, action: #selector(lengthSplitChanged), for: .valueChanged)

        let scrollView = UIScrollView()
        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 14

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(16)
            make.width.equalTo(scrollView.snp.width).offset(-32)
        }

        contentStack.addArrangedSubview(makeLengthSplitCard())
        contentStack.addArrangedSubview(makeThresholdCard())

        let legendTitle = UILabel()
        legendTitle.text = "BubbleEnd 边框颜色"
        legendTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        legendTitle.textColor = .secondaryLabel
        contentStack.addArrangedSubview(legendTitle)

        let legendCard = makeCard()
        let legendStack = UIStackView()
        legendStack.axis = .vertical
        legendStack.spacing = 14
        legendCard.addSubview(legendStack)
        legendStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(16)
        }
        legendStack.addArrangedSubview(makeLegendRow(
            colors: [.systemGreen, .systemBlue],
            title: "正常 final",
            detail: "保持当前气泡的默认边框色"
        ))
        legendStack.addArrangedSubview(makeLegendRow(
            colors: [UIColor(red: 1, green: 0.8, blue: 0, alpha: 1)],
            title: "达到字符阈值",
            detail: "黄色边框"
        ))
        legendStack.addArrangedSubview(makeLegendRow(
            colors: [.systemRed],
            title: "异常结束",
            detail: "红色边框"
        ))
        legendStack.addArrangedSubview(makeLegendRow(
            colors: [.systemPurple],
            title: "其他结束原因",
            detail: "紫色边框"
        ))
        contentStack.addArrangedSubview(legendCard)
    }

    private func makeThresholdCard() -> UIView {
        let card = makeCard()
        thresholdTitleLabel.text = "分泡单位：\(thresholdUnits)"
        thresholdTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        thresholdTitleLabel.textColor = .label
        thresholdLabel.text = "范围 10～500，按语种计量单位累计"
        thresholdLabel.font = .systemFont(ofSize: 13)
        thresholdLabel.textColor = .secondaryLabel
        thresholdSlider.minimumValue = 10
        thresholdSlider.maximumValue = 500
        thresholdSlider.value = Float(thresholdUnits)
        thresholdSlider.isContinuous = true
        thresholdSlider.addTarget(self, action: #selector(thresholdChanged), for: .valueChanged)
        thresholdSlider.addTarget(
            self,
            action: #selector(thresholdChangeFinished),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        let stack = UIStackView(arrangedSubviews: [thresholdTitleLabel, thresholdSlider, thresholdLabel])
        stack.axis = .vertical
        stack.spacing = 10
        card.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        return card
    }

    @objc private func thresholdChanged() {
        let value = Int(thresholdSlider.value.rounded())
        thresholdTitleLabel.text = "分泡单位：\(value)"
    }

    @objc private func thresholdChangeFinished() {
        onThresholdUnitsChange(Int(thresholdSlider.value.rounded()))
    }

    private func makeLengthSplitCard() -> UIView {
        let card = makeCard()
        let title = UILabel()
        title.text = "达到字符阈值分气泡"
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .label

        let detail = UILabel()
        detail.text = "修改后会重启离线翻译通道"
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [title, detail])
        textStack.axis = .vertical
        textStack.spacing = 4

        let row = UIStackView(arrangedSubviews: [textStack, lengthSplitSwitch])
        row.alignment = .center
        row.spacing = 12
        card.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(16)
        }
        return card
    }

    private func makeLegendRow(colors: [UIColor], title: String, detail: String) -> UIView {
        let swatches = UIStackView()
        swatches.axis = .horizontal
        swatches.spacing = 5
        colors.forEach { color in
            let swatch = UIView()
            swatch.backgroundColor = color
            swatch.layer.cornerRadius = 7
            swatch.snp.makeConstraints { make in
                make.size.equalTo(14)
            }
            swatches.addArrangedSubview(swatch)
        }
        swatches.snp.makeConstraints { make in
            make.width.equalTo(42)
        }

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [swatches, textStack])
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func makeCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        return card
    }

    @objc private func lengthSplitChanged() {
        onLengthSplitEnabledChange(lengthSplitSwitch.isOn)
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
