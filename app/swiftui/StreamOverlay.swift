// Stream overlays: control bar, stats card, start reminder and the add-a-game guide, shown in borderless
// panels attached above the SDL stream window. They never take keyboard focus, and
// only the control bar receives clicks, so the stream keeps its input.
//
// They run while Qt's event loop is suspended by the stream: SDL's event loop keeps
// the main run loop turning, which drives the timer and SwiftUI updates below.

import AppKit
import SwiftUI

// MARK: - Model

/// Mirrors MVStreamStateCallback and the MV_STREAM_* flags in moonvibeui.h.
public typealias MVStreamStateCallback = @convention(c) () -> Int32
private let streamCaptured: Int32 = 1
private let streamStats: Int32 = 2
private let streamFullscreen: Int32 = 4

struct MVOverlayInfo: Decodable {
    let computer: String
    let app: String
    let targetMbps: Double
}

struct MVStreamStats: Decodable, Equatable {
    let fps: Double
    let width: Int
    let height: Int
    let bitrateMbps: Double
    let rttMs: Int
    let decodeMs: Double
    let dropPercent: Double
}

@MainActor
final class MVOverlayModel: ObservableObject {
    let info: MVOverlayInfo
    @Published var stats: MVStreamStats?
    @Published var captured = false
    @Published var statsVisible = false
    @Published var fullscreen = false

    var sendAction: ((Int) -> Void)?

    init(info: MVOverlayInfo) {
        self.info = info
    }

    /// Mirrors Session::StreamAction.
    func perform(_ action: Int) { sendAction?(action) }
}

// MARK: - Panels

/// A borderless panel that never becomes key, so the stream window keeps the keyboard.
final class MVOverlayPanel: NSPanel {
    let interactive: Bool
    var fadingIn = false
    var fadingOut = false

    init(interactive: Bool) {
        self.interactive = interactive
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = !interactive
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle]
        // Clear glass reads best over video, whatever the system appearance
        appearance = NSAppearance(named: .aqua)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Size of the hosted SwiftUI content, measured by SwiftUI itself. (fittingSize is
    /// zero here, since the hosting view doesn't feed its size into Auto Layout.)
    private(set) var measure: () -> NSSize = { .zero }

    func host<Content: View>(_ view: Content) {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        contentView = controller.view
        measure = { [controller] in
            let size = controller.sizeThatFits(in: NSSize(width: 4000, height: 4000))
            return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        }
    }
}

@MainActor
final class MVStreamOverlay {
    static var current: MVStreamOverlay?

    private static let reminderCountKey = "MoonvibeStreamReminderCount"
    private static let reminderShowCount = 10

    private let streamWindow: NSWindow
    private let state: MVStreamStateCallback
    let model: MVOverlayModel

    private let barPanel = MVOverlayPanel(interactive: true)
    private let statsPanel = MVOverlayPanel(interactive: false)
    private let reminderPanel = MVOverlayPanel(interactive: false)
    private let guidePanel = MVOverlayPanel(interactive: false)
    /// The stream was opened from the add-a-game guide: its steps stay on screen.
    private let showsGuide: Bool
    private var timer: Timer?

    /// Measured size per panel, with the state it was measured for: SwiftUI layout only
    /// runs again when that state changes, not on every tick of the main thread.
    private var measuredSizes: [ObjectIdentifier: (key: String, size: NSSize)] = [:]
    private var barHideDate = Date.distantPast
    private var reminderHideDate = Date.distantPast
    private var wasCaptured = false

    /// Room around each glass shape inside its panel, so the drop shadow fades out
    /// instead of being cut by the panel's edges. Shapes sit `edgeInset` from the stream's edges.
    static let shadowMargin: CGFloat = 28
    private let edgeInset: CGFloat = 12

