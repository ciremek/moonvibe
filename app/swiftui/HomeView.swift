// Home window: sidebar (search, computers, recents), app grid and launch bar.

import AppKit
import SwiftUI

extension Color {
    /// A color that follows the window's light/dark appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// One neutral tile color: indigo is kept for the selection so it stands out.
private let tileFill = Color(light: NSColor(hex: 0xEEF0F4), dark: NSColor(hex: 0x2B2D34))

/// The accent as text, icons and outlines. mvAccent stays the fill under white text,
/// but lacks contrast against dark backgrounds, hence a lighter shade there.
let mvAccentForeground = Color(light: NSColor(hex: 0x4F5BD5), dark: NSColor(hex: 0x8C96F2))
/// Destructive actions and errors as text and icons, readable in both appearances.
let mvDanger = Color(light: NSColor(hex: 0xB42318), dark: NSColor(hex: 0xFF7B72))
/// Destructive buttons, a fill under white text.
let mvDangerFill = Color(hex: 0xB42318)
/// Online and running dots, always next to a text that says the same.
let mvOnline = Color(hex: 0x28B44B)
/// The running badge, a fill under white text.
let mvRunningFill = Color(hex: 0x1E7E36)

/// "de" before a name, elided before a vowel in French ("d'AZATOTH", "de Steam"). Other
/// languages get the name alone: their translations place it themselves.
func mvOf(_ name: String) -> String {
    guard Bundle.main.preferredLocalizations.first == "fr" else { return name }
    let first = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).first
    return first.map { "aeiou".contains($0) } == true ? "d'\(name)" : "de \(name)"
}

// MARK: - Root

