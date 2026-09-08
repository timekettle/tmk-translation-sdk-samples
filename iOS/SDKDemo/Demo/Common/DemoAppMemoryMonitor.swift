import Foundation
import UIKit
import MachO
import ObjectiveC
import os.log

struct DemoAppMemoryBreakdown: Equatable {
    let footprintMB: Double
    let residentMB: Double
    let virtualMB: Double
    let internalMB: Double
    let compressedMB: Double
    let purgeableMB: Double
}

enum DemoMemoryTrend: String {
    case observing = "观察中"
    case stable = "稳定"
    case growing = "持续上涨"
    case warning = "内存警告"

    var color: UIColor {
        switch self {
        case .observing: return UIColor.white.withAlphaComponent(0.72)
        case .stable: return .systemGreen
        case .growing, .warning: return .systemRed
        }
    }
}

enum DemoMemoryTrendEvaluator {
    static func evaluate(
        elapsedSeconds: TimeInterval,
        newest: Double?,
        middle: Double?,
        oldest: Double?
    ) -> DemoMemoryTrend {
        guard elapsedSeconds >= 15 * 60 else { return .observing }
        guard let newest, let middle, let oldest else { return .stable }
        let growth = newest - oldest
        let slopeMBPerMinute = growth / 10.0
        return oldest < middle && middle < newest && growth >= 15 && slopeMBPerMinute >= 1
            ? .growing
            : .stable
    }
}

struct DemoMemoryCheckpoint: Equatable {
    let minute: Int
    let memoryMB: Double
    let growthMB: Double
    let trend: DemoMemoryTrend
}

struct DemoMemoryRuntimeHealth: Equatable {
    var onlineRows = 0
    var offlineRows = 0
    var audioDroppedFrames: UInt64 = 0
    var onlineState = "-"
    var offlineState = "-"
}

struct DemoAppMemorySnapshot: Equatable {
    var breakdown: DemoAppMemoryBreakdown?
    var pageEnterMB: Double?
    var runtimeReadyMB: Double?
    var runStartMB: Double?
    var checkpoints: [DemoMemoryCheckpoint] = []
    var trend: DemoMemoryTrend = .observing
    var warningCount = 0
    var isRunning = false
    var runtimeHealth: DemoMemoryRuntimeHealth?
}

private final class DemoIOSProcessMemorySampler {
    func sample() -> DemoAppMemoryBreakdown? {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult: kern_return_t = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else { return nil }

        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let basicResult: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }
        let mb = 1024.0 * 1024.0
        return DemoAppMemoryBreakdown(
            footprintMB: Double(vmInfo.phys_footprint) / mb,
            residentMB: Double(basicInfo.resident_size) / mb,
            virtualMB: Double(basicInfo.virtual_size) / mb,
            internalMB: Double(vmInfo.internal) / mb,
            compressedMB: Double(vmInfo.compressed) / mb,
            purgeableMB: Double(vmInfo.purgeable_volatile_pmap) / mb
        )
    }
}

private final class DemoAppMemorySessionStore {
    private let queue = DispatchQueue(label: "co.timekettle.demo.memory-store", qos: .utility)
    private let fileURL: URL

    init(mode: String, sessionID: String) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("demo_memory_sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("ios_\(mode)_\(sessionID).json")
        prune(directory: directory)
    }

    func save(mode: String, sessionID: String, completed: Bool, event: String, snapshot: DemoAppMemorySnapshot) {
        func jsonValue(_ value: Double?) -> Any { value ?? NSNull() }
        let payload: [String: Any] = [
            "platform": "iOS",
            "mode": mode,
            "session_id": sessionID,
            "completed": completed,
            "event": event,
            "updated_at_ms": Int(Date().timeIntervalSince1970 * 1000),
            "page_enter_mb": jsonValue(snapshot.pageEnterMB),
            "runtime_ready_mb": jsonValue(snapshot.runtimeReadyMB),
            "run_start_mb": jsonValue(snapshot.runStartMB),
            "current_mb": jsonValue(snapshot.breakdown?.footprintMB),
            "trend": snapshot.trend.rawValue,
            "memory_warning_count": snapshot.warningCount,
            "checkpoints": snapshot.checkpoints.map {
                ["minute": $0.minute, "memory_mb": $0.memoryMB, "growth_mb": $0.growthMB, "trend": $0.trend.rawValue]
            }
        ]
        queue.async { [fileURL] in
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func prune(directory: URL) {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )) ?? []
            let sorted = files.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            sorted.dropFirst(10).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}

final class DemoAppMemoryMonitor {
    private struct Sample { let uptime: TimeInterval; let memoryMB: Double }
    private static let logger = Logger(subsystem: "co.timekettle.demo", category: "AppMemory")
    private let mode: String
    private let sessionID = UUID().uuidString
    private let sampler = DemoIOSProcessMemorySampler()
    private let samplingQueue = DispatchQueue(label: "co.timekettle.demo.memory-sampler", qos: .utility)
    private lazy var store = DemoAppMemorySessionStore(mode: mode, sessionID: sessionID)
    private var timer: DispatchSourceTimer?
    private var samples: [Sample] = []
    private var runStartUptime: TimeInterval?
    private var lastMinutePersisted = -1
    private var warningObserver: NSObjectProtocol?
    private(set) var snapshot = DemoAppMemorySnapshot()
    var onUpdate: ((DemoAppMemorySnapshot) -> Void)?
    var runtimeHealthProvider: (() -> DemoMemoryRuntimeHealth)?