    init(streamWindow: NSWindow, info: MVOverlayInfo, state: @escaping MVStreamStateCallback) {
        self.streamWindow = streamWindow
        self.state = state
        model = MVOverlayModel(info: info)
        model.sendAction = { action in
            MVWindowController.shared?.model.sendAction?(["action": "streamAction", "value": action])
        }

        barPanel.host(MVControlBar(model: model))
        statsPanel.host(MVStatsCard(model: model))
        reminderPanel.host(MVReminder())
        if let guide = MVWindowController.shared?.model.streamGuide,
           guide.desktopName == info.app, guide.computerName == info.computer {
            guidePanel.host(MVStreamGuideCard(guide: guide))
            showsGuide = true
        } else {
            showsGuide = false
        }

        // Remind the shortcuts on the first streams
        let shown = UserDefaults.standard.integer(forKey: Self.reminderCountKey)
        if shown < Self.reminderShowCount {
            UserDefaults.standard.set(shown + 1, forKey: Self.reminderCountKey)
            reminderHideDate = Date().addingTimeInterval(4)
        }

        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { MVStreamOverlay.current?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func end() {
        timer?.invalidate()
        timer = nil
        for panel in [statsPanel, reminderPanel, guidePanel, barPanel] where panel.parent != nil {
            streamWindow.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func tick() {
        let flags = state()
        let captured = flags & streamCaptured != 0
        model.captured = captured
        model.statsVisible = flags & streamStats != 0
        model.fullscreen = flags & streamFullscreen != 0

        let now = Date()
        let content = streamWindow.contentRect(forFrameRect: streamWindow.frame)

        // Control bar: shown when the free cursor touches the top of the stream, or
        // right after the mouse gets released, then hidden 2 s after it leaves the bar
        if captured {
            barHideDate = .distantPast
        } else {
            if wasCaptured { barHideDate = now.addingTimeInterval(2.5) }
            let mouse = NSEvent.mouseLocation
            let atTopEdge = content.contains(mouse) && mouse.y >= content.maxY - 8
            if atTopEdge || (barPanel.isVisible && barPanel.frame.contains(mouse)) {
                barHideDate = now.addingTimeInterval(2)
            }
        }
        wasCaptured = captured

        // Panels hug their content, so text never truncates and clicks outside the
        // bar's capsule area still reach the stream
        let offset = Self.shadowMargin - edgeInset
        if show(barPanel, now < barHideDate) {
            let bar = size(of: barPanel, for: "\(captured)\(model.fullscreen)\(model.statsVisible)")
            place(barPanel, size: bar, x: content.midX - bar.width / 2, y: content.maxY - bar.height + offset)
        }
        if show(statsPanel, model.statsVisible) {
            let stats = size(of: statsPanel, for: "\(model.stats == nil)")
            place(statsPanel, size: stats, x: content.maxX - stats.width + offset, y: content.maxY - stats.height + offset)
        }
        if show(reminderPanel, now < reminderHideDate) {
            let reminder = size(of: reminderPanel, for: "")
            place(reminderPanel, size: reminder, x: content.midX - reminder.width / 2, y: content.minY - offset)
        }
        if show(guidePanel, showsGuide) {
            let guide = size(of: guidePanel, for: "")
            place(guidePanel, size: guide, x: content.maxX - guide.width + offset, y: content.minY - offset)
        }
    }

    private func size(of panel: MVOverlayPanel, for key: String) -> NSSize {
        if let cached = measuredSizes[ObjectIdentifier(panel)], cached.key == key {
            return cached.size
        }
        let size = panel.measure()
        measuredSizes[ObjectIdentifier(panel)] = (key, size)
        return size
    }

    private func place(_ panel: NSPanel, size: NSSize, x: CGFloat, y: CGFloat) {
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
    }

    /// Fades a panel in or out. Hidden panels are taken off screen entirely rather than
    /// left transparent, so the window server has nothing to composite over the video.
    /// Returns whether the panel is on screen, to be laid out.
    @discardableResult
    private func show(_ panel: MVOverlayPanel, _ visible: Bool) -> Bool {
        if visible {
            if panel.parent == nil {
                panel.alphaValue = 0
                streamWindow.addChildWindow(panel, ordered: .above)
            }
            if panel.alphaValue < 1, !panel.fadingIn {
                panel.fadingIn = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 1
                } completionHandler: {
                    panel.fadingIn = false
                }
            }
            panel.ignoresMouseEvents = !panel.interactive
            return true
        }

        guard panel.parent != nil, !panel.fadingOut else { return panel.parent != nil }
        panel.fadingOut = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.fadingOut = false
                // It may have been asked back while fading out
                guard let self, panel.alphaValue == 0, panel.parent != nil, !panel.fadingIn else { return }
                self.streamWindow.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }
        return true
    }
}

// MARK: - Views

private extension View {
    /// Clear glass capsule on macOS 26, regular material before. The drop shadow keeps
    /// it readable over dark video.
    @ViewBuilder
    func overlayGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        }
    }
}

struct MVControlBar: View {
    @ObservedObject var model: MVOverlayModel

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(mvOnline).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("\(model.info.computer) · \(model.info.app)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)

            Divider().frame(height: 18)

            MVBarButton(title: model.captured ? "Souris capturée" : "Capturer la souris",
                        symbol: "computermouse", active: model.captured, shortcut: "⌃⌥⇧Z") {
                model.perform(1)
            }
            MVBarButton(title: "Stats", symbol: "chart.bar", active: model.statsVisible, shortcut: "⌃⌥⇧S") {
                model.perform(2)
            }
            MVBarButton(title: model.fullscreen ? "Fenêtre" : "Plein écran",
                        symbol: model.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        active: false, shortcut: "⌃⌥⇧X") {
                model.perform(3)
            }

            Divider().frame(height: 18)

            Button {
                model.perform(0)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                    Text("Quitter")
                    MVKeycap("⌃⌥⇧Q")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(mvDanger)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Quitter le stream (⌃⌥⇧Q)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize()
        .overlayGlass(in: Capsule())
        .padding(MVStreamOverlay.shadowMargin)
    }
}

struct MVBarButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let active: Bool
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(active ? Color.primary.opacity(0.10) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(title) + Text(verbatim: " (\(shortcut))"))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct MVStatsCard: View {
    @ObservedObject var model: MVOverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stats").font(.system(size: 13, weight: .bold))
                .accessibilityAddTraits(.isHeader)

            if let stats = model.stats {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(stats.fps.rounded()))")
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                    Text("images/s").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(stats.fps.rounded())) images par seconde")
                VStack(spacing: 0) {
                    MVStatRow(label: "Résolution", value: "\(stats.width)×\(stats.height)")
                    MVStatRow(label: "Débit", value: String(format: "%.0f / %.0f Mb/s", stats.bitrateMbps, model.info.targetMbps))
                    MVStatRow(label: "Latence réseau", value: stats.rttMs > 0 ? "\(stats.rttMs) ms" : "—")
                    MVStatRow(label: "Décodage", value: String(format: "%.1f ms", stats.decodeMs))
                    MVStatRow(label: "Images perdues", value: String(format: "%.1f %%", stats.dropPercent))
                }
            } else {
                Text("Mesure en cours…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }

            HStack(spacing: 4) {
                MVKeycap("⌃⌥⇧S")
                Text("pour masquer").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(width: 230)
        .fixedSize(horizontal: false, vertical: true)
        .overlayGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(MVStreamOverlay.shadowMargin)
    }
}

private struct MVStatRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
        .accessibilityElement(children: .combine)
    }
}

