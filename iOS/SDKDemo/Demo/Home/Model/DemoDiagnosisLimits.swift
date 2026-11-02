import Foundation

/// Demo 的输入边界；SDK 的非法值兜底不能替代页面输入校验。
nonisolated enum DemoDiagnosisLimits {
    static let maximumCapacityMB = Int64.max / (1024 * 1024)

    static func positiveInteger(_ text: String, maximum: Int64) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(text), value > 0, value <= maximum else { return nil }
        return value
    }
}
