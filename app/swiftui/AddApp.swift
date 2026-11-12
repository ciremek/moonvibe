// "Add a game" guide: Moonlight's protocol can only read a PC's apps, so the game gets added
// in Sunshine's or Apollo's web interface. Moonvibe finds a Steam game and its poster,
// walks through the form with each value ready to copy, then waits for the game to show up
// on the PC and gives it its poster.

import AppKit
import SwiftUI

// MARK: - Steam

/// A game from Steam's store search.
struct MVSteamGame: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let type: String
    let tinyImage: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case tinyImage = "tiny_image"
    }

    /// Launches the game through Steam, as a detached command in Sunshine.
    var command: String { "steam://rungameid/\(id)" }
    var capsuleURL: URL? { tinyImage.flatMap(URL.init(string:)) }
}

enum MVSteam {
    /// Steam's public store search: only the search terms leave this Mac.
    static func search(_ term: String) async throws -> [MVSteamGame] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "l", value: Bundle.main.preferredLocalizations.first == "fr" ? "french" : "english"),
            // Without a store country, Steam finds nothing for most games. A fixed one
            // keeps the Mac's region to itself: only names and ids are used here.
            URLQueryItem(name: "cc", value: "US"),
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Results: Decodable { let items: [MVSteamGame] }
        return try JSONDecoder().decode(Results.self, from: data).items.filter { $0.type == "app" }
    }

    /// The game's poster in the Steam library (1200×1800, else 600×900), if it has one.
    static func poster(of game: MVSteamGame) async -> Data? {
        for file in ["library_600x900_2x.jpg", "library_600x900.jpg"] {
            guard let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(game.id)/\(file)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            return data
        }
        return nil
    }
}

// MARK: - Launchers

/// Games started through their own launcher, with the command of a default install.
struct MVLauncherPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let command: String
    let symbol: String
    let color: MVTileColor

    static let all = [
        MVLauncherPreset(id: "lol", name: "League of Legends",
                         command: #""C:\Riot Games\Riot Client\RiotClientServices.exe" --launch-product=league_of_legends --launch-patchline=live"#,
                         symbol: "crown.fill", color: .orange),
        MVLauncherPreset(id: "valorant", name: "Valorant",
                         command: #""C:\Riot Games\Riot Client\RiotClientServices.exe" --launch-product=valorant --launch-patchline=live"#,
                         symbol: "scope", color: .red),
        MVLauncherPreset(id: "fortnite", name: "Fortnite",
                         command: "com.epicgames.launcher://apps/Fortnite?action=launch&silent=true",
                         symbol: "bolt.fill", color: .purple),
    ]
}

// MARK: - Sheet

