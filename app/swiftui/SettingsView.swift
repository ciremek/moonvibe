// Settings window: every streaming preference, grouped in sections with search.

import AppKit
import SwiftUI

// MARK: - Sections and search index

enum MVSettingsSection: String, CaseIterable, Identifiable {
    case image, audio, input, gamepad, network, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return String(localized: "Image")
        case .audio: return String(localized: "Audio")
        case .input: return String(localized: "Clavier et souris")
        case .gamepad: return String(localized: "Manette")
        case .network: return String(localized: "Ordinateurs et réseau")
        case .advanced: return String(localized: "Avancé")
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .audio: return "speaker.wave.2.fill"
        case .input: return "keyboard"
        case .gamepad: return "gamecontroller.fill"
        case .network: return "network"
        case .advanced: return "gearshape.2.fill"
        }
    }

    var color: Color {
        switch self {
        case .image: return mvAccent
        case .audio: return Color(hex: 0xD6336C)
        case .input: return Color(hex: 0x6A6A72)
        case .gamepad: return Color(hex: 0x1F8A3B)
        case .network: return Color(hex: 0x2F7DD8)
        case .advanced: return Color(hex: 0x55555C)
        }
    }

    /// Setting titles, for the search field.
    var settingTitles: [String] {
        switch self {
        case .image:
            return [String(localized: "Préréglage"), String(localized: "Résolution"), String(localized: "Images par seconde"), String(localized: "Débit vidéo"), String(localized: "Mode d'affichage"),
                    String(localized: "Synchronisation verticale (V-Sync)"), String(localized: "HDR")]
        case .audio:
            return [String(localized: "Configuration audio"), String(localized: "Couper le son du PC"), String(localized: "Couper le son en arrière-plan")]
        case .input:
            return [String(localized: "Souris pour bureau à distance"), String(localized: "Inverser les clics gauche et droit"),
                    String(localized: "Inverser le défilement"), String(localized: "Capturer les raccourcis système")]
        case .gamepad:
            return [String(localized: "Plusieurs manettes"), String(localized: "Manettes en arrière-plan"), String(localized: "Souris à la manette"), String(localized: "Inverser A/B et X/Y")]
        case .network:
            return [String(localized: "Trouver les PC automatiquement"), String(localized: "Détecter les blocages réseau"), String(localized: "Couper l'AWDL"),
                    String(localized: "Quitter l'app à la fin du stream")]
        case .advanced:
            return [String(localized: "Codec vidéo"), String(localized: "YUV 4:4:4"), String(localized: "Décodeur vidéo"), String(localized: "Moteur de rendu"), String(localized: "Débloquer le débit"),
                    String(localized: "Optimiser les réglages des jeux"), String(localized: "Garder l'écran allumé"), String(localized: "Afficher les stats au démarrage"), String(localized: "Avertissements de connexion"),
                    String(localized: "Avertissements de configuration"), String(localized: "Statut Discord"),
                    String(localized: "Rechercher les mises à jour")]
        }
    }
}

@MainActor
final class MVSettingsState: ObservableObject {
    @Published var section: MVSettingsSection? = .image
    @Published var search = ""
}

// MARK: - Window

@MainActor
final class MVSettingsWindowController: NSObject, NSWindowDelegate {
    static var shared: MVSettingsWindowController?

    let state = MVSettingsState()
    let window: NSWindow