    init(mode: String) { self.mode = mode }

    func start() {
        guard timer == nil else { return }
        warningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.recordMemoryWarning() }
        sample(event: "PAGE_ENTER")
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sampleOnQueue(event: "SAMPLE") }
        self.timer = timer
        timer.resume()
    }

    func markRuntimeReady() {
        guard snapshot.runtimeReadyMB == nil else { return }
        sample(event: "RUNTIME_READY") { [weak self] value in self?.snapshot.runtimeReadyMB = value }
    }

    func markRunStarted() {
        guard runStartUptime == nil else { return }
        runStartUptime = ProcessInfo.processInfo.systemUptime
        snapshot.isRunning = true
        sample(event: "RUN_START") { [weak self] value in self?.snapshot.runStartMB = value }
    }

    func markRunStopped() {
        snapshot.isRunning = false
        sample(event: "RUN_STOP")
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
        warningObserver = nil
        sample(event: "PAGE_EXIT", completed: true)
    }

    private func recordMemoryWarning() {
        snapshot.warningCount += 1
        snapshot.trend = .warning
        sample(event: "MEMORY_WARNING")
    }

    private func sample(event: String, completed: Bool = false, assignment: ((Double) -> Void)? = nil) {
        samplingQueue.async { [weak self] in self?.sampleOnQueue(event: event, completed: completed, assignment: assignment) }
    }

    private func sampleOnQueue(event: String, completed: Bool = false, assignment: ((Double) -> Void)? = nil) {
        guard let breakdown = sampler.sample() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot.breakdown = breakdown
            self.snapshot.runtimeHealth = self.runtimeHealthProvider?()
            if self.snapshot.pageEnterMB == nil { self.snapshot.pageEnterMB = breakdown.footprintMB }
            assignment?(breakdown.footprintMB)
            self.samples.append(Sample(uptime: now, memoryMB: breakdown.footprintMB))
            self.samples.removeAll { now - $0.uptime > 95 * 60 }
            self.updateTrendAndCheckpoints(now: now)
            self.onUpdate?(self.snapshot)
            let elapsedMinute = self.runStartUptime.map { max(0, Int((now - $0) / 60)) } ?? -1
            if event != "SAMPLE" || (elapsedMinute >= 0 && elapsedMinute != self.lastMinutePersisted) {
                self.lastMinutePersisted = elapsedMinute
                self.persist(event: event, completed: completed)
            }
        }
    }

    private func updateTrendAndCheckpoints(now: TimeInterval) {
        guard let runStartUptime, let baseline = snapshot.runStartMB else { return }
        let elapsed = now - runStartUptime
        let windows = [0, 5, 10].map { offset -> Double? in
            median(samples.filter {
                let age = now - $0.uptime
                return age >= Double(offset) * 60 && age < Double(offset + 5) * 60
            }.map(\.memoryMB))
        }
        if snapshot.warningCount > 0 {
            snapshot.trend = .warning
        } else {
            snapshot.trend = DemoMemoryTrendEvaluator.evaluate(
                elapsedSeconds: elapsed,
                newest: windows[0],
                middle: windows[1],
                oldest: windows[2]
            )
        }
        for minute in [15, 30, 60, 90] where elapsed >= Double(minute * 60) && !snapshot.checkpoints.contains(where: { $0.minute == minute }) {
            let values = samples.filter { abs($0.uptime - (runStartUptime + Double(minute * 60))) <= 60 }.map(\.memoryMB)
            let memory = median(values) ?? snapshot.breakdown?.footprintMB ?? baseline
            snapshot.checkpoints.append(DemoMemoryCheckpoint(minute: minute, memoryMB: memory, growthMB: memory - baseline, trend: snapshot.trend))
            persist(event: "\(minute)_MIN", completed: false)
        }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func persist(event: String, completed: Bool) {
        store.save(mode: mode, sessionID: sessionID, completed: completed, event: event, snapshot: snapshot)
        let current = snapshot.breakdown?.footprintMB ?? 0
        Self.logger.info("mode=\(self.mode, privacy: .public) event=\(event, privacy: .public) memory_mb=\(current, format: .fixed(precision: 1)) trend=\(self.snapshot.trend.rawValue, privacy: .public)")
    }
}