struct MVAddAppSheet: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer

    private enum Step { case game, pc, done }
    private enum Kind: Hashable { case steam, program }

    @State private var step: Step
    @State private var kind: Kind = .steam
    @State private var name: String
    @State private var command = ""
    @State private var settings: MVAppSettings
    @State private var knownAppIds: Set<Int>
    @State private var query = ""
    @State private var results: [MVSteamGame] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var steamGame: MVSteamGame?
    @State private var preset: MVLauncherPreset?
    @State private var loadingPoster = false
    @State private var dropTargeted = false
    @AppStorage(MVTileStyle.key) private var tileStyle = MVTileStyle.covers
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: MVModel, computer: MVComputer) {
        _model = ObservedObject(wrappedValue: model)
        self.computer = computer
        // Opened again while it waits: back to the steps on the PC
        if let pending = model.pendingApp, pending.computerId == computer.id {
            _step = State(initialValue: pending.foundAppId == nil ? .pc : .done)
            _name = State(initialValue: pending.name)
            _settings = State(initialValue: pending.settings)
            _knownAppIds = State(initialValue: pending.knownAppIds)
        } else {
            _step = State(initialValue: .game)
            _name = State(initialValue: "")
            _settings = State(initialValue: MVAppSettings())
            _knownAppIds = State(initialValue: Set(computer.apps.map(\.id)))
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedCommand: String { command.trimmingCharacters(in: .whitespaces) }

    /// A Steam or launcher link, which Sunshine starts as a detached command.
    private var detachedCommand: String? {
        switch kind {
        case .steam: return steamGame?.command
        case .program: return preset.flatMap { $0.command == trimmedCommand ? $0.command : nil }
        }
    }

    /// The desktop app, to add the game from the PC itself.
    private var desktopApp: MVApp? {
        computer.apps.first { $0.symbolName == "display" }
    }

    /// The game as its tile will look, before it exists on the PC.
    private var previewApp: MVApp {
        MVApp(id: -1, name: trimmedName.isEmpty ? String(localized: "Nouveau jeu") : trimmedName)
    }

    private var foundApp: MVApp? {
        guard let id = model.pendingApp?.foundAppId else { return nil }
        return computer.apps.first { $0.id == id }
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity)
    }

    var body: some View {
        Group {
            switch step {
            case .game: gameStep.transition(stepTransition)
            case .pc: pcStep.transition(stepTransition)
            case .done: doneStep.transition(stepTransition)
            }
        }
        .padding(24)
        .frame(width: 620)
        .animation(.mvState, value: step)
        .onChange(of: model.pendingApp?.foundAppId) { _, found in
            if found != nil { step = .done }
        }
    }

    // MARK: Step 1: the game

    private var gameStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            MVSheetHeader(title: "Ajouter un jeu", subtitle: "Sur \(computer.name), avec Sunshine ou Apollo.")

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Type", selection: $kind) {
                        Text("Jeu Steam").tag(Kind.steam)
                        Text("Autre programme").tag(Kind.program)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if kind == .steam {
                        steamSearch
                    }
                    if kind == .program {
                        Menu {
                            ForEach(MVLauncherPreset.all) { preset in
                                Button(preset.name) { apply(preset) }
                            }
                        } label: {
                            Label("Lanceurs connus", systemImage: "wand.and.stars")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Remplit le nom et la commande, pour une installation par défaut.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nom").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        TextField("Nom du jeu", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    if kind == .program {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Commande (facultatif)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            TextField(text: $command, prompt: Text(verbatim: "C:\\Program Files\\…\\jeu.exe")) {
                                Text("Commande")
                            }
                            .textFieldStyle(.roundedBorder)
                            Text("Le programme à lancer sur le PC. Si tu ne connais pas son chemin, Moonvibe t'aide à le trouver depuis le PC.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    preview
                    if tileStyle.posters {
                        HStack(spacing: 6) {
                            if settings.poster != nil {
                                Button("Retirer") { withAnimation(.mvState) { settings.poster = nil } }
                            }
                            Button("Image…") { choosePoster() }
                                .help("Choisir une image pour l'affiche")
                        }
                        .controlSize(.small)
                    }
                }
                .frame(width: 150)
            }

            HStack {
                Spacer()
                Button("Annuler") { model.closeAddApp() }
                    .keyboardShortcut(.cancelAction)
                Button("Continuer") {
                    let command = detachedCommand ?? (kind == .program && !trimmedCommand.isEmpty ? trimmedCommand : nil)
                    model.watchForApp(named: trimmedName, settings: settings, command: command,
                                      detached: detachedCommand != nil, knownAppIds: knownAppIds, on: computer)
                    step = .pc
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || (kind == .steam && steamGame == nil))
            }
        }
    }

    private var preview: some View {
        MVAppTile(app: previewApp, settings: settings, selected: false, highlighted: dropTargeted,
                  running: false, enabled: true, posterStyle: tileStyle.posters,
                  poster: model.poster(of: previewApp, on: computer, settings: settings, style: tileStyle))
            .overlay {
                if loadingPoster {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityHidden(true)
            .dropDestination(for: URL.self) { urls, _ in
                guard tileStyle.posters, let url = urls.first else { return false }
                usePoster { try MVPosters.importImage(at: url, for: computer) }
                return true
            } isTargeted: { dropTargeted = tileStyle.posters && $0 }
    }

    private var steamSearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Rechercher sur Steam", text: $query)
                    .textFieldStyle(.plain)
                if searching {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { game in
                        steamRow(game)
                    }
                }
            }
            .frame(height: 196)
            .overlay {
                if results.isEmpty && !searching {
                    Group {
                        if searchFailed {
                            Text("Steam ne répond pas.")
                        } else if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                            Text("Aucun jeu trouvé.")
                        } else {
                            Text("L'affiche et la commande viennent de Steam.")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                }
            }
        }
        .task(id: query) { await search() }
    }

    private func steamRow(_ game: MVSteamGame) -> some View {
        let selected = game == steamGame
        return Button {
            pick(game)
        } label: {
            HStack(spacing: 10) {
                AsyncImage(url: game.capsuleURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 80, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(game.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(mvAccentForeground)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? mvAccent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            results = []
            searchFailed = false
            return
        }
        // Typing goes on: wait for a pause
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await MVSteam.search(term)
            guard !Task.isCancelled else { return }
            withAnimation(.mvState) {
                results = found
                searchFailed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchFailed = true
        }
    }

    private func pick(_ game: MVSteamGame) {
        withAnimation(.mvGlide) {
            steamGame = game
            name = game.name
        }
        loadingPoster = true
        Task {
            defer { if steamGame == game { loadingPoster = false } }
            guard let data = await MVSteam.poster(of: game), steamGame == game else { return }
            usePoster { try MVPosters.importImage(data: data, for: computer) }
        }
    }

    private func apply(_ preset: MVLauncherPreset) {
        withAnimation(.mvState) {
            self.preset = preset
            name = preset.name
            command = preset.command
            settings.symbol = preset.symbol
            settings.color = preset.color
        }
    }

    private func choosePoster() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Choisir")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        usePoster { try MVPosters.importImage(at: url, for: computer) }
    }

    private func usePoster(_ importImage: () throws -> String) {
        guard let name = try? importImage() else {
            NSSound.beep()
            return
        }
        withAnimation(.mvState) { settings.poster = name }
    }

    // MARK: Step 2: on the PC

    /// Sunshine's and Apollo's web interface: one port above the streaming one.
    private var webInterfaceURL: URL? {
        guard let address = computer.addresses.first(where: \.active)
                ?? computer.addresses.first(where: { $0.kind == "local" })
                ?? computer.addresses.first else { return nil }
        let host = address.address.contains(":") ? "[\(address.address)]" : address.address
        return URL(string: "https://\(host):\(address.port + 1)")
    }

    private var pcStep: some View {
        let pending = model.pendingApp
        return VStack(alignment: .leading, spacing: 18) {
            MVSheetHeader(title: "Ajoute \(trimmedName) dans Sunshine",
                          subtitle: "Ou dans Apollo : c'est le même formulaire. Moonvibe repère le jeu dès que tu l'enregistres.")

            if pending?.command == nil, let desktop = desktopApp {
                fromPCCard(desktop)
            }

            VStack(alignment: .leading, spacing: 16) {
                instruction(1, "Ouvre l'interface web de Sunshine.") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = webInterfaceURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Ouvrir sur ce Mac", systemImage: "safari")
                            }
                        }
                        Text("Ou sur le PC : **localhost:47990**. Le navigateur se méfie de son certificat : normal, Sunshine fabrique le sien.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                instruction(2, "Va dans **Applications**, puis **Ajouter une application** (*Add New*).") { EmptyView() }
                instruction(3, "**Nom de l'application** (*Application Name*) :") {
                    MVCopyField(text: trimmedName)
                }
                if let command = pending?.command, pending?.detached == true {
                    instruction(4, "**Commandes détachées** (*Detached Commands*) : ajoute celle-ci.") {
                        MVCopyField(text: command)
                    }
                } else if let command = pending?.command {
                    instruction(4, "**Commande** (*Command*) :") {
                        MVCopyField(text: command)
                    }
                } else {
                    instruction(4, "**Commande** (*Command*) : le chemin du programme sur le PC.") { EmptyView() }
                }
                instruction(5, "Enregistre.") { EmptyView() }
            }

            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("En attente de \(trimmedName) sur \(computer.name)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
            .help("Tu peux fermer : Moonvibe habille le jeu dès qu'il apparaît.")

            HStack {
                Button("Retour") {
                    model.stopWatchingForApp()
                    step = .game
                }
                Spacer()
                Button("Fermer") { model.closeAddApp() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .task {
            // Ask the PC for its apps every few seconds rather than every 30
            while !Task.isCancelled {
                model.refreshApps(on: computer)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The game's path is on the PC: do it all from its desktop, the steps over the stream.
    private func fromPCCard(_ desktop: MVApp) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 20))
                .foregroundStyle(mvAccentForeground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Le chemin du jeu est sur le PC ?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Fais tout depuis son bureau : Moonvibe l'ouvre en stream avec ces étapes à l'écran, et ⌃⌥⇧V y tape le nom du jeu.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Ouvrir le bureau") { model.addFromPC(using: desktop, on: computer) }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canLaunch(on: computer))
                .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(mvAccent.opacity(0.1)))
    }

    /// A numbered step with what it needs below, like a copyable value.
    private func instruction(_ number: Int, _ text: LocalizedStringKey,
                             @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MVPairingInstruction(number: number, text: text)
            content()
                .padding(.leading, 26)
        }
    }

    // MARK: Step 3: done

    private var doneStep: some View {
        MVAddAppDone(model: model, computer: computer, app: foundApp ?? previewApp, settings: settings,
                     tileStyle: tileStyle)
    }
}

/// The game's tile lands, bursting out, then the buttons rise in.
private struct MVAddAppDone: View {
    @ObservedObject var model: MVModel
    let computer: MVComputer
    let app: MVApp
    let settings: MVAppSettings
    let tileStyle: MVTileStyle
    @State private var celebrated = false
    @State private var bursts = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            MVAppTile(app: app, settings: settings, selected: false, highlighted: false,
                      running: false, enabled: true, posterStyle: tileStyle.posters,
                      poster: model.poster(of: app, on: computer, settings: settings, style: tileStyle),
                      bursts: bursts)
                .frame(width: 150)
                .scaleEffect(celebrated || reduceMotion ? 1 : 0.85)
                .animation(.snappy(extraBounce: 0.2), value: celebrated)
                .accessibilityHidden(true)

            Group {
                Text("\(app.name) est sur \(computer.name)")
                    .font(.system(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Terminer") { model.closeAddApp() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                    MVPrimaryButton(title: "Lancer \(app.name)", busy: false,
                                    disabled: !model.canLaunch(on: computer)) {
                        model.closeAddApp()
                        model.requestLaunch(app, on: computer)
                    }
                }
                .padding(.top, 4)
            }
            .opacity(celebrated ? 1 : 0)
            .offset(y: celebrated || reduceMotion ? 0 : 10)
            .animation(.smooth(duration: 0.45).delay(0.25), value: celebrated)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            celebrated = true
            bursts += 1
        }
    }
}

/// A value to type on the PC, with a button that copies it.
struct MVCopyField: View {
    let text: String
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copies += 1
                let copy = copies
                withAnimation(.mvState) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copies == copy { withAnimation(.mvState) { copied = false } }
                }
            } label: {
                Label {
                    if copied {
                        Text("Copié")
                    } else {
                        Text("Copier")
                    }
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .controlSize(.small)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

// MARK: - The "+" tile

/// At the end of the grid: opens the guide.
struct MVAddAppTile: View {
    let posterStyle: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: posterStyle ? MVPoster.cornerRadius : 20, style: .continuous)
                    .strokeBorder(hovering && enabled ? AnyShapeStyle(mvAccentForeground) : AnyShapeStyle(.tertiary),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .aspectRatio(posterStyle ? 3.0 / 4.0 : 4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(hovering && enabled ? AnyShapeStyle(mvAccentForeground) : AnyShapeStyle(.secondary))
                            .scaleEffect(hovering && enabled ? 1.12 : 1)
                    }
                Text("Ajouter un jeu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.mvGlide, value: hovering)
        .help(enabled ? Text("Ajouter un jeu sur ce PC") : Text("Le PC doit être en ligne et appairé"))
    }
}