    init(model: MVModel) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Réglages")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        // Same as the main window: SwiftUI's split view sizes must not drive the window's layout pass
        let hostingController = NSHostingController(rootView: MVSettingsView(model: model, state: state).tint(mvAccent))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 720, height: 480)
        if !window.setFrameUsingName("MoonvibeSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("MoonvibeSettingsWindow")
        window.delegate = self
    }

    static func show(model: MVModel, section: MVSettingsSection? = nil) {
        let controller = shared ?? MVSettingsWindowController(model: model)
        shared = controller
        if let section {
            controller.state.section = section
            controller.state.search = ""
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Layout

struct MVSettingsView: View {
    @ObservedObject var model: MVModel
    @ObservedObject var state: MVSettingsState
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $state.section) {
                ForEach(MVSettingsSection.allCases) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        MVSectionIcon(section: section)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                MVSearchField(text: $state.search, focused: $searchFocused)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                if !state.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    MVSettingsSearchResults(state: state)
                } else {
                    switch state.section ?? .image {
                    case .image: MVImageSettings(model: model)
                    case .audio: MVAudioSettings(model: model)
                    case .input: MVInputSettings(model: model)
                    case .gamepad: MVGamepadSettings(model: model)
                    case .network: MVNetworkSettings(model: model)
                    case .advanced: MVAdvancedSettings(model: model)
                    }
                }
            }
            .navigationTitle(state.search.isEmpty ? (state.section ?? .image).title : String(localized: "Recherche"))
        }
        .background {
            Group {
                Button("Rechercher un réglage") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Fermer") { MVSettingsWindowController.shared?.window.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

struct MVSectionIcon: View {
    let section: MVSettingsSection

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(section.color))
    }
}

struct MVSettingsSearchResults: View {
    @ObservedObject var state: MVSettingsState

