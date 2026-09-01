import UIKit

/// Shared debug overlay used by both online demo modes.
final class NetworkQualityOverlayView: UIView {
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
