// Stream health: how this Mac reaches the network, a warning on Home before a stream when
// that link is likely to hurt it, and a report once a stream is over with what to change.
// The report's figures come from the engine (Session::StreamReport) and are the ones
// Moonlight logs as "Global video stats", plus the audio cuts it logs as queue overflows.

import AppKit
import CoreWLAN
import Network
import SwiftUI

// MARK: - Link

/// The Wi-Fi this Mac is on: band, channel, width and signal.
struct MVWiFi: Equatable {
    enum Band { case ghz2_4, ghz5, ghz6 }

    let band: Band
    let channel: Int
    let widthMHz: Int?
    /// Signal strength in dBm: -50 is excellent, -75 and below is weak.
    let rssi: Int

    static func current() -> MVWiFi? {
        guard let interface = CWWiFiClient.shared().interface(),
              let channel = interface.wlanChannel() else { return nil }
        let band: Band
        switch channel.channelBand {
        case .band2GHz: band = .ghz2_4
        case .band5GHz: band = .ghz5
        case .band6GHz: band = .ghz6
        default: return nil
        }
        let width: Int?
        switch channel.channelWidth {
        case .width20MHz: width = 20
        case .width40MHz: width = 40
        case .width80MHz: width = 80
        case .width160MHz: width = 160
        default: width = nil
        }
        return MVWiFi(band: band, channel: channel.channelNumber, widthMHz: width, rssi: interface.rssiValue())
    }

    var bandLabel: String {
        switch band {
        case .ghz2_4: return String(localized: "2,4 GHz")
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        }
    }

    /// "Wi-Fi 6 GHz · canal 5 · 160 MHz"
    var description: String {
        let band = bandLabel
        guard let widthMHz else { return String(localized: "Wi-Fi \(band) · canal \(channel)") }
        let width = "\(widthMHz) MHz"
        return String(localized: "Wi-Fi \(band) · canal \(channel) · \(width)")
    }
}

/// How this Mac reaches the network, as far as a stream is concerned.
struct MVLink: Equatable {
    /// Ethernet (or Thunderbolt and the like): nothing to worry about.
    let wired: Bool
    /// Set when the traffic goes over Wi-Fi.
    let wifi: MVWiFi?

    enum Warning {
        case slowBand, weakSignal

        var title: LocalizedStringKey {
            switch self {
            case .slowBand: return "Wi-Fi 2,4 GHz"
            case .weakSignal: return "Signal Wi-Fi faible"
            }
        }

        var advice: LocalizedStringKey {
            switch self {
            case .slowBand: return "Le 2,4 GHz est plus lent et plus encombré : attends-toi à de la latence. Reconnecte-toi en 5 ou 6 GHz, ou branche un câble."
            case .weakSignal: return "Attends-toi à des saccades : rapproche-toi de la box, ou branche un câble."
            }
        }
    }

    /// What is likely to hurt a stream on this link, if anything.
    var warning: Warning? {
        guard !wired, let wifi else { return nil }
        if wifi.band == .ghz2_4 { return .slowBand }
        return wifi.rssi < -75 ? .weakSignal : nil
    }

    var label: String {
        if wired { return "Ethernet" }
        guard let wifi else { return "Wi-Fi" }
        return "Wi-Fi \(wifi.bandLabel)"
    }
}

/// Follows the Mac's link: on network changes, and every 15 seconds since Wi-Fi can
/// switch bands on the same network without the path changing.
@MainActor
final class MVLinkMonitor {
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var refreshTask: Task<Void, Never>?
    private let onChange: (MVLink) -> Void

    init(onChange: @escaping (MVLink) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.path = path
                self?.refresh()
            }
        }
        monitor.start(queue: .main)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.refresh()
            }
        }
    }

    var current: MVLink {
        let wired = path?.usesInterfaceType(.wiredEthernet) ?? false
        let wifi = !wired && (path?.usesInterfaceType(.wifi) ?? true) ? MVWiFi.current() : nil
        return MVLink(wired: wired, wifi: wifi)
    }

    func refresh() {
        onChange(current)
    }
}

// MARK: - Report

/// Session::StreamReport, sent by the host when a stream ends.
struct MVStreamReport: Decodable, Equatable {
    let computerId: String
    let app: String
    /// The PC address the stream went through.
    let address: String
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
}