final class DemoAppMemoryOverlayView: UIView {
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let summaryLabel = UILabel()
    private let detailButton = UIButton(type: .system)
    private let detailLabel = UILabel()
    private let stack = UIStackView()
    private var snapshot = DemoAppMemorySnapshot()
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.055, green: 0.075, blue: 0.11, alpha: 0.96)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        clipsToBounds = false
        titleLabel.text = "APP 内存监控"
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        closeButton.setTitle("×", for: .normal)
        closeButton.tintColor = .white
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 19, weight: .regular)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        summaryLabel.numberOfLines = 0
        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        summaryLabel.textColor = .white
        detailButton.setTitle("内存明细  ▶", for: .normal)
        detailButton.setTitleColor(.systemCyan, for: .normal)
        detailButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        detailButton.contentHorizontalAlignment = .left
        detailButton.addTarget(self, action: #selector(toggleDetail), for: .touchUpInside)
        detailLabel.numberOfLines = 0
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        detailLabel.isHidden = true
        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        stack.axis = .vertical
        stack.spacing = 5
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(summaryLabel)
        stack.addArrangedSubview(detailButton)
        stack.addArrangedSubview(detailLabel)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(equalToConstant: 268)
        ])
        update(snapshot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: DemoAppMemorySnapshot) {
        self.snapshot = snapshot
        let current = snapshot.breakdown.map { String(format: "%.1f MB", $0.footprintMB) } ?? "-"
        let page = value(snapshot.pageEnterMB)
        let ready = value(snapshot.runtimeReadyMB)
        let start = value(snapshot.runStartMB)
        let points = [15, 30, 60, 90].map { minute -> String in
            guard let point = snapshot.checkpoints.first(where: { $0.minute == minute }) else { return "\(minute)分钟  等待中" }
            return String(format: "%d分钟  %.1f MB  %+.1f MB", minute, point.memoryMB, point.growthMB)
        }.joined(separator: "\n")
        let summary = "当前  \(current)  \(snapshot.trend.rawValue)\n进入  \(page)\n就绪  \(ready)\n启动  \(start)\n\(points)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributedSummary = NSMutableAttributedString(
            string: summary,
            attributes: [
                .foregroundColor: snapshot.trend.color,
                .font: summaryLabel.font as Any,
                .paragraphStyle: paragraph
            ]
        )
        summaryLabel.attributedText = attributedSummary
        if let b = snapshot.breakdown {
            var detail = String(format: "Footprint   %.1f MB\nResident    %.1f MB\nInternal    %.1f MB\nCompressed  %.1f MB\nPurgeable   %.1f MB\nVirtual     %.1f MB\n内存警告    %d", b.footprintMB, b.residentMB, b.internalMB, b.compressedMB, b.purgeableMB, b.virtualMB, snapshot.warningCount)
            if let health = snapshot.runtimeHealth {
                detail += "\n在线气泡    \(health.onlineRows)/200\n离线气泡    \(health.offlineRows)/200\n音频丢帧    \(health.audioDroppedFrames)\n在线状态    \(health.onlineState)\n离线状态    \(health.offlineState)"
            }
            detailLabel.text = detail
        } else { detailLabel.text = "等待采样" }
    }

    private func value(_ value: Double?) -> String { value.map { String(format: "%.1f MB", $0) } ?? "-" }
    @objc private func close() { onClose?() }
    @objc private func toggleDetail() {
        detailLabel.isHidden.toggle()
        detailButton.setTitle(detailLabel.isHidden ? "内存明细  ▶" : "内存明细  ▼", for: .normal)
    }
}