struct MVRootView: View {
    @ObservedObject var model: MVModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            MVSidebar(model: model, searchFocused: $searchFocused)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            MVDetail(model: model)
        }
        .frame(minWidth: 940, minHeight: 560)
        .background {
            // Keyboard shortcuts without visible controls
            Group {
                Button("Rechercher") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Réglages") { model.openSettings?(nil) }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Annuler") { model.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!model.busy || !model.cancellable)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $model.showPairing) {
            MVPairingSheet(model: model)
        }
        .sheet(isPresented: Binding(
            get: { model.computerSettingsId != nil },
            set: { if !$0 { model.computerSettingsId = nil } }
        )) {
            if let computer = model.computers.first(where: { $0.id == model.computerSettingsId }) {
                MVComputerSettingsSheet(model: model, computer: computer)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.appSettingsTarget != nil },
            set: { if !$0 { model.appSettingsTarget = nil } }
        )) {
            if let target = model.appSettingsTarget,
               let computer = model.computers.first(where: { $0.id == target.computerId }),
               let app = computer.apps.first(where: { $0.id == target.appId }) {
                MVAppSettingsSheet(model: model, computer: computer, app: app)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.addAppComputerId != nil },
            set: { if !$0 { model.closeAddApp() } }
        )) {
            if let computer = model.computers.first(where: { $0.id == model.addAppComputerId }) {
                MVAddAppSheet(model: model, computer: computer)
            }
        }
        .alert("Lancement impossible", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct MVSidebar: View {
    @ObservedObject var model: MVModel
    var searchFocused: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List(selection: $model.selectedComputerId) {
            Section("Ordinateurs") {
                ForEach(model.filteredComputers) { computer in
                    MVComputerRow(computer: computer,
                                  waking: model.isWaking(computer),
                                  wakePackets: model.wakePackets[computer.id] ?? 0)
                        .tag(computer.id)
                        .contextMenu {
                            Button("Réglages \(mvOf(computer.name))…") { model.computerSettingsId = computer.id }
                        }
                }
                Button {
                    model.openPairing()
                } label: {
                    Label("Ajouter un ordinateur…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .selectionDisabled()
            }

            if !model.recents.isEmpty {
                Section("Récents") {
                    ForEach(model.recents) { recent in
                        Button {
                            model.launch(recent)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recent.appName).font(.system(size: 13))
                                    Text("\(recent.computerName) · \(recent.dateText)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "clock")
                            }
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()
                        .help("Relancer \(recent.appName) sur \(recent.computerName)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            MVSearchField(text: $model.search, focused: searchFocused)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let version = model.availableUpdate {
                    MVUpdateBadge(version: version) { model.updater?.checkForUpdates() }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                HStack {
                    Button {
                        model.openSettings?(nil)
                    } label: {
                        Label("Réglages", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(.mvState, value: model.availableUpdate)
        }
    }
}

struct MVSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
            if text.isEmpty {
                MVKeycap("⌘K")
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Effacer la recherche")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

struct MVComputerRow: View {
    let computer: MVComputer
    let waking: Bool
    let wakePackets: Int

    private var stateText: String {
        if computer.online { return computer.paired ? String(localized: "En ligne") : String(localized: "Non appairé") }
        return waking ? String(localized: "Réveil en cours…") : String(localized: "Hors ligne")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(computer.name).font(.system(size: 13, weight: .semibold))
                Text(stateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            MVStatusDot(color: computer.online ? mvOnline : waking ? Color.orange : Color.secondary.opacity(0.35),
                        packets: wakePackets,
                        online: computer.online)
        }
        .padding(.vertical, 2)
        .animation(.mvState, value: stateText)
    }
}

extension View {
    /// Soft fade where content scrolls under the toolbar (Liquid Glass, macOS 26+).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

struct MVKeycap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary, lineWidth: 0.5))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

struct MVDetail: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Group {
            if let computer = model.selectedComputer {
                // A view of its own per PC, so switching PCs fades instead of morphing tiles
                MVComputerHome(model: model, computer: computer)
                    .id(computer.id)
                    .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label("Aucun ordinateur", systemImage: "desktopcomputer")
                } description: {
                    Text("Les PC de ton réseau qui font tourner Sunshine ou Apollo apparaissent ici.")
                } actions: {
                    Button("Ajouter un ordinateur…") { model.openPairing() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.selectedComputerId)
    }
}

struct MVComputerHome: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    @FocusState private var gridFocused: Bool
    @State private var confirmDelete = false
    @Namespace private var selectionRing
    @AppStorage(MVTileStyle.key) private var tileStyle = MVTileStyle.covers
    /// The tile being dragged to another place.
    @State private var draggedAppId: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileMinWidth: CGFloat = 140
    private let spacing: CGFloat = 18

    /// Which banner shows, if any: it slides in and out when this changes.
    private var bannerKind: Int {
        if !computer.online || !computer.paired { return 1 }
        return computer.runningApp != nil ? 2 : 0
    }

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: -10)), removal: .opacity)
    }

    var body: some View {
        let apps = model.visibleApps(of: computer)
        let selected = model.selectedApp(of: computer)
        let launchingAfterWake = model.appLaunchingAfterWake(on: computer)

        VStack(spacing: 0) {
            if !computer.online || !computer.paired {
                MVComputerBanner(model: model, computer: computer)
                    .transition(bannerTransition)
            } else if let running = computer.runningApp {
                MVRunningBanner(model: model, computer: computer, app: running)
                    .transition(bannerTransition)
            }

            if let summary = model.lastReport, summary.report.computerId == computer.id {
                MVStreamReportCard(summary: summary) { model.lastReport = nil }
                    .transition(bannerTransition)
            }

            GeometryReader { geometry in
                let columnCount = max(1, Int((geometry.size.width - 48 + spacing) / (tileMinWidth + spacing)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinWidth, maximum: 180), spacing: spacing)],
                                  alignment: .leading, spacing: spacing) {
                            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                                let ref = MVAppRef(computerId: computer.id, appId: app.id)
                                let settings = model.settings(of: app, on: computer)
                                MVAppTile(app: app,
                                          settings: settings,
                                          selected: app.id == selected?.id && gridFocused,
                                          highlighted: app.id == selected?.id,
                                          running: app.id == computer.runningAppId,
                                          enabled: computer.online && computer.paired,
                                          posterStyle: tileStyle.posters,
                                          poster: model.poster(of: app, on: computer, settings: settings, style: tileStyle),
                                          launching: (model.busy && model.launchingApp == ref) || launchingAfterWake?.id == app.id,
                                          launchRequests: model.launchRequests[ref] ?? 0,
                                          bursts: (model.launchStarts[ref] ?? 0) + (model.arrivals[ref] ?? 0),
                                          wakeDelay: mvWaveDelay(index: index, reduceMotion: reduceMotion),
                                          selectionRing: selectionRing)
                                    // Its place while it's dragged: the other tiles make room as it goes
                                    .opacity(draggedAppId == app.id ? 0.35 : 1)
                                    .onDrag {
                                        model.selectedAppId = app.id
                                        draggedAppId = app.id
                                        forgetDragOnRelease()
                                        return NSItemProvider(object: String(app.id) as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: MVTileDropDelegate(
                                        target: app, computer: computer, model: model,
                                        dragged: $draggedAppId, reduceMotion: reduceMotion))
                                    // The launched tile is the selected one: its sparks go over the others
                                    .zIndex(app.id == selected?.id ? 1 : 0)
                                    .onTapGesture(count: 2) { model.requestLaunch(app, on: computer) }
                                    .simultaneousGesture(TapGesture().onEnded {
                                        model.selectedAppId = app.id
                                        gridFocused = true
                                    })
                                    .contextMenu {
                                        Button("Réglages \(mvOf(app.name))…") {
                                            model.appSettingsTarget = MVAppRef(computerId: computer.id, appId: app.id)
                                        }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { model.requestLaunch(app, on: computer) }
                                    .accessibilityAction(named: "Réglages \(mvOf(app.name))") {
                                        model.appSettingsTarget = MVAppRef(computerId: computer.id, appId: app.id)
                                    }
                                    .accessibilityAction(named: "Déplacer vers la gauche") {
                                        if index > 0 { model.moveApp(app.id, to: apps[index - 1].id, on: computer) }
                                    }
                                    .accessibilityAction(named: "Déplacer vers la droite") {
                                        if index + 1 < apps.count { model.moveApp(app.id, to: apps[index + 1].id, on: computer) }
                                    }
                                    .accessibilityHint(computer.online ? "Lance l'app" : "Réveille le PC, puis lance l'app")
                            }
                            if computer.paired, model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                                MVAddAppTile(posterStyle: tileStyle.posters, enabled: computer.online) {
                                    model.openAddApp(on: computer)
                                }
                            }
                        }
                        // Dropped between tiles: the order is already where it was left
                        .onDrop(of: [.text], isTargeted: nil) { _ in
                            let accepted = draggedAppId != nil
                            draggedAppId = nil
                            return accepted
                        }
                        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .mvGlide, value: selected?.id)
                    }
                    .padding(24)
                }
                .softTopScrollEdge()
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: model.moveSelection(by: -1, in: computer)
                    case .right: model.moveSelection(by: 1, in: computer)
                    case .up: model.moveSelection(by: -columnCount, in: computer)
                    case .down: model.moveSelection(by: columnCount, in: computer)
                    @unknown default: break
                    }
                }
            }

            MVLaunchBar(model: model, computer: computer, app: selected)
        }
        .animation(.mvState, value: bannerKind)
        .animation(.mvState, value: model.lastReport)
        .navigationTitle(computer.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                MVQualityButton(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Réveiller") { model.wake(computer) }
                        .disabled(!model.canWake(computer) || model.isWaking(computer))
                    Button("Réglages \(mvOf(computer.name))…") { model.computerSettingsId = computer.id }
                    Button("Ajouter un jeu…") { model.openAddApp(on: computer) }
                        .disabled(!computer.online || !computer.paired)
                    if model.hasCustomAppOrder(computer) {
                        Button("Rétablir l'ordre du PC") {
                            withAnimation(reduceMotion ? nil : .mvGlide) { model.resetAppOrder(of: computer) }
                        }
                    }
                    if let running = computer.runningApp {
                        Button("Quitter \(running.name)…") { model.confirmQuitComputerId = computer.id }
                    }
                    Divider()
                    Button("Supprimer \(computer.name)…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("Plus d'actions")
                .accessibilityLabel("Plus d'actions")
            }
        }
        .background {
            // ⌘1, ⌘2, ⌘3 launch the first apps
            Group {
                ForEach(Array(apps.prefix(3).enumerated()), id: \.element.id) { index, app in
                    Button("Lancer \(app.name)") { model.requestLaunch(app, on: computer) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear { gridFocused = true }
        .confirmationDialog("Supprimer \(computer.name) de Moonvibe ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { model.delete(computer) }
        } message: {
            Text("Il faudra l'appairer à nouveau pour streamer.")
        }
    }
}

extension MVComputerHome {
    /// SwiftUI says nothing when a drag ends away from a drop target: the mouse release does.
    private func forgetDragOnRelease() {
        Task {
            repeat {
                try? await Task.sleep(for: .milliseconds(150))
            } while NSEvent.pressedMouseButtons & 1 != 0
            draggedAppId = nil
        }
    }
}

/// Moves the dragged tile into each tile's place as it passes over it.
private struct MVTileDropDelegate: DropDelegate {
    let target: MVApp
    let computer: MVComputer
    let model: MVModel
    @Binding var dragged: Int?
    let reduceMotion: Bool

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target.id else { return }
        withAnimation(reduceMotion ? nil : .mvGlide) {
            model.moveApp(dragged, to: target.id, on: computer)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

struct MVComputerBanner: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            if computer.online {
                icon("lock")
                message("\(computer.name) n'est pas appairé")
                Spacer(minLength: 8)
                Button("Appairer") { model.openPairing(for: computer) }
                    .controlSize(.large)
                    .fixedSize()
            } else {
                switch model.wakeStates[computer.id] {
                case .waking(let since):
                    MVWakeWaves(packets: model.wakePackets[computer.id] ?? 0)
                    message("Réveil \(mvOf(computer.name))…",
                            model.appLaunchingAfterWake(on: computer).map { app -> LocalizedStringKey in
                                "\(app.name) se lance dès qu'il répond."
                            })
                    Spacer(minLength: 8)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(since))
                        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(reduceMotion ? nil : .snappy, value: seconds)
                    }
                    .accessibilityHidden(true)
                    Button("Annuler") { model.cancelWake(computer) }
                        .controlSize(.large)
                        .fixedSize()
                case .noAnswer:
                    icon("exclamationmark.triangle.fill", color: .orange)
                    message("\(computer.name) ne répond pas",
                            "Vérifie le Wake-on-LAN dans son BIOS et son adresse MAC.")
                    Spacer(minLength: 8)
                    Button("Options de réveil…") { model.computerSettingsId = computer.id }
                        .controlSize(.large)
                        .fixedSize()
                    Button("Réessayer") { model.wake(computer) }
                        .controlSize(.large)
                        .fixedSize()
                case .failed:
                    icon("exclamationmark.triangle.fill", color: mvDanger)
                    message("Réveil impossible", "Vérifie que ce Mac est connecté au réseau.")
                    Spacer(minLength: 8)
                    Button("Réessayer") { model.wake(computer) }
                        .controlSize(.large)
                        .fixedSize()
                case nil:
                    icon("moon.zzz")
                    if model.canWake(computer) {
                        message("\(computer.name) est hors ligne")
                        Spacer(minLength: 8)
                        Button("Réveiller") { model.wake(computer) }
                            .controlSize(.large)
                            .fixedSize()
                    } else {
                        message("\(computer.name) est hors ligne",
                                "Ajoute son adresse MAC pour le réveiller à distance.")
                        Spacer(minLength: 8)
                        Button("Options de réveil…") { model.computerSettingsId = computer.id }
                            .controlSize(.large)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4))
        .animation(.mvState, value: model.wakeStates[computer.id])
    }

    private func icon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 18))
            .foregroundStyle(color)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    // Two lines at most and first claim on the width, like the running banner
    private func message(_ title: LocalizedStringKey, _ detail: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .layoutPriority(1)
        .accessibilityElement(children: .combine)
    }
}