    private var results: [(MVSettingsSection, String)] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        return MVSettingsSection.allCases.flatMap { section in
            section.settingTitles
                .filter { $0.localizedCaseInsensitiveContains(query) || section.title.localizedCaseInsensitiveContains(query) }
                .map { (section, $0) }
        }
    }

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: state.search)
        } else {
            Form {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    Button {
                        state.section = result.0
                        state.search = ""
                    } label: {
                        HStack(spacing: 10) {
                            MVSectionIcon(section: result.0)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.1)
                                Text(result.0.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Shared rows

extension MVModel {
    /// A binding to one preference, sent to the host when it changes.
    func binding<Value>(_ keyPath: WritableKeyPath<MVPrefs, Value>) -> Binding<Value> {
        Binding(
            get: { self.prefs[keyPath: keyPath] },
            set: { value in self.setPrefs { $0[keyPath: keyPath] = value } }
        )
    }
}

/// A switch with a title, and its explanation in the tooltip.
struct MVSettingToggle: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .help(help ?? "")
    }
}

/// Resolution menu: modes that follow the Mac's display, then fixed sizes.
struct MVResolutionPicker: View {
    @ObservedObject var model: MVModel

    private struct Choice: Hashable {
        let mode: MVResolutionMode
        var width = 0
        var height = 0
    }

    private static let fixedSizes = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]

    private var relativeChoices: [Choice] {
        var modes: [MVResolutionMode] = [.native]
        if model.display.hasNotch { modes.append(.safeArea) }
        modes += [.scaled75, .scaled50]
        return modes.map { Choice(mode: $0) }
    }

    private var fixedChoices: [Choice] {
        var sizes = Self.fixedSizes
        // Keep a custom size set elsewhere (old settings) selectable
        if model.prefs.resolutionMode == .fixed, !sizes.contains(where: { $0 == (model.prefs.width, model.prefs.height) }) {
            sizes.append((model.prefs.width, model.prefs.height))
        }
        return sizes.map { Choice(mode: .fixed, width: $0.0, height: $0.1) }
    }

    private var current: Choice {
        model.prefs.resolutionMode == .fixed
            ? Choice(mode: .fixed, width: model.prefs.width, height: model.prefs.height)
            : Choice(mode: model.prefs.resolutionMode)
    }

    private func label(_ choice: Choice) -> String {
        let (width, height) = model.display.resolution(for: choice.mode, prefs: model.prefs)
        let size = "\(width)×\(height)"
        switch choice.mode {
        case .native: return String(localized: "Natif · \(size)")
        case .safeArea: return String(localized: "Natif sans encoche · \(size)")
        case .scaled75: return String(localized: "75 % · \(size)")
        case .scaled50: return String(localized: "50 % · \(size)")
        case .fixed:
            switch (choice.width, choice.height) {
            case (1280, 720): return "720p · 1280×720"
            case (1920, 1080): return "1080p · 1920×1080"
            case (2560, 1440): return "1440p · 2560×1440"
            case (3840, 2160): return "4K · 3840×2160"
            default: return String(localized: "Perso · \(choice.width)×\(choice.height)")
            }
        }
    }

    var body: some View {
        Picker("Résolution", selection: Binding(
            get: { current },
            set: { choice in
                model.setPrefs {
                    $0.resolutionMode = choice.mode
                    if choice.mode == .fixed {
                        $0.width = choice.width
                        $0.height = choice.height
                    }
                }
            }
        )) {
            Section("Selon ton écran") {
                ForEach(relativeChoices, id: \.self) { Text(label($0)).tag($0) }
            }
            Section("Fixe") {
                ForEach(fixedChoices, id: \.self) { Text(label($0)).tag($0) }
            }
        }
    }
}

/// Frame rates the Mac's display can show.
struct MVFpsPicker: View {
    @ObservedObject var model: MVModel

    private var options: [Int] {
        let options = [30, 60, 90, 120].filter { $0 <= model.display.maxFps }
        return options.contains(model.prefs.fps) ? options : (options + [model.prefs.fps]).sorted()
    }

    var body: some View {
        Picker("Images par seconde", selection: Binding(get: { model.prefs.fps }, set: { model.setFps($0) })) {
            ForEach(options, id: \.self) { Text("\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

struct MVBitrateSlider: View {
    @ObservedObject var model: MVModel

    var body: some View {
        HStack {
            Slider(value: Binding(
                get: { Double(model.prefs.bitrateKbps) / 1000 },
                set: { value in model.setPrefs { $0.bitrateKbps = Int(value.rounded()) * 1000 } }
            // No step: a stepped slider draws one tick mark per Mb/s. The setter rounds instead.
            ), in: 5...Double(model.prefs.maxBitrateMbps))
            .labelsHidden()
            .accessibilityLabel("Débit vidéo")
            .accessibilityValue("\(model.prefs.bitrateKbps / 1000) mégabits par seconde")
            Text("\(model.prefs.bitrateKbps / 1000) Mb/s")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
    }
}

// MARK: - Sections

struct MVImageSettings: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Form {
            Section {
                Picker("Préréglage", selection: Binding(
                    get: { model.preset },
                    set: { model.apply($0) }
                )) {
                    ForEach(MVPreset.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.preset.help)
            } header: {
                Text("Préréglage")
            }

            Section("Résolution et fluidité") {
                MVResolutionPicker(model: model)
                LabeledContent("Images par seconde") {
                    MVFpsPicker(model: model).labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Débit vidéo")
                    MVBitrateSlider(model: model)
                }
                .help("Plus haut, l'image est plus nette. Plus bas, elle saccade moins sur un réseau chargé.")
            }

            Section("Affichage") {
                Picker("Mode", selection: model.binding(\.windowMode)) {
                    ForEach(MVWindowMode.allCases) { Text($0.label).tag($0) }
                }
                MVSettingToggle(title: "Synchronisation verticale (V-Sync)",
                                help: "Supprime les déchirures d'image, au prix d'un peu de latence.",
                                isOn: model.binding(\.vsync))
                MVSettingToggle(title: "HDR",
                                help: "Nécessite un écran HDR et un codec HEVC ou AV1.",
                                isOn: model.binding(\.hdr))
            }
        }
        .formStyle(.grouped)
    }
}

struct MVAudioSettings: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Form {
            Section {
                Picker("Configuration audio", selection: model.binding(\.audioConfig)) {
                    Text("Stéréo").tag(0)
                    Text("Surround 5.1").tag(1)
                    Text("Surround 7.1").tag(2)
                }
                MVSettingToggle(title: "Couper le son du PC", isOn: model.binding(\.muteHost))
                MVSettingToggle(title: "Couper le son en arrière-plan", isOn: model.binding(\.muteOnFocusLoss))
            }
        }
        .formStyle(.grouped)
    }
}

struct MVInputSettings: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Form {
            Section("Souris") {
                MVSettingToggle(title: "Souris pour bureau à distance",
                                help: "Le curseur suit exactement ta souris. À éviter dans les jeux de tir.",
                                isOn: model.binding(\.absoluteMouse))
                MVSettingToggle(title: "Inverser les clics gauche et droit", isOn: model.binding(\.swapMouseButtons))
                MVSettingToggle(title: "Inverser le défilement", isOn: model.binding(\.reverseScroll))
            }
            Section("Clavier") {
                Picker("Capturer les raccourcis système", selection: model.binding(\.captureSysKeys)) {
                    Text("Jamais").tag(0)
                    Text("En plein écran").tag(1)
                    Text("Toujours").tag(2)
                }
                .help("Envoie au PC les raccourcis comme ⌘⇥ ou ⌘Espace au lieu de les laisser à macOS.")
            }
        }
        .formStyle(.grouped)
    }
}

struct MVGamepadSettings: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Form {
            Section("Manettes") {
                MVSettingToggle(title: "Plusieurs manettes",
                                help: "Chaque manette est un joueur. Coupé, elles pilotent toutes le joueur 1.",
                                isOn: model.binding(\.multiController))
                MVSettingToggle(title: "Manettes en arrière-plan", isOn: model.binding(\.backgroundGamepad))
                MVSettingToggle(title: "Souris à la manette",
                                help: "Maintiens Start pour piloter la souris du PC avec la manette.",
                                isOn: model.binding(\.gamepadMouse))
                MVSettingToggle(title: "Inverser A/B et X/Y",
                                help: "Pour les manettes Nintendo.",
                                isOn: model.binding(\.swapFaceButtons))
            }
        }
        .formStyle(.grouped)
    }
}

