import Foundation

/// 遥测埋点入口（samples 工程不引入 TmkTelemetry SPI，此类为空壳，保留类名供编译通过）。
final class DemoLingCastAspect {
    func setTraceReportingEnabled(_ enabled: Bool) {}
    func onTraceStarted(traceId: String?) {}
}