struct MVRunningBanner: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    let app: MVApp

    var body: some View {
        let switchTarget = model.confirmSwitch.flatMap { pending in
            pending.computerId == computer.id ? computer.apps.first { $0.id == pending.appId } : nil
        }
        let confirming = model.confirmQuitComputerId == computer.id || switchTarget != nil

        HStack(spacing: 12) {
            if let target = switchTarget {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(mvDanger)
                    .accessibilityHidden(true)
                // Two lines at most, and first claim on the width: an unbounded height here
                // let the text grow one word per line and push the whole window off screen
                Text("Quitter **\(app.name)** pour lancer \(target.name) ? Le travail non enregistré sera perdu.")
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Button("Annuler") { model.confirmSwitch = nil }
                    .fixedSize()
                Button("Quitter et lancer", role: .destructive) { model.quitAndLaunch(target, on: computer) }
                    .tint(mvDangerFill)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            } else if confirming {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(mvDanger)
                    .accessibilityHidden(true)
                Text("Quitter **\(app.name)** sur \(computer.name) ? Le travail non enregistré sera perdu.")
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Button("Annuler") { model.confirmQuitComputerId = nil }
                    .fixedSize()
                Button("Quitter", role: .destructive) { model.quitRunningApp(on: computer) }
                    .tint(mvDangerFill)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            } else {
                Circle().fill(mvOnline).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("**\(app.name)** tourne sur \(computer.name)")
                    .font(.system(size: 13))
                Spacer()
                Button("Quitter l'app") { model.confirmQuitComputerId = computer.id }
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background((confirming ? mvDanger : mvOnline).opacity(0.08))
        .animation(.easeInOut(duration: 0.15), value: confirming)
    }
}

struct MVAppTile: View {
    let app: MVApp
    let settings: MVAppSettings
    let selected: Bool
    let highlighted: Bool
    let running: Bool
    let enabled: Bool
    /// A 3:4 poster rather than an icon tile, and the cover it shows if any.
    var posterStyle = false
    var poster: MVPosterImage?
    /// Its stream is starting, or waits for the PC to wake up.
    var launching = false
    /// Launch requests so far: the tile presses in and springs back for each new one.
    var launchRequests = 0
    /// Launches started and arrivals so far: each one bursts out of the tile.
    var bursts = 0
    /// When the PC answers, tiles light up one after the other.
    var wakeDelay = 0.0
    /// Shared by the grid's tiles; nil for a tile shown alone.
    var selectionRing: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat { posterStyle ? MVPoster.cornerRadius : 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if posterStyle {
                        posterTile
                    } else {
                        iconTile
                    }
                }
                .overlay {
                    if highlighted {
                        ring
                    }
                }

                if !running, settings.preset != nil || !settings.openApps.isEmpty {
                    // The stream does more than the usual: say so without words
                    HStack(spacing: 4) {
                        if let preset = settings.preset {
                            Image(systemName: "dial.medium").help("Qualité propre : \(preset.label)")
                        }
                        if !settings.openApps.isEmpty {
                            Image(systemName: "macwindow.on.rectangle").help("Ouvre des apps sur ce Mac")
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(posterStyle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(posterStyle ? 6 : 0)
                    .background {
                        // Covers are busy: the icons get a backdrop of their own
                        if posterStyle {
                            Capsule().fill(.regularMaterial)
                        }
                    }
                    .padding(posterStyle ? 8 : 10)
                    .accessibilityHidden(true)
                }
                if running {
                    Text("En cours")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(mvRunningFill))
                        .padding(posterStyle ? 8 : 10)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .offset(y: posterStyle && highlighted && !reduceMotion ? -3 : 0)
            Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }
        .animation(.mvState, value: running)
        .keyframeAnimator(initialValue: 1.0, trigger: launchRequests) { [reduceMotion] tile, scale in
            // Pressed in, then back: a dip in opacity says the same without motion
            let pressed = max(0, (1 - scale) / 0.06)
            tile.scaleEffect(reduceMotion ? 1 : scale)
                .opacity(reduceMotion ? 1 - 0.4 * pressed : 1)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.94, duration: 0.09)
                SpringKeyframe(1.0, duration: 0.4, spring: .snappy(extraBounce: 0.15))
            }
        }
        .overlay {
            // Larger than the tile, so the sparks fly over its neighbors
            MVLaunchBurst(trigger: bursts, color: settings.color?.color ?? mvAccent)
                .frame(width: 440, height: 440)
        }
        // Asleep, the tiles sink back and lose their color
        .saturation(enabled ? 1 : 0)
        .opacity(enabled ? 1 : 0.55)
        .scaleEffect(enabled || reduceMotion ? 1 : 0.97)
        .animation(.smooth(duration: 0.5).delay(wakeDelay), value: enabled)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(settings.color.map { $0.color.opacity(highlighted ? 0.28 : 0.18) }
                  ?? (highlighted ? mvAccent.opacity(0.12) : tileFill))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay { artwork }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The selected poster casts the light of its cover.
    private var posterTile: some View {
        let glow = poster?.glow ?? settings.color?.color ?? mvAccent
        return MVPoster(app: app, settings: settings, poster: poster, launching: launching)
            .shadow(color: glow.opacity(highlighted && enabled ? 0.6 : 0), radius: 18, y: 10)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
    }

    /// The selection outline, which glides from tile to tile.
    @ViewBuilder
    private var ring: some View {
        let outline = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(mvAccentForeground, lineWidth: 3)
            .opacity(selected ? 1 : 0.55)
        if let selectionRing, !reduceMotion {
            outline.matchedGeometryEffect(id: "selection", in: selectionRing)
        } else {
            outline
        }
    }

    private var artwork: some View {
        Image(systemName: settings.symbol ?? app.symbolName)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(settings.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary.opacity(0.75)))
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, options: .repeating, isActive: launching)
    }
}