/// A stream's report with the link the Mac had when it started, and what to make of it.
struct MVStreamSummary: Equatable {
    /// Shorter streams were launched by mistake or quit right away: nothing to report.
    static let minimumDuration: Double = 20

    let report: MVStreamReport
    let link: MVLink
    /// How the stream reached the PC: "Réseau local", "Tailscale", "IP publique"…
    let route: String?
    /// Through the PC's local network, the shortest way.
    let localRoute: Bool

    enum Verdict { case great, fair, rough }

    private var audioCutsPerMinute: Double {
        Double(report.audioCuts) / max(report.durationSecs / 60, 1)
    }

    var verdict: Verdict {
        if report.networkDropPercent >= 2 || report.rttMs >= 50 || audioCutsPerMinute >= 0.5 {
            return .rough
        }
        if report.networkDropPercent < 0.5 && report.rttMs < 15 && report.audioCuts == 0 && link.warning == nil {
            return .great
        }
        return .fair
    }

    /// The one change most likely to help, from the most to the least obvious cause.
    var tip: LocalizedStringKey? {
        switch link.warning {
        case .slowBand: return "Tu étais en Wi-Fi 2,4 GHz, plus lent et plus encombré : reconnecte-toi en 5 ou 6 GHz, ou branche un câble."
        case .weakSignal: return "Le signal Wi-Fi était faible : rapproche-toi de la box, ou branche un câble."
        case nil: break
        }
        if report.audioCuts > 0 && !link.wired {
            return "Le son a coupé : le Wi-Fi a perdu des paquets en rafale. Le câble ou le Wi-Fi 6 GHz règlent ça le plus souvent."
        }
        if report.networkDropPercent >= 1 {
            return "Des images se sont perdues en route : baisse le débit, ou passe au câble."
        }
        if !localRoute, let route, report.rttMs >= 15 {
            return "Le stream est passé par \(route), pas par le réseau local : un peu plus de latence est normal."
        }
        if report.rttMs >= 50 {
            return "La latence était élevée : c'est normal à distance, sinon vérifie ton réseau."
        }
        return nil
    }
}

// MARK: - Views

/// Warning and alert text, readable in both appearances.
private let mvWarningForeground = Color(light: NSColor(srgbRed: 0xB5 / 255, green: 0x47 / 255, blue: 0x08 / 255, alpha: 1),
                                        dark: NSColor(srgbRed: 0xFD / 255, green: 0xB0 / 255, blue: 0x22 / 255, alpha: 1))

/// Home's report on the stream that just ended: a verdict, the figures that matter, and a tip.
struct MVStreamReportCard: View {
    let summary: MVStreamSummary
    let dismiss: () -> Void

    private var report: MVStreamReport { summary.report }

    private var color: Color {
        switch summary.verdict {
        case .great: return mvOnline
        case .fair: return mvWarningForeground
        case .rough: return mvDanger
        }
    }

    private var title: LocalizedStringKey {
        switch summary.verdict {
        case .great: return "Stream impeccable"
        case .fair: return "Stream correct"
        case .rough: return "Stream difficile"
        }
    }

    private var duration: String {
        let seconds = Int(report.durationSecs.rounded())
        if seconds < 3600 {
            return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
        }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MVStatusDot(color: color, packets: 0, online: true)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(report.app) · \(duration)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    metric("Latence", value: "\(report.rttMs) ms")
                    metric("Images/s", value: "\(Int(report.receivedFps.rounded())) / \(report.targetFps)")
                    metric("Pertes", value: (report.networkDropPercent / 100).formatted(.percent.precision(.fractionLength(0...1))))
                    metric("Coupures du son", value: "\(report.audioCuts)")
                    metric("Liaison", value: summary.link.label)
                    if let route = summary.route {
                        metric("Chemin", value: route)
                    }
                }
                if let tip = summary.tip {
                    Label {
                        Text(tip)
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .font(.system(size: 12))
                    .lineLimit(2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fermer le bilan")
            .accessibilityLabel("Fermer le bilan")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private func metric(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }
}

/// The launch bar's warning when the Mac's link is likely to hurt the stream.
struct MVLinkWarningLabel: View {
    let warning: MVLink.Warning

    var body: some View {
        Label(warning.title, systemImage: "wifi.exclamationmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(mvWarningForeground)
            .help(warning.advice)
            .accessibilityHint(warning.advice)
    }
}
