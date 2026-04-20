//
//  DemoLanguagePickerViewController.swift
//  TmkTranslationSDKDemo
//

import UIKit
import SnapKit

final class DemoLanguagePickerViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    private let titleText: String
    private let options: [DemoLanguageOption]
    private let selectedCode: String?
    private let onConfirm: (DemoLanguageOption) -> Void

    private let maskView = UIView()
    private let containerView = UIView()
    private let pickerView = UIPickerView()
    private var bottomConstraint: Constraint?

    init(title: String,
         options: [DemoLanguageOption],
         selectedCode: String?,
         onConfirm: @escaping (DemoLanguageOption) -> Void) {
        self.titleText = title
        self.options = options
        self.selectedCode = selectedCode
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showPicker()
    }

    private func setupUI() {
        view.backgroundColor = .clear

        maskView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        maskView.alpha = 0
        maskView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onCancel)))
        view.addSubview(maskView)
        maskView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        containerView.backgroundColor = .systemBackground
        containerView.layer.cornerRadius = 12
        containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        containerView.clipsToBounds = true
        view.addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.height.equalTo(320)
            bottomConstraint = make.bottom.equalToSuperview().offset(320).constraint
        }

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)

        let confirmButton = UIButton(type: .system)
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(onConfirmTap), for: .touchUpInside)

        let titleLabel = UILabel()
        titleLabel.text = titleText
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabel

        let topLine = UIView()
        topLine.backgroundColor = .separator

        pickerView.dataSource = self
        pickerView.delegate = self

        containerView.addSubview(cancelButton)
        containerView.addSubview(confirmButton)
        containerView.addSubview(titleLabel)
        containerView.addSubview(topLine)
        containerView.addSubview(pickerView)

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
        titleLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(cancelButton)
        }
        topLine.snp.makeConstraints { make in
            make.top.equalTo(cancelButton.snp.bottom).offset(6)
            make.left.right.equalToSuperview()
            make.height.equalTo(0.5)
        }
        pickerView.snp.makeConstraints { make in
            make.top.equalTo(topLine.snp.bottom)
            make.left.right.bottom.equalToSuperview()
        }

        if let selectedCode,
           let index = options.firstIndex(where: { $0.actualCode == selectedCode }) {
            pickerView.selectRow(index, inComponent: 0, animated: false)
        }
    }

    private func showPicker() {
        view.layoutIfNeeded()
        bottomConstraint?.update(offset: 0)
        UIView.animate(withDuration: 0.25) {
            self.maskView.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    @objc private func onCancel() {
        bottomConstraint?.update(offset: 320)
        UIView.animate(withDuration: 0.25, animations: {
            self.maskView.alpha = 0
            self.view.layoutIfNeeded()
        }, completion: { _ in
            self.dismiss(animated: false)
        })
    }

    @objc private func onConfirmTap() {
        guard options.isEmpty == false else {
            onCancel()
            return
        }
        onConfirm(options[pickerView.selectedRow(inComponent: 0)])
        onCancel()
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        options.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        let option = options[row]
        return "\(option.title) (\(option.actualCode))"
    }
}