// MARK: - Toolbar quality capsule

struct MVQualityButton: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Button {
            model.showQuality.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle().fill(mvAccentForeground).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("\(model.preset.label) · \(model.qualitySummary)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.mvState, value: model.qualitySummary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .help("Qualité du stream")
        .popover(isPresented: $model.showQuality, arrowEdge: .bottom) {
            MVQualityPopover(model: model)
        }
    }
}

// MARK: - Launch bar

struct MVLaunchBar: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    let app: MVApp?

    var body: some View {
        HStack(spacing: 14) {
            if let app {
                primaryButton(for: app)
                    .fixedSize()
                    .help("Pendant le stream : ⌃⌥⇧Q pour quitter, ⌃⌥⇧S pour les stats, ⌃⌥⇧Z pour libérer la souris")
            }

            (model.busy && model.cancellable ? Text("\(model.status)  ·  esc pour annuler") : Text(model.status))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
                .animation(.mvState, value: model.status)

            Spacer(minLength: 0)

            // Before a stream, while the Mac is on a link that's likely to hurt it
            if let warning = model.link.warning, !model.busy {
                MVLinkWarningLabel(warning: warning)
                    .transition(.opacity)
            }
        }
        .animation(.mvState, value: model.link.warning)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func primaryButton(for app: MVApp) -> some View {
        if !computer.online, model.canWake(computer), computer.paired {
            // Picking another app while the PC wakes up switches the app it launches
            let waitingForWake = model.appLaunchingAfterWake(on: computer)?.id == app.id
            MVPrimaryButton(title: "Réveiller et lancer \(app.name)",
                            systemImage: "power",
                            busy: waitingForWake || model.busy,
                            disabled: waitingForWake || !model.canWakeAndLaunch(on: computer)) {
                model.requestLaunch(app, on: computer)
            }
        } else {
            let resuming = app.id == computer.runningAppId
            MVPrimaryButton(title: resuming ? "Reprendre \(app.name)" : "Lancer \(app.name)",
                            busy: model.busy,
                            disabled: !model.canLaunch(on: computer)) {
                model.requestLaunch(app, on: computer)
            }
        }
    }
}

struct MVPrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage = "play.fill"
    let busy: Bool
    let disabled: Bool
    let action: () -> Void

    private var label: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title).fontWeight(.semibold)
        }
        .padding(.horizontal, 6)
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        } else {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
        }
    }
}