private final class DemoAppMemoryCoordinator {
    let monitor: DemoAppMemoryMonitor
    private weak var controller: UIViewController?
    private let overlay = DemoAppMemoryOverlayView()
    private var topConstraint: NSLayoutConstraint?
    private var leadingConstraint: NSLayoutConstraint?
    private var panStart = CGPoint.zero

    init(controller: UIViewController, mode: String, visibleByDefault: Bool) {
        self.controller = controller
        monitor = DemoAppMemoryMonitor(mode: mode)
        overlay.onClose = { [weak self] in self?.setVisible(false) }
        monitor.onUpdate = { [weak overlay] in overlay?.update($0) }
        controller.view.addSubview(overlay)
        overlay.isHidden = !visibleByDefault
        overlay.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = overlay.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8)
        leadingConstraint = overlay.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([topConstraint!, leadingConstraint!])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        overlay.addGestureRecognizer(pan)
        overlay.isUserInteractionEnabled = true
        monitor.start()
    }

    func setVisible(_ visible: Bool) {
        overlay.isHidden = !visible
        if visible { controller?.view.bringSubviewToFront(overlay) }
        controller?.updateDemoMemoryMonitorMenuState(visible: visible)
    }
    func toggleVisibility() -> Bool {
        let visible = overlay.isHidden
        setVisible(visible)
        return visible
    }
    func stop() { monitor.stop() }
    func setRuntimeHealthProvider(_ provider: @escaping () -> DemoMemoryRuntimeHealth) { monitor.runtimeHealthProvider = provider }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = controller?.view else { return }
        switch gesture.state {
        case .began:
            panStart = CGPoint(x: leadingConstraint?.constant ?? 12, y: topConstraint?.constant ?? 8)
        case .changed, .ended:
            let translation = gesture.translation(in: view)
            let maxX = max(8, view.bounds.width - overlay.bounds.width - 8)
            let maxY = max(8, view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - overlay.bounds.height - 8)
            leadingConstraint?.constant = min(max(8, panStart.x + translation.x), maxX)
            topConstraint?.constant = min(max(8, panStart.y + translation.y), maxY)
        default: break
        }
    }
}

private var demoMemoryCoordinatorKey: UInt8 = 0
private var demoMemoryMenuActionKey: UInt8 = 0

extension UIViewController {
    private var demoMemoryCoordinator: DemoAppMemoryCoordinator? {
        get { objc_getAssociatedObject(self, &demoMemoryCoordinatorKey) as? DemoAppMemoryCoordinator }
        set { objc_setAssociatedObject(self, &demoMemoryCoordinatorKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var demoMemoryMenuAction: UIAction? {
        get { objc_getAssociatedObject(self, &demoMemoryMenuActionKey) as? UIAction }
        set { objc_setAssociatedObject(self, &demoMemoryMenuActionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func installDemoMemoryMonitor(mode: String, visibleByDefault: Bool) {
        guard demoMemoryCoordinator == nil else { return }
        demoMemoryCoordinator = DemoAppMemoryCoordinator(
            controller: self,
            mode: mode,
            visibleByDefault: visibleByDefault
        )
        updateDemoMemoryMonitorMenuState(visible: visibleByDefault)
    }
    func demoMemoryRuntimeReady() { demoMemoryCoordinator?.monitor.markRuntimeReady() }
    func demoMemoryRunStarted() { demoMemoryCoordinator?.monitor.markRunStarted() }
    func demoMemoryRunStopped() { demoMemoryCoordinator?.monitor.markRunStopped() }
    func demoMemoryPageExit() { demoMemoryCoordinator?.stop() }
    func setDemoMemoryRuntimeHealthProvider(_ provider: @escaping () -> DemoMemoryRuntimeHealth) {
        demoMemoryCoordinator?.setRuntimeHealthProvider(provider)
    }
    func demoMemoryMonitorMenuAction(visibleByDefault: Bool) -> UIAction {
        let action = UIAction(
            title: "内存监控",
            image: UIImage(systemName: "memorychip"),
            state: visibleByDefault ? .on : .off
        ) { [weak self] action in
            guard let visible = self?.demoMemoryCoordinator?.toggleVisibility() else { return }
            action.state = visible ? .on : .off
        }
        demoMemoryMenuAction = action
        return action
    }
    func updateDemoMemoryMonitorMenuState(visible: Bool) {
        demoMemoryMenuAction?.state = visible ? .on : .off
    }
}
