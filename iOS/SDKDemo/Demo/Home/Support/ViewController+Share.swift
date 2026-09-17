//
//  ViewController+Share.swift
//  TmkTranslationSDKDemo
//

import UIKit

enum DemoSharePresenter {
    static let errorDomain = "co.timekettle.demo.share"
}

extension UIViewController {
    /// Demo 内统一的轻提示，对齐 Android Toast；不打断当前操作，也不占用 UIAlertController。
    func showDemoToast(_ message: String, duration: TimeInterval = 2.5) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }

        let toastTag = 917_311
        view.viewWithTag(toastTag)?.removeFromSuperview()

        let toast = UIView()
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.tag = toastTag
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        toast.layer.cornerRadius = 10
        toast.clipsToBounds = true
        toast.alpha = 0

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.numberOfLines = 0
        toast.addSubview(label)
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
            toast.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -10)
        ])

        UIView.animate(withDuration: 0.2, animations: {
            toast.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.2, delay: duration, options: [.curveEaseInOut]) {
                toast.alpha = 0
            } completion: { _ in
                toast.removeFromSuperview()
            }
        }
    }

    /// 分享 Demo 诊断/录音文件。
    /// - Note: 在 `My Mac (Designed for iPad)` 上直接分享应用容器内文件容易触发文件提供者解析异常，
    ///   因此统一先复制一份临时快照；在 `My Mac` 上改走文档导出面板，避免系统分享面板直接崩溃。
    func presentShareActivityForFileURLs(_ originalURLs: [URL], sourceView: UIView) {
        do {
            cleanupExpiredShareSnapshotDirectories()
            let exportedURLs = try makeShareSnapshotCopies(from: originalURLs)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                let picker = UIDocumentPickerViewController(forExporting: exportedURLs, asCopy: true)
                if let popover = picker.popoverPresentationController {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceView.bounds
                }
                present(picker, animated: true)
                return
            }
            let activity = UIActivityViewController(activityItems: exportedURLs, applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                self.removeShareSnapshotCopies(exportedURLs)
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            }
            present(activity, animated: true)
        } catch {
            presentShareErrorAlert(error)
        }
    }

    /// 分享 Demo 诊断目录。
    /// - Note: iPhone / iPad 优先使用系统分享面板；`My Mac (Designed for iPad)` 仍走导出面板，
    ///   避免系统分享面板直接处理目录或沙盒 live directory 时出现兼容性问题。
    func presentShareActivityForDirectoryURL(_ originalURL: URL, sourceView: UIView) {
        do {
            cleanupExpiredShareSnapshotDirectories()
            let exportedDirectoryURL = try makeShareSnapshotDirectoryCopy(from: originalURL)
            if ProcessInfo.processInfo.isiOSAppOnMac {
                let picker = UIDocumentPickerViewController(forExporting: [exportedDirectoryURL], asCopy: true)
                if let popover = picker.popoverPresentationController {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceView.bounds
                }
                present(picker, animated: true)
                return
            }
            let activity = UIActivityViewController(activityItems: [exportedDirectoryURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                self.removeShareSnapshotCopies([exportedDirectoryURL])
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
            }
            present(activity, animated: true)
            return
        } catch {
            presentShareErrorAlert(error)
        }
    }

    private func cleanupExpiredShareSnapshotDirectories(maxAge: TimeInterval = 24 * 60 * 60) {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmk_share_exports", isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true else {
                continue
            }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            guard modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeShareSnapshotCopies(from originalURLs: [URL]) throws -> [URL] {
        let fileManager = FileManager.default
        let exportDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tmk_share_exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        var exportedURLs: [URL] = []
        for (index, originalURL) in originalURLs.enumerated() {
            guard fileManager.fileExists(atPath: originalURL.path) else { continue }
            let exportedURL = exportDirectory.appendingPathComponent(uniqueShareFileName(for: originalURL, index: index),
                                                                    isDirectory: false)
            if fileManager.fileExists(atPath: exportedURL.path) {
                try fileManager.removeItem(at: exportedURL)
            }
            try fileManager.copyItem(at: originalURL, to: exportedURL)
            exportedURLs.append(exportedURL)
        }
        guard exportedURLs.isEmpty == false else {
            throw NSError(domain: DemoSharePresenter.errorDomain,
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可分享的文件"])
        }
        return exportedURLs
    }

    private func makeShareSnapshotDirectoryCopy(from originalURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw NSError(domain: DemoSharePresenter.errorDomain,
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可分享的目录"])
        }
        let exportRoot = fileManager.temporaryDirectory
            .appendingPathComponent("tmk_share_exports", isDirectory: true)
        let exportDirectory = exportRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let targetURL = exportDirectory.appendingPathComponent(originalURL.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.copyItem(at: originalURL, to: targetURL)
        return targetURL
    }

    private func uniqueShareFileName(for url: URL, index: Int) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        if index == 0 {
            return ext.isEmpty ? baseName : "\(baseName).\(ext)"
        }
        return ext.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(ext)"
    }

    private func removeShareSnapshotCopies(_ urls: [URL]) {
        guard let directory = urls.first?.deletingLastPathComponent() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func presentShareErrorAlert(_ error: Error) {
        let alert = UIAlertController(title: "分享失败",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}
