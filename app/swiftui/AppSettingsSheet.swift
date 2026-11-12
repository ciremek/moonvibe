// App settings sheet: the tile's look and poster, the quality the app streams at, and the
// Mac apps its streams open and quit.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MVAppSettingsSheet: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    let app: MVApp
    @State private var settings: MVAppSettings
    /// Times each symbol was picked: the picked one bounces.
    @State private var picks: [String: Int] = [:]
    @Namespace private var symbolSelection
    @Namespace private var colorSelection
    @AppStorage(MVTileStyle.key) private var tileStyle = MVTileStyle.covers
    /// A file dragged over the tile preview.
    @State private var dropTargeted = false
    @State private var posterError = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tile icons to pick from: games, genres and a few useful apps.
    private static let symbols = [
        "gamecontroller", "gamecontroller.fill", "desktopcomputer", "display",
        "plus.rectangle.on.rectangle", "app.dashed", "sparkles", "flame.fill",
        "bolt.fill", "crown.fill", "trophy.fill", "shield.fill",
        "target", "scope", "figure.run", "car.fill",
        "airplane", "soccerball", "basketball.fill", "puzzlepiece.fill",
        "dice.fill", "cube.fill", "theatermasks.fill", "wand.and.stars",
        "globe.europe.africa.fill", "map.fill", "music.note", "film.fill",
        "tv.fill", "headphones", "moon.stars.fill", "star.fill",
    ]

    init(model: MVModel, computer: MVComputer, app: MVApp) {
        _model = ObservedObject(wrappedValue: model)
        self.computer = computer
        self.app = app
        _settings = State(initialValue: model.settings(of: app, on: computer))
    }

    private var currentSymbol: String { settings.symbol ?? app.symbolName }

    var body: some View {
        VStack(spacing: 0) {
            MVSheetHeader(title: "Réglages \(mvOf(app.name))")
                .padding(.horizontal, 24)
                .padding(.top, 22)

            Form {
                Section("Apparence") {
                    HStack(alignment: .top, spacing: 20) {
                        MVAppTile(app: app, settings: settings, selected: false, highlighted: dropTargeted,
                                  running: false, enabled: true, posterStyle: tileStyle.posters,
                                  poster: model.poster(of: app, on: computer, settings: settings, style: tileStyle))
                            .frame(width: 120)
                            .accessibilityHidden(true)
                            .dropDestination(for: URL.self) { urls, _ in
                                guard tileStyle.posters, let url = urls.first else { return false }
                                usePoster(at: url)
                                return true
                            } isTargeted: { dropTargeted = tileStyle.posters && $0 }

                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8),
                                      alignment: .leading, spacing: 4) {
                                ForEach(Self.symbols, id: \.self) { symbol in
                                    symbolButton(symbol)
                                }
                            }
                            HStack(spacing: 6) {
                                colorButton(nil)
                                ForEach(MVTileColor.allCases) { colorButton($0) }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if tileStyle.posters {
                        LabeledContent {
                            HStack {
                                if settings.poster != nil {
                                    Button("Retirer") { withAnimation(.mvState) { settings.poster = nil } }
                                }
                                Button("Choisir une image…") { choosePoster() }
                            }
                        } label: {
                            Text("Affiche")
                            if posterError {
                                Text("Cette image ne s'ouvre pas.").foregroundStyle(mvDanger)
                            } else {
                                Text("Pour cette app seulement. Tu peux aussi glisser une image sur la tuile.")
                            }
                        }
                    }
                }

                Section {
                    Picker("Qualité", selection: $settings.preset) {
                        Text("Comme d'habitude").tag(MVPreset?.none)
                        ForEach(MVPreset.builtIn) { preset in
                            Text(preset.label).tag(MVPreset?.some(preset))
                        }
                        if model.customPreset != nil {
                            Text(MVPreset.custom.label).tag(MVPreset?.some(.custom))
                        }
                    }
                } header: {
                    Text("Qualité")
                } footer: {
                    if let preset = settings.preset, let summary = model.summary(for: preset) {
                        Text(summary).monospacedDigit()
                    }
                }

                Section {
                    ForEach(settings.openApps, id: \.self) { path in
                        appRow(path)
                    }
                    Button {
                        chooseApps()
                    } label: {
                        Label("Ajouter une app…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Toggle("Les quitter à la fin du stream", isOn: $settings.quitOpenedApps)
                        .disabled(settings.openApps.isEmpty)
                        .help("Seulement celles que Moonvibe a ouvertes : une app déjà lancée reste ouverte.")
                } header: {
                    Text("Apps à ouvrir sur ce Mac")
                } footer: {
                    Text("Elles s'ouvrent au lancement du stream, en arrière-plan.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Réinitialiser") { withAnimation(.mvState) { settings = MVAppSettings() } }
                    .disabled(settings.isEmpty)
                Spacer()
                Button("Annuler") { model.appSettingsTarget = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    model.setSettings(settings, of: app, on: computer)
                    model.appSettingsTarget = nil
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let selected = symbol == currentSymbol
        return Button {
            withAnimation(.mvGlide) {
                // The guessed icon stays automatic, so it follows a renamed app
                settings.symbol = symbol == app.symbolName ? nil : symbol
            }
            picks[symbol, default: 0] += 1
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .symbolEffect(.bounce, value: picks[symbol] ?? 0)
                .frame(width: 32, height: 32)
                .background {
                    if selected {
                        // The highlight glides from the old icon to the new one
                        selection(in: symbolSelection, id: "symbol") {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(mvAccent.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(mvAccentForeground, lineWidth: 1.5))
                        }
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func colorButton(_ color: MVTileColor?) -> some View {
        let selected = settings.color == color
        return Button {
            withAnimation(.mvGlide) { settings.color = color }
        } label: {
            Circle()
                .fill(color?.color ?? Color.secondary.opacity(0.25))
                .frame(width: 20, height: 20)
                .overlay {
                    if color == nil {
                        Image(systemName: "nosign").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(3)
                .overlay {
                    if selected {
                        selection(in: colorSelection, id: "color") {
                            Circle().strokeBorder(mvAccentForeground, lineWidth: 2)
                        }
                    }
                }
        }
        .buttonStyle(.plain)
        .help(color?.label ?? String(localized: "Sans couleur"))
        .accessibilityLabel(color?.label ?? String(localized: "Sans couleur"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A selection mark that moves between choices, or simply appears with Reduce Motion.
    @ViewBuilder
    private func selection(in namespace: Namespace.ID, id: String, @ViewBuilder mark: () -> some View) -> some View {
        if reduceMotion {
            mark()
        } else {
            mark().matchedGeometryEffect(id: id, in: namespace)
        }
    }

    private func appRow(_ path: String) -> some View {
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(name)
            Spacer()
            Button {
                withAnimation(.mvState) { settings.openApps.removeAll { $0 == path } }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Retirer \(name)")
            .accessibilityLabel("Retirer \(name)")
        }
    }

    private func choosePoster() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Choisir")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        usePoster(at: url)
    }

    /// Copies the image into Moonvibe's posters. The old one stays on disk until the next
    /// launch, in case this sheet is cancelled.
    private func usePoster(at url: URL) {
        do {
            let name = try MVPosters.importImage(at: url, for: computer)
            withAnimation(.mvState) {
                settings.poster = name
                posterError = false
            }
        } catch {
            withAnimation(.mvState) { posterError = true }
        }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Ajouter")
        guard panel.runModal() == .OK else { return }
        withAnimation(.mvState) {
            for url in panel.urls where !settings.openApps.contains(url.path) {
                settings.openApps.append(url.path)
            }
        }
    }
}