struct MVNetworkSettings: View {
    @ObservedObject var model: MVModel

    var body: some View {
        Form {
            Section("Ordinateurs") {
                MVSettingToggle(title: "Trouver les PC automatiquement", isOn: model.binding(\.mdns))
                MVSettingToggle(title: "Quitter l'app à la fin du stream", isOn: model.binding(\.quitAppAfter))
            }
            Section("Réseau") {
                MVSettingToggle(title: "Couper l'AWDL",
                                help: "Évite les pics de latence Wi-Fi d'AirDrop pendant le stream.",
                                isOn: model.binding(\.disableAwdl))
                MVSettingToggle(title: "Détecter les blocages réseau",
                                help: "Prévient quand ton réseau bloque les ports du stream.",
                                isOn: model.binding(\.detectNetworkBlocking))
            }
        }
        .formStyle(.grouped)
    }
}

struct MVAdvancedSettings: View {
    @ObservedObject var model: MVModel
    /// Sparkle's own key, so the switch follows it
    @AppStorage("SUEnableAutomaticChecks") private var checkForUpdates = true
    @AppStorage(MVQuickLaunch.menuBarIconKey) private var menuBarIcon = false
    @AppStorage(MVQuickLaunch.hideDockIconKey) private var hideDockIcon = false
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    var body: some View {
        Form {
            Section("Vidéo") {
                Picker("Codec vidéo", selection: Binding(
                    // The deprecated "HEVC HDR" value behaves like HEVC
                    get: { model.prefs.videoCodec == 3 ? 2 : model.prefs.videoCodec },
                    set: { value in model.setPrefs { $0.videoCodec = value } }
                )) {
                    Text("Automatique").tag(0)
                    Text("H.264").tag(1)
                    Text("HEVC").tag(2)
                    Text("AV1").tag(4)
                }
                MVSettingToggle(title: "YUV 4:4:4",
                                help: "Couleurs plus fines pour le texte, si le PC et ce Mac le gèrent.",
                                isOn: model.binding(\.yuv444))
                Picker("Décodeur vidéo", selection: model.binding(\.videoDecoder)) {
                    Text("Automatique").tag(0)
                    Text("Matériel").tag(1)
                    Text("Logiciel").tag(2)
                }
                Picker("Moteur de rendu", selection: model.binding(\.renderer)) {
                    Text("Automatique").tag(0)
                    Text("Vulkan").tag(1)
                    Text("Metal").tag(2)
                    Text("AVSampleBufferDisplayLayer").tag(3)
                }
                // Only this renderer paces frames on macOS: Vulkan and Metal ignore the option
                if model.prefs.renderer == 3 {
                    MVSettingToggle(title: "Frame pacing",
                                    help: model.prefs.vsync ? "Lisse l'affichage quand les images arrivent irrégulièrement."
                                                            : "Nécessite la V-Sync.",
                                    isOn: model.binding(\.framePacing))
                        .disabled(!model.prefs.vsync)
                }
                MVSettingToggle(title: "Débloquer le débit",
                                help: "Monte le débit jusqu'à 500 Mb/s au lieu de 150.",
                                isOn: model.binding(\.unlockBitrate))
                MVSettingToggle(title: "Optimiser les réglages des jeux",
                                help: "Pour GeForce Experience uniquement.",
                                isOn: model.binding(\.gameOptimizations))
            }
            Section("Pendant le stream") {
                MVSettingToggle(title: "Garder l'écran allumé", isOn: model.binding(\.keepAwake))
                MVSettingToggle(title: "Afficher les stats au démarrage", isOn: model.binding(\.showStats))
                MVSettingToggle(title: "Avertissements de connexion", isOn: model.binding(\.connectionWarnings))
                MVSettingToggle(title: "Avertissements de configuration",
                                help: "Signale les réglages que ce Mac ou le PC ne gèrent pas.",
                                isOn: model.binding(\.configurationWarnings))
                MVSettingToggle(title: "Statut Discord",
                                help: "Affiche le jeu en cours sur ton profil Discord.",
                                isOn: model.binding(\.richPresence))
                // macOS turns Game Mode on by itself, and only its own switch turns it off
                LabeledContent {
                    Link("En savoir plus", destination: URL(string: "https://support.apple.com/105118")!)
                } label: {
                    Text("Mode Jeu de macOS")
                    Text(gameModeTip)
                }
            }
            Section("Moonvibe") {
                MVSettingToggle(title: "Icône dans la barre des menus",
                                help: "Tes jeux récents en un clic, comme dans le menu de l'icône du Dock.",
                                isOn: $menuBarIcon)
                    .onChange(of: menuBarIcon) { model.quickLaunch?.updateMenuBarIcon() }
                MVSettingToggle(title: "Masquer l'icône du Dock",
                                help: "Moonvibe vit dans la barre des menus. L'icône revient le temps d'un stream, pour ⌘⇥.",
                                isOn: $hideDockIcon)
                    .onChange(of: hideDockIcon) { model.quickLaunch?.updateDockIcon() }
                    .disabled(!menuBarIcon)
                MVSettingToggle(title: "Rechercher les mises à jour",
                                help: "Vérifie deux fois par jour si une nouvelle version est sortie.",
                                isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { model.updater?.automaticallyChecks = checkForUpdates }
                LabeledContent {
                    Button("Rechercher maintenant…") { model.updater?.checkForUpdates() }
                } label: {
                    Text("Moonvibe \(version)")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Where macOS keeps its Game Mode switch, which remembers the choice for Moonvibe.
    private var gameModeTip: LocalizedStringKey {
        if #available(macOS 26.0, *) {
            return "Il aide les manettes et AirPods Bluetooth, mais laisse moins de ressources aux apps en arrière-plan, comme VirtualHere. Si la souris ou le son accrochent, coupe-le pendant un stream : ⌃⌥⇧Z, l'icône manette de la barre des menus, Réglages, Mode Jeu. macOS s'en souvient."
        }
        return "Il aide les manettes et AirPods Bluetooth, mais laisse moins de ressources aux apps en arrière-plan, comme VirtualHere. Si la souris ou le son accrochent, coupe-le pendant un stream : ⌃⌥⇧Z, puis le menu Mode Jeu de la barre des menus, Désactiver le mode Jeu. macOS s'en souvient."
    }
}
