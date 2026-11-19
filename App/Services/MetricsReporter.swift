import Foundation
import MetricKit

/// Receives MetricKit's daily metrics and diagnostics (crashes, hangs, CPU, battery, background
/// location time) from iOS. Nothing is sent anywhere: payloads are logged and the most recent ones
/// are kept in Caches/MetricKit as JSON, so they can be inspected on a development device (Xcode →
/// Devices → Download Container) or exported later. MetricKit only reports for users who share
/// analytics with app developers.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsReporter()
    static let maxStoredPayloads = 20

    private let directory: URL?

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("MetricKit")) {
        self.directory = directory
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let background = payload.applicationTimeMetrics?.cumulativeBackgroundLocationTime.converted(to: .minutes).value ?? 0
            let cpu = payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value ?? 0
            let launches = payload.applicationLaunchMetrics?.histogrammedTimeToFirstDraw.totalBucketCount ?? 0
            Log.metrics.info("""
                Daily metrics: \
                CPU \(cpu, format: .fixed(precision: 1), privacy: .public)s, \
                background location \(background, format: .fixed(precision: 1), privacy: .public) min, \
                launches \(launches, privacy: .public)
                """)
            store(payload.jsonRepresentation(), kind: "metrics")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Log.metrics.error("""
                Diagnostics: \(payload.crashDiagnostics?.count ?? 0, privacy: .public) crashes, \
                \(payload.hangDiagnostics?.count ?? 0, privacy: .public) hangs, \
                \(payload.cpuExceptionDiagnostics?.count ?? 0, privacy: .public) CPU exceptions, \
                \(payload.diskWriteExceptionDiagnostics?.count ?? 0, privacy: .public) disk-write exceptions
                """)
            store(payload.jsonRepresentation(), kind: "diagnostics")
        }
    }

    /// Writes the payload and keeps only the newest `maxStoredPayloads` files.
    func store(_ json: Data, kind: String, now: Date = Date()) {
        guard let directory else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(kind)-\(Int(now.timeIntervalSince1970 * 1000)).json"
            try json.write(to: directory.appendingPathComponent(name), options: .atomic)
            let files = try manager.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
            for old in files.dropLast(Self.maxStoredPayloads) {
                try? manager.removeItem(at: directory.appendingPathComponent(old))
            }
        } catch {
            Log.metrics.error("Couldn't store a MetricKit payload: \(error.localizedDescription, privacy: .public)")
        }
    }
}
