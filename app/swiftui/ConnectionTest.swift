// Connection test: latency, jitter and loss between this Mac and a PC, plus the link the
// Mac uses. Many PCs drop pings (Windows' firewall does by default), so each sample is
// the time to open a TCP connection to Sunshine's HTTP port, which streaming needs open:
// the SYN/SYN-ACK round trip, without any app processing in between.

import Foundation
import Network

struct MVConnectionReport: Equatable {
    /// Every attempt in order, in milliseconds: nil when it got no answer.
    let trace: [Double?]
    /// Round trips that succeeded, in milliseconds.
    var samples: [Double] { trace.compactMap { $0 } }
    var attempts: Int { trace.count }
    /// "Ethernet", "Wi-Fi 6 GHz · canal 5 · 160 MHz"…, or nil when nothing answered.
    let link: String?

    enum Verdict {
        case excellent, fair, unstable
    }

    var lossPercent: Double { attempts == 0 ? 0 : Double(attempts - samples.count) * 100 / Double(attempts) }
    var averageMs: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    /// Mean difference between consecutive samples, as RTP measures jitter.
    var jitterMs: Double {
        guard samples.count > 1 else { return 0 }
        let differences = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        return differences.reduce(0, +) / Double(differences.count)
    }

    var verdict: Verdict {
        if samples.isEmpty || lossPercent >= 2 || averageMs >= 30 || jitterMs >= 8 { return .unstable }
        if lossPercent == 0 && averageMs < 10 && jitterMs < 2 { return .excellent }
        return .fair
    }
}

@MainActor
final class MVConnectionTester: ObservableObject {
    @Published private(set) var running = false
    /// The attempts so far, drawn live while the test runs.
    @Published private(set) var trace: [Double?] = []
    @Published private(set) var report: MVConnectionReport?
    private var task: Task<Void, Never>?

    /// About ten seconds: 40 samples, 250 ms apart.
    static let sampleCount = 40
    private static let interval: Duration = .milliseconds(250)

    func start(host: String, port: Int) {
        task?.cancel()
        report = nil
        trace = []
        running = true
        task = Task { [weak self] in
            var wired: Bool?
            for _ in 0..<Self.sampleCount {
                guard !Task.isCancelled else { return }
                let result = await Self.connectTime(host: host, port: port)
                if let (_, isWired) = result {
                    wired = isWired
                }
                self?.trace.append(result?.0)
                try? await Task.sleep(for: Self.interval)
            }
            guard let self, !Task.isCancelled else { return }
            report = MVConnectionReport(trace: trace, link: Self.linkDescription(wired: wired))
            running = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    /// Time to open a TCP connection, and whether it went over Ethernet. Nil after a second
    /// without an answer, which counts as a lost sample.
    private static func connectTime(host: String, port: Int) async -> (Double, Bool)? {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let queue = DispatchQueue(label: "io.github.ciremek.Moonvibe.connection-test")
            let once = MVOnce()
            let start = DispatchTime.now().uptimeNanoseconds

            @Sendable func finish(_ result: (Double, Bool)?) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    finish((ms, connection.currentPath?.usesInterfaceType(.wiredEthernet) ?? false))
                case .failed, .waiting, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
    }

    private static func linkDescription(wired: Bool?) -> String? {
        guard let wired else { return nil }
        if wired { return "Ethernet" }
        return MVWiFi.current()?.description ?? "Wi-Fi"
    }
}

/// Lets exactly one of several racing callbacks through.
private final class MVOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
