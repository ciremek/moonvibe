// Stream history: each stream long enough to report on, kept on this Mac for a recap of the
// year. One JSON object per line in ~/Library/Application Support/Moonvibe/History.jsonl,
// so a stream only ever appends a line and an unreadable line costs that line alone.

import Foundation

/// One stream, as it ended.
struct MVStreamRecord: Codable, Equatable {
    let end: Date
    let computerId: String
    let computerName: String
    let app: String
    let durationSecs: Double
    let width: Int
    let height: Int
    let targetFps: Int
    let codec: String
    let receivedFps: Double
    let renderedFps: Double
    let networkDropPercent: Double
    let jitterDropPercent: Double
    let rttMs: Int
    let rttVarianceMs: Int
    let decodeMs: Double
    let audioCuts: Int
    /// "ethernet" or "wifi", and the Wi-Fi when there was one.
    let link: String
    let wifiBand: String?
    let wifiRssi: Int?
    /// The kind of PC address ("local", "remote", "ipv6", "manual") and its label.
    let routeKind: String?
    let route: String?
    /// "great", "fair" or "rough".
    let verdict: String
    let moonvibeVersion: String

    init(summary: MVStreamSummary, computerName: String, routeKind: String?, end: Date = Date()) {
        let report = summary.report
        self.end = end
        computerId = report.computerId
        self.computerName = computerName
        app = report.app
        durationSecs = report.durationSecs
        width = report.width
        height = report.height
        targetFps = report.targetFps
        codec = report.codec
        receivedFps = report.receivedFps
        renderedFps = report.renderedFps
        networkDropPercent = report.networkDropPercent
        jitterDropPercent = report.jitterDropPercent
        rttMs = report.rttMs
        rttVarianceMs = report.rttVarianceMs
        decodeMs = report.decodeMs
        audioCuts = report.audioCuts
        link = summary.link.wired ? "ethernet" : "wifi"
        wifiBand = summary.link.wifi?.band.rawValue
        wifiRssi = summary.link.wifi?.rssi
        self.routeKind = routeKind
        route = summary.route
        verdict = summary.verdict.rawValue
        moonvibeVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

enum MVStreamHistory {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvibe/History.jsonl")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    static func append(_ record: MVStreamRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            NSLog("Moonvibe: couldn't record the stream in the history: %@", error.localizedDescription)
        }
    }

    /// Every stream recorded, oldest first.
    static func load() -> [MVStreamRecord] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(MVStreamRecord.self, from: Data(line.utf8))
        }
    }
}
