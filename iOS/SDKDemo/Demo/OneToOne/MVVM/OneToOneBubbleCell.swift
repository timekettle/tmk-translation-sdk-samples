import UIKit
import SnapKit

final class OneToOneBubbleCell: UITableViewCell {
    static let reuseId = "OneToOneBubbleCell"
    private let bubbleView = UIView()
    private let contentLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        contentView.addSubview(bubbleView)
        bubbleView.layer.cornerRadius = 14
        bubbleView.clipsToBounds = true
        bubbleView.addSubview(contentLabel)
        contentLabel.numberOfLines = 0
        contentLabel.font = .systemFont(ofSize: 13)
        contentLabel.textColor = .label
        contentLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(10)
        }
    }

    func configure(metaText: String,
                   sourceLangCode: String,
                   sourceText: String,
                   sourceSegments: [DemoConversationDisplaySegment],
                   targetLangCode: String,
                   translatedText: String,
                   translatedSegments: [DemoConversationDisplaySegment],
                   isRightBubble: Bool,
                   isBubbleEnded: Bool,
                   bubbleEndReason: String? = nil,
                   timeRangeText: String? = nil) {
        contentLabel.attributedText = DemoConversationSegmentRenderer.makeBubbleText(
            metaText: metaText,
            sourceLangCode: sourceLangCode,
            sourceSegments: sourceSegments,
            sourceFallbackText: sourceText,
            targetLangCode: targetLangCode,
            translatedSegments: translatedSegments,
            translatedFallbackText: translatedText,
            font: contentLabel.font,
            timeRangeText: timeRangeText
        )
        bubbleView.layer.borderWidth = isBubbleEnded ? 1 : 0
        bubbleView.layer.borderColor = bubbleBorderColor(isRightBubble: isRightBubble, reason: bubbleEndReason)
        bubbleView.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.78)
            if isRightBubble {
                make.right.equalToSuperview().inset(12)
                bubbleView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            } else {
                make.left.equalToSuperview().inset(12)
                bubbleView.backgroundColor = UIColor.systemGray5
            }
        }
    }

    private func bubbleBorderColor(isRightBubble: Bool, reason: String?) -> CGColor? {
        let color: UIColor
        switch reason {
        case "length": color = .systemYellow
        case "error": color = .systemRed
        case nil, "natural", "native_final", "empty_final": color = isRightBubble ? .systemBlue : .systemGreen
        default: color = .systemPurple
        }
        return color.cgColor
    }
}