struct MVReminder: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "computermouse")
            Text("Souris capturée")
            Text("·").foregroundStyle(.secondary)
            MVKeycap("⌃⌥⇧Z")
            Text("pour la libérer")
            Text("·").foregroundStyle(.secondary)
            MVKeycap("⌃⌥⇧Q")
            Text("pour quitter")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .fixedSize()
        .overlayGlass(in: Capsule())
        .padding(MVStreamOverlay.shadowMargin)
    }
}

/// The add-a-game steps, in the stream's bottom right corner while it shows the PC's desktop.
struct MVStreamGuideCard: View {
    let guide: MVStreamGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Ajouter \(guide.appName) sur \(guide.computerName)")
            } icon: {
                Image(systemName: "plus.app.fill").foregroundStyle(mvAccent)
            }
            .font(.system(size: 13, weight: .semibold))
            step(1, "Ouvre **localhost:47990** dans un navigateur, puis **Applications**, **Ajouter une application** (*Add New*).")
            step(2, "**Nom de l'application** (*Application Name*) : ⌃⌥⇧V tape « \(guide.appName) ».")
            step(3, "**Commande** (*Command*) : dans le menu Démarrer, clic droit sur le jeu, **Ouvrir l'emplacement du fichier**, puis pareil sur le raccourci qui s'affiche. Le jeu sélectionné, **Ctrl Maj C** copie son chemin : colle-le.")
            step(4, "**Enregistre**, puis ⌃⌥⇧Q pour revenir : Moonvibe s'occupe de l'affiche.")
        }
        .frame(width: 330, alignment: .leading)
        .padding(16)
        .overlayGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(MVStreamOverlay.shadowMargin)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: String(number))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(mvAccent))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - C entry points

@_cdecl("mv_overlay_begin")
public func mvOverlayBegin(_ streamWindow: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>,
                           _ state: MVStreamStateCallback) {
    guard let streamWindow,
          let info = try? JSONDecoder().decode(MVOverlayInfo.self, from: Data(String(cString: json).utf8))
    else { return }
    let window = Unmanaged<NSWindow>.fromOpaque(streamWindow).takeUnretainedValue()
    MainActor.assumeIsolated {
        MVStreamOverlay.current?.end()
        MVStreamOverlay.current = MVStreamOverlay(streamWindow: window, info: info, state: state)
    }
}

@_cdecl("mv_overlay_stats")
public func mvOverlayStats(_ json: UnsafePointer<CChar>) {
    // Called on the decoder thread
    guard let stats = try? JSONDecoder().decode(MVStreamStats.self, from: Data(String(cString: json).utf8)) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            MVStreamOverlay.current?.model.stats = stats
        }
    }
}

@_cdecl("mv_overlay_end")
public func mvOverlayEnd() {
    MainActor.assumeIsolated {
        MVStreamOverlay.current?.end()
        MVStreamOverlay.current = nil
    }
}
