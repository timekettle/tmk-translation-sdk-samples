import UIKit
import SnapKit

final class NowListeningBubbleCell: UITableViewCell {
    static let reuseId = "NowListeningBubbleCell"

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

    func configure(row: NowListeningRowViewData,
                   roomNo: String,
                   scenario: String,
                   mode: String,
                   configuredSampleRate: Int,
                   configuredChannels: Int,
                   captureSampleRate: Int,
                   captureChannels: Int,
                   playbackChannels: Int) {
        let capture = captureChannels > 0 ? "\(captureSampleRate)Hz/\(captureChannels)ch" : "-"
        let playback = playbackChannels > 0 ? "\(playbackChannels)ch" : "-"
        let sourceDisplay = row.sourceText.isEmpty ? "..." : row.sourceText
        let targetDisplay = row.translatedText.isEmpty ? "..." : row.translatedText
        let metaText = "sessionId: \(row.sessionId)  bubbleId: \(row.bubbleId)\n房间: \(roomNo)  通道: \(scenario)/\(mode)\n采样: 配置\(configuredSampleRate)Hz/\(configuredChannels)ch  采集\(capture)  回放\(playback)"
        contentLabel.text = "\(metaText)\n\n源语言(\(row.sourceLangCode))：\(sourceDisplay)\n目标语言(\(row.targetLangCode))：\(targetDisplay)"

        bubbleView.snp.remakeConstraints { make in
            make.top.bottom.equalToSuperview().inset(6)
            make.width.lessThanOrEqualTo(contentView.snp.width).multipliedBy(0.78)
            make.left.equalToSuperview().inset(12)
        }
        bubbleView.backgroundColor = UIColor.systemGray5
        contentLabel.textAlignment = .left
    }
}
