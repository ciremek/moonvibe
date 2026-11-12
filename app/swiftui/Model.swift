// State of the SwiftUI shell, fed by the Qt host through the bridge (Bridge.swift).

import AppKit
import SwiftUI

// MARK: - Data from the host

struct MVApp: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// The cover the PC serves, cached as a file, and when that file last changed.
    var boxArt: String?
    var boxArtDate: Double?

    var symbolName: String {
        let lower = name.lowercased()
        if lower.contains("virtual") || lower.contains("virtuel") { return "plus.rectangle.on.rectangle" }
        if lower.contains("desktop") || lower.contains("bureau") { return "display" }
        if lower.contains("steam") { return "gamecontroller" }
        return "app.dashed"
    }
}

struct MVComputer: Decodable, Identifiable, Hashable {
    let uuid: String
    let name: String
    let online: Bool
    /// For an offline PC: paired the last time it was seen.
    let paired: Bool
    /// The PC reported a MAC address for Wake-on-LAN.
    let canWake: Bool
    /// "AA:BB:CC:DD:EE:FF" as reported by the PC, or empty.
    let mac: String
    let runningAppId: Int
    /// In the order the user gave them on Home, else the PC's.
    var apps: [MVApp]
    /// Detected addresses first, then the ones added by hand.
    let addresses: [MVAddress]

    var id: String { uuid }

    var statusText: String {
        if !online { return String(localized: "Hors ligne") }
        return paired ? String(localized: "En ligne · appairé") : String(localized: "En ligne · non appairé")
    }

    var runningApp: MVApp? { apps.first { $0.id == runningAppId } }
}

/// Mirrors StreamingPreferences::ResolutionMode.
enum MVResolutionMode: Int, Codable {
    case fixed = 0, native, safeArea, scaled75, scaled50
}

/// Mirrors StreamingPreferences::WindowMode.
enum MVWindowMode: Int, Codable, CaseIterable, Identifiable {
    case fullscreen = 0, borderless, windowed
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .fullscreen: return String(localized: "Plein écran")
        case .borderless: return String(localized: "Fenêtre sans bordure")
        case .windowed: return String(localized: "Fenêtre")
        }
    }
}

/// Mirrors StreamingPreferences, as carried by the bridge (see SwiftUIShell::pushPrefs()).
struct MVPrefs: Codable, Equatable {
    // Image
    var resolutionMode: MVResolutionMode = .native
    var width = 1920
    var height = 1080
    var fps = 60
    var bitrateKbps = 20000
    var unlockBitrate = false
    var windowMode: MVWindowMode = .borderless
    var vsync = true
    var framePacing = false
    var hdr = false
    // Advanced video
    var yuv444 = false
    var videoCodec = 0
    var videoDecoder = 0
    var renderer = 0
    // Audio
    var audioConfig = 0
    var muteHost = true
    var muteOnFocusLoss = false
    // Keyboard and mouse
    var absoluteMouse = false
    var swapMouseButtons = false
    var reverseScroll = false
    var captureSysKeys = 0
    // Gamepad
    var multiController = true
    var backgroundGamepad = false
    var gamepadMouse = true
    var swapFaceButtons = false
    // Computers and network
    var mdns = true
    var detectNetworkBlocking = true
    var disableAwdl = false
    var quitAppAfter = false
    var gameOptimizations = true
    // Misc
    var keepAwake = true
    var showStats = false
    var connectionWarnings = true
    var configurationWarnings = true
    var richPresence = false

    var maxBitrateMbps: Int { unlockBitrate ? 500 : 150 }
}

// MARK: - Presets

enum MVPreset: String, CaseIterable, Identifiable, Codable {
    case fluid, balanced, max, custom
    var id: String { rawValue }

    /// The built-in presets, recognized from the current values.
    static let builtIn: [MVPreset] = [.fluid, .balanced, .max]

    var label: String {
        switch self {
        case .fluid: return String(localized: "Fluide")
        case .balanced: return String(localized: "Équilibré")
        case .max: return String(localized: "Max")
        case .custom: return String(localized: "Perso")
        }
    }

    var help: String {
        switch self {
        case .fluid: return String(localized: "Latence minimale, idéal en Wi-Fi.")
        case .balanced: return String(localized: "Le compromis entre netteté et fluidité.")
        case .max: return String(localized: "Résolution native. Câble ou Wi-Fi 6 conseillé.")
        case .custom: return String(localized: "Tes réglages, enregistrés dès que tu les modifies.")
        }
    }

    var resolutionMode: MVResolutionMode {
        switch self {
        case .fluid: return .scaled50
        case .balanced: return .scaled75
        case .max, .custom: return .native
        }
    }

    var bitrateKbps: Int {
        switch self {
        case .fluid: return 40_000
        case .balanced: return 80_000
        case .max, .custom: return 144_000
        }
    }
}

/// The values saved under the Perso preset.
struct MVCustomPreset: Codable, Equatable {
    var resolutionMode: MVResolutionMode
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int

    init(_ prefs: MVPrefs) {
        resolutionMode = prefs.resolutionMode
        width = prefs.width
        height = prefs.height
        fps = prefs.fps
        bitrateKbps = prefs.bitrateKbps
    }
}

// MARK: - Display info

/// Native panel resolution and refresh rate of the screen hosting the window.
struct MVDisplay: Equatable {
    var nativeWidth = 1920
    var nativeHeight = 1080
    var safeAreaHeight = 1080
    var maxFps = 60
    /// Global top-left corner in CoreGraphics coordinates, as the Qt host expects.
    var origin = CGPoint.zero

    var hasNotch: Bool { safeAreaHeight != nativeHeight }

    static func of(_ screen: NSScreen?) -> MVDisplay {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return MVDisplay() }

        let displayId = CGDirectDisplayID(number.uint32Value)
        var display = MVDisplay()
        display.origin = CGDisplayBounds(displayId).origin
        display.maxFps = max(screen.maximumFramesPerSecond, 30)

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayId, options) as? [CGDisplayMode]) ?? []
        // kDisplayModeNativeFlag
        if let native = modes.first(where: { $0.ioFlags & 0x0200_0000 != 0 }) {
            display.nativeWidth = native.pixelWidth
            display.nativeHeight = native.pixelHeight
        }

        display.safeAreaHeight = display.nativeHeight
        if screen.safeAreaInsets.top > 0, screen.frame.height > 0 {
            let ratio = (screen.frame.height - screen.safeAreaInsets.top) / screen.frame.height
            display.safeAreaHeight = Int((CGFloat(display.nativeHeight) * ratio).rounded())
        }
        return display
    }

    /// Resolution the stream will use for a given mode, matching Session::applyAutoResolution().
    func resolution(for mode: MVResolutionMode, prefs: MVPrefs) -> (Int, Int) {
        switch mode {
        case .fixed: return (prefs.width, prefs.height)
        case .native: return (nativeWidth, nativeHeight)
        case .safeArea: return (nativeWidth, safeAreaHeight)
        case .scaled75: return ((nativeWidth * 75 / 100) & ~7, (nativeHeight * 75 / 100) & ~7)
        case .scaled50: return ((nativeWidth * 50 / 100) & ~7, (nativeHeight * 50 / 100) & ~7)
        }
    }
}

// MARK: - Pairing

enum MVPairingStep: Equatable {
    /// Pick a PC found on the network, or add one by address.
    case search
    /// Waiting for the user to type the PIN into Sunshine. The PIN is empty until the host sends it.
    case waiting(computerId: String, pin: String)
    case paired(computerId: String)
    case failed(computerId: String, error: String)
}

struct MVPairingUpdate: Decodable {
    let uuid: String
    let stage: String
    let pin: String?
    let error: String?
}

struct MVAddHostResult: Decodable {
    let success: Bool
    let portBlocking: Bool
}

struct MVAppRef: Hashable {
    let computerId: String
    let appId: Int
}

/// A game being added on a PC (MVAddAppSheet): what Moonvibe gives it once it shows up.
struct MVPendingApp: Equatable {
    let computerId: String
    let name: String
    let settings: MVAppSettings
    /// What to start, when the guide knows it: a Steam or launcher link goes in Sunshine's
    /// detached commands, a program in its command.
    let command: String?
    let detached: Bool
    /// The PC's apps when the guide opened: one that wasn't there is the new one.
    let knownAppIds: Set<Int>
    /// Set once it showed up on the PC.
    var foundAppId: Int?
}

/// The guide's steps, shown over a stream of the PC's desktop to add a game from there.
struct MVStreamGuide: Equatable {
    let appName: String
    let computerName: String
    /// The desktop app the stream is for: only that stream shows the steps.
    let desktopName: String
}

// MARK: - App settings

/// Tile colors, from a palette that reads in both appearances.
enum MVTileColor: String, Codable, CaseIterable, Identifiable {
    case indigo, blue, teal, green, orange, red, pink, purple, graphite
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .indigo: return mvAccentForeground
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .graphite: return .gray
        }
    }

    var label: String {
        switch self {
        case .indigo: return String(localized: "Indigo")
        case .blue: return String(localized: "Bleu")
        case .teal: return String(localized: "Turquoise")
        case .green: return String(localized: "Vert")
        case .orange: return String(localized: "Orange")
        case .red: return String(localized: "Rouge")
        case .pink: return String(localized: "Rose")
        case .purple: return String(localized: "Violet")
        case .graphite: return String(localized: "Graphite")
        }
    }
}

/// Moonvibe's own settings for one app on one PC.
struct MVAppSettings: Codable, Equatable {
    /// SF Symbol for the tile, else one guessed from the app's name.
    var symbol: String?
    var color: MVTileColor?
    /// A poster picked on this Mac, by file name in MVPosters.directory: it wins over the
    /// cover the PC serves.
    var poster: String?
    /// Quality for this app's streams, else the usual one.
    var preset: MVPreset?
    /// Mac apps to open when a stream of this app starts, by path.
    var openApps: [String] = []
    /// Quit, when the stream ends, the apps Moonvibe opened for it.
    var quitOpenedApps = true

    var isEmpty: Bool { self == MVAppSettings() }
}

// MARK: - Addresses

/// One address Moonvibe knows for a PC.
struct MVAddress: Decodable, Hashable {
    let address: String
    let port: Int
    /// "local", "remote" and "ipv6" are detected; "manual" ones were added by hand.
    let kind: String
    /// The address the PC answers on right now.
    let active: Bool

    static let defaultPort = 47989

    /// As the user would type it: the port only when it isn't Sunshine's default.
    var text: String {
        guard port != Self.defaultPort else { return address }
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    var kindLabel: String {
        switch kind {
        case "local": return String(localized: "Réseau local")
        case "remote": return String(localized: "IP publique")
        case "ipv6": return "IPv6"
        default: return MVAddress.autoLabel(for: text) ?? String(localized: "Ajoutée")
        }
    }

    /// "Tailscale" for its 100.64.0.0/10 addresses.
    static func autoLabel(for text: String) -> String? {
        let octets = text.split(separator: ":").first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) else { return nil }
        return "Tailscale"
    }
}

enum MVAddressTest: Equatable {
    case testing, ok, otherComputer, unreachable, invalid
}

struct MVAddressTestResult: Decodable {
    let uuid: String
    let address: String
    let result: String
}

// MARK: - Wake-on-LAN

/// Moonvibe's own wake settings for a PC, on top of what the PC reports.
struct MVWakeOptions: Codable, Equatable {
    /// Replaces the MAC address reported by the PC. Empty: use the reported one.
    var mac = ""
    /// One more target, for waking the PC from outside its network: an IP address or a
    /// DDNS name, and the UDP port the router forwards to the PC. Empty: none.
    var address = ""
    var port = 9

    var isEmpty: Bool { self == MVWakeOptions() }

    /// "AA:BB:CC:DD:EE:FF", from the usual ways of writing a MAC address, or nil.
    static func normalizedMac(_ text: String) -> String? {
        let digits = Array(text.uppercased().filter { !":-. ".contains($0) })
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit) else { return nil }
        return stride(from: 0, to: 12, by: 2).map { String(digits[$0...$0 + 1]) }.joined(separator: ":")
    }
}

enum MVWakeState: Equatable {
    /// Magic packets go out until the PC answers.
    case waking(since: Date)
    /// The PC didn't answer within `MVModel.wakeTimeout`.
    case noAnswer
    /// No packet could be sent.
    case failed
}

struct MVWakeResult: Decodable {
    let uuid: String
    let sent: Bool
}

// MARK: - Recent sessions

struct MVRecent: Codable, Identifiable, Hashable {
    let computerId: String
    let computerName: String
    let appId: Int
    let appName: String
    let date: Date

    var id: String { "\(computerId):\(appId)" }

    var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "aujourd'hui") }
        if calendar.isDateInYesterday(date) { return String(localized: "hier") }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Model

@MainActor
final class MVModel: ObservableObject {
    @Published var computers: [MVComputer] = []
    /// The computers as the host sent them, before the user's app order.
    private var hostComputers: [MVComputer] = []
    /// App ids in the order the user dragged them into, by computer id.
    private var appOrder: [String: [Int]] = [:]
    @Published var selectedComputerId: String?
    @Published var selectedAppId: Int?
    @Published private(set) var prefs = MVPrefs()
    @Published var display = MVDisplay()
    @Published var recents: [MVRecent] = []
    @Published var search = ""
    @Published var showQuality = false
    /// Opens the settings window, on a given section or where it was left.
    var openSettings: ((MVSettingsSection?) -> Void)?
    @Published var status = ""
    @Published var busy = false
    /// The busy work can be cancelled with esc.
    @Published var cancellable = true
    @Published var errorMessage: String?
    var updater: MVUpdater?
    var quickLaunch: MVQuickLaunch?
    /// Version of the update the sidebar badge shows, found by a scheduled check.
    @Published var availableUpdate: String?
    @Published var showPairing = false
    @Published var pairingStep = MVPairingStep.search
    @Published var addingHost = false
    @Published var addHostError: String?
    /// Computer whose running app awaits a quit confirmation in the banner.
    @Published var confirmQuitComputerId: String?
    /// App the user wants to launch while another one runs on the same PC: the banner
    /// asks to quit the running one first.
    @Published var confirmSwitch: MVAppRef?
    /// App to launch once the PC reports its running app has quit.
    private var launchAfterQuit: MVAppRef?
    private var openedPairingForEmptyList = false

    /// Wake settings by computer id.
    @Published private(set) var wakeOptions: [String: MVWakeOptions] = [:]
    /// PCs being woken, or that didn't wake, by computer id.
    @Published private(set) var wakeStates: [String: MVWakeState] = [:]
    /// Magic packets sent so far, by computer id: each one sets off a wave in the UI.
    @Published private(set) var wakePackets: [String: Int] = [:]
    /// Launch requests so far, by app: the tile acknowledges each one.
    @Published private(set) var launchRequests: [MVAppRef: Int] = [:]
    /// The app the last launch was for; it's starting while `busy` is set.
    @Published private(set) var launchingApp: MVAppRef?
    /// Launches actually started, by app: each one bursts out of its tile.
    @Published private(set) var launchStarts: [MVAppRef: Int] = [:]
    /// Apps just added through the guide, by app: they burst out of their tile too.
    @Published private(set) var arrivals: [MVAppRef: Int] = [:]
    /// Computer whose "add a game" guide is open.
    @Published var addAppComputerId: String?
    /// The game the guide waits for, even once closed.
    @Published private(set) var pendingApp: MVPendingApp?
    /// Steps to show over the next stream, to add the game from the PC itself.
    private(set) var streamGuide: MVStreamGuide?
    /// How this Mac reaches the network right now.
    @Published private(set) var link = MVLink(wired: false, wifi: nil)
    /// The report on the last stream, until it's closed or another stream starts.
    @Published var lastReport: MVStreamSummary?
    private var linkMonitor: MVLinkMonitor?
    /// The link when the current stream started, which its report shows.
    private var linkAtLaunch: MVLink?
    /// Computer whose settings sheet is open.
    @Published var computerSettingsId: String?
    /// App whose settings sheet is open.
    @Published var appSettingsTarget: MVAppRef?
    /// Settings by "computerId:appId".
    @Published private(set) var appSettings: [String: MVAppSettings] = [:]
    /// Bundle IDs of the apps Moonvibe opened for the current stream, to quit when it ends.
    private var appsToQuitAfterStream: Set<String>?
    /// Labels given to added addresses, by computer id then address.
    @Published private(set) var addressLabels: [String: [String: String]] = [:]
    /// Address checks, by computer id then address as typed.
    @Published private(set) var addressTests: [String: [String: MVAddressTest]] = [:]
    /// App to launch once a waking PC answers, by computer id.
    private var launchAfterWake: [String: Int] = [:]
    private var wakeTasks: [String: Task<Void, Never>] = [:]

    /// A PC booting from off takes about a minute to start Sunshine; a slow one may need two.
    static let wakeTimeout: Duration = .seconds(120)
    /// Wi-Fi sends broadcast frames once, without acknowledgment, so a magic packet can get
    /// lost: it goes out again at this interval until the PC answers.
    static let wakeResendInterval: Duration = .seconds(10)

    var sendAction: (([String: Any]) -> Void)?
    weak var window: NSWindow?

    private static let recentsKey = "MoonvibeRecents"
    private static let wakeOptionsKey = "MoonvibeWakeOptions"
    private static let addressLabelsKey = "MoonvibeAddressLabels"
    private static let appSettingsKey = "MoonvibeAppSettings"
    private static let appOrderKey = "MoonvibeAppOrder"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let decoded = try? JSONDecoder().decode([MVRecent].self, from: data) {
            recents = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.wakeOptionsKey),
           let decoded = try? JSONDecoder().decode([String: MVWakeOptions].self, from: data) {
            wakeOptions = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.addressLabelsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            addressLabels = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Self.appSettingsKey),
           let decoded = try? JSONDecoder().decode([String: MVAppSettings].self, from: data) {
            appSettings = decoded
        }
        MVPosters.prune(keeping: Set(appSettings.values.compactMap(\.poster)))
        if let order = UserDefaults.standard.dictionary(forKey: Self.appOrderKey) as? [String: [Int]] {
            appOrder = order
        }
        linkMonitor = MVLinkMonitor { [weak self] link in
            if self?.link != link {
                self?.link = link
            }
        }
    }

    // MARK: Derived state

    var selectedComputer: MVComputer? { computers.first { $0.id == selectedComputerId } }

    var filteredComputers: [MVComputer] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return computers }
        return computers.filter { computer in
            computer.name.localizedCaseInsensitiveContains(query) ||
            computer.apps.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    func visibleApps(of computer: MVComputer) -> [MVApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !computer.name.localizedCaseInsensitiveContains(query) else { return computer.apps }
        return computer.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The user's pick, else the app running on the PC (to resume it), else the first one.
    func selectedApp(of computer: MVComputer) -> MVApp? {
        let apps = visibleApps(of: computer)
        return apps.first { $0.id == selectedAppId }
            ?? apps.first { $0.id == computer.runningAppId }
            ?? apps.first
    }

    var preset: MVPreset {
        MVPreset.builtIn.first { preset in
            prefs.resolutionMode == preset.resolutionMode &&
            prefs.bitrateKbps == preset.bitrateKbps &&
            (fpsFollowsDisplay || prefs.fps == display.maxFps)
        } ?? .custom
    }

    /// Built-in presets stream at the highest frame rate of the display the stream opens
    /// on, resolved at launch: a preset picked on a 120 Hz MacBook drops to 60 on a 60 Hz
    /// screen instead of streaming frames it can't show.
    @Published private(set) var fpsFollowsDisplay = UserDefaults.standard.bool(forKey: "MoonvibeFpsFollowsDisplay") {
        didSet { UserDefaults.standard.set(fpsFollowsDisplay, forKey: "MoonvibeFpsFollowsDisplay") }
    }

    /// A frame rate picked by hand.
    func setFps(_ fps: Int) {
        fpsFollowsDisplay = fps == display.maxFps
        setPrefs { $0.fps = fps }
    }

    /// Resolution · frame rate · bitrate a preset streams at, on the current display.
    func summary(for preset: MVPreset) -> String? {
        if preset == .custom {
            guard let custom = customPreset else { return nil }
            var values = prefs
            values.width = custom.width
            values.height = custom.height
            let (width, height) = display.resolution(for: custom.resolutionMode, prefs: values)
            return String(localized: "\(width)×\(height) · \(custom.fps) i/s · \(custom.bitrateKbps / 1000) Mb/s")
        }
        let (width, height) = display.resolution(for: preset.resolutionMode, prefs: prefs)
        return String(localized: "\(width)×\(height) · \(display.maxFps) i/s · \(preset.bitrateKbps / 1000) Mb/s")
    }

    var streamResolution: (Int, Int) { display.resolution(for: prefs.resolutionMode, prefs: prefs) }

    var qualitySummary: String {
        let (width, height) = streamResolution
        return String(localized: "\(width)×\(height) · \(prefs.fps) i/s · \(prefs.bitrateKbps / 1000) Mb/s")
    }

    func canLaunch(on computer: MVComputer) -> Bool {
        computer.online && computer.paired && !busy
    }

    /// The MAC address the magic packet targets: the user's, else the one the PC reported.
    func wakeMac(of computer: MVComputer) -> String? {
        MVWakeOptions.normalizedMac(wakeOptions[computer.id]?.mac ?? "") ?? (computer.canWake ? computer.mac : nil)
    }

    func canWake(_ computer: MVComputer) -> Bool {
        !computer.online && wakeMac(of: computer) != nil
    }

    /// An offline PC this Mac paired with: launching one of its apps wakes it first.
    func canWakeAndLaunch(on computer: MVComputer) -> Bool {
        canWake(computer) && computer.paired && !busy
    }

    func isWaking(_ computer: MVComputer) -> Bool {
        if case .waking = wakeStates[computer.id] { return true }
        return false
    }

    /// The app that launches once the waking PC answers.
    func appLaunchingAfterWake(on computer: MVComputer) -> MVApp? {
        guard let appId = launchAfterWake[computer.id] else { return nil }
        return computer.apps.first { $0.id == appId }
    }

    // MARK: Updates from the host

    func update(computers: [MVComputer]) {
        hostComputers = computers
        let computers = ordered(computers)
        self.computers = computers
        matchPendingApp()
        // Launch the app waiting for the previous one to quit
        if let pending = launchAfterQuit,
           let computer = computers.first(where: { $0.id == pending.computerId }),
           computer.online, computer.runningAppId == 0,
           let app = computer.apps.first(where: { $0.id == pending.appId }) {
            launchAfterQuit = nil
            launch(app, on: computer)
        }

        // A PC woke up (or was deleted): stop sending packets, then launch the app waiting for it
        for (computerId, state) in wakeStates {
            let computer = computers.first { $0.id == computerId }
            guard computer?.online ?? true else { continue }
            let appId = launchAfterWake[computerId]
            stopWaking(computerId)
            if case .waking = state, let computer, let appId,
               let app = computer.apps.first(where: { $0.id == appId }) {
                requestLaunch(app, on: computer)
            }
        }

        // No PC yet: start with pairing, once
        if computers.isEmpty, !openedPairingForEmptyList {
            openedPairingForEmptyList = true
            openPairing()
        }
        if selectedComputerId == nil || !computers.contains(where: { $0.id == selectedComputerId }) {
            selectedComputerId = computers.first(where: { $0.online && $0.paired })?.id ?? computers.first?.id
        }
    }

    func update(prefs: MVPrefs) {
        self.prefs = prefs
        // Values set before Perso existed (or in the old UI) become the first Perso
        if customPreset == nil, preset == .custom {
            saveCustomPreset()
        }
    }

    // MARK: Perso preset

    @Published private(set) var customPreset: MVCustomPreset? = {
        guard let data = UserDefaults.standard.data(forKey: "MoonvibeCustomPreset") else { return nil }
        return try? JSONDecoder().decode(MVCustomPreset.self, from: data)
    }()

    /// Saves the current image values as Perso. Called whenever they match no built-in preset,
    /// so tweaking resolution, frame rate or bitrate always lands in Perso.
    private func saveCustomPreset() {
        let custom = MVCustomPreset(prefs)
        guard custom != customPreset else { return }
        customPreset = custom
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: "MoonvibeCustomPreset")
        }
    }

    func refreshDisplay() {
        display = MVDisplay.of(window?.screen ?? NSScreen.main)
    }

    // MARK: Actions

    func setPrefs(_ change: (inout MVPrefs) -> Void) {
        var updated = prefs
        change(&updated)
        guard updated != prefs else { return }
        prefs = updated
        if preset == .custom {
            saveCustomPreset()
        }
        if let data = try? JSONEncoder().encode(updated),
           let object = try? JSONSerialization.jsonObject(with: data) {
            sendAction?(["action": "setPrefs", "prefs": object])
        }
    }

    func apply(_ preset: MVPreset) {
        if preset == .custom {
            guard let custom = customPreset else { return }
            fpsFollowsDisplay = false
            setPrefs {
                $0.resolutionMode = custom.resolutionMode
                $0.width = custom.width
                $0.height = custom.height
                $0.fps = custom.fps
                $0.bitrateKbps = custom.bitrateKbps
            }
            return
        }
        fpsFollowsDisplay = true
        setPrefs {
            $0.resolutionMode = preset.resolutionMode
            $0.bitrateKbps = preset.bitrateKbps
            $0.fps = display.maxFps
        }
    }

    func launch(_ app: MVApp, on computer: MVComputer) {
        guard canLaunch(on: computer) else { return }
        refreshDisplay()
        // Sent before the launch, so the host applies it to this stream
        if fpsFollowsDisplay, prefs.fps != display.maxFps {
            setPrefs { $0.fps = display.maxFps }
        }
        busy = true
        cancellable = true
        let ref = MVAppRef(computerId: computer.id, appId: app.id)
        launchingApp = ref
        launchStarts[ref, default: 0] += 1
        lastReport = nil
        linkAtLaunch = linkMonitor?.current ?? link
        status = String(localized: "Connexion à \(computer.name)…")
        rememberRecent(app, on: computer)

        let settings = self.settings(of: app, on: computer)
        openAppsBeforeStream(settings)
        var action: [String: Any] = [
            "action": "launch",
            "uuid": computer.uuid,
            "appId": app.id,
            "displayX": Int(display.origin.x),
            "displayY": Int(display.origin.y),
        ]
        if let overrides = qualityOverrides(for: settings.preset) {
            action["overrides"] = overrides
        }
        sendAction?(action)
    }

    func launch(_ recent: MVRecent) {
        guard let computer = computers.first(where: { $0.id == recent.computerId }),
              let app = computer.apps.first(where: { $0.id == recent.appId }) else { return }
        selectedComputerId = computer.id
        selectedAppId = app.id
        requestLaunch(app, on: computer)
    }

    /// Launches an app, or first asks to quit the other app running on the PC: the host
    /// refuses to start a second one.
    func requestLaunch(_ app: MVApp, on computer: MVComputer) {
        // Wake & Go: wake the PC, and launch the app as soon as it answers
        let ref = MVAppRef(computerId: computer.id, appId: app.id)
        if !computer.online {
            if canWakeAndLaunch(on: computer) {
                selectedAppId = app.id
                launchRequests[ref, default: 0] += 1
                wake(computer, thenLaunch: app)
            }
            return
        }
        if computer.runningAppId != 0, computer.runningAppId != app.id {
            selectedComputerId = computer.id
            selectedAppId = app.id
            confirmQuitComputerId = nil
            confirmSwitch = ref
            launchRequests[ref, default: 0] += 1
            return
        }
        if canLaunch(on: computer) {
            launchRequests[ref, default: 0] += 1
        }
        launch(app, on: computer)
    }

    func quitAndLaunch(_ app: MVApp, on computer: MVComputer) {
        confirmSwitch = nil
        launchAfterQuit = MVAppRef(computerId: computer.id, appId: app.id)
        quitRunningApp(on: computer)
        let running = computer.runningApp?.name ?? String(localized: "L'app en cours")
        status = String(localized: "\(running) se ferme, puis \(app.name) se lance…")
    }

    /// The host failed to quit the app: drop the launch waiting for it.
    func cancelPendingLaunch() {
        launchAfterQuit = nil
    }

    func openPairing(for computer: MVComputer? = nil) {
        addHostError = nil
        pairingStep = .search
        showPairing = true
        if let computer { pair(computer) }
    }

    func pair(_ computer: MVComputer) {
        pairingStep = .waiting(computerId: computer.id, pin: "")
        sendAction?(["action": "pair", "uuid": computer.uuid])
    }

    func update(pairing: MVPairingUpdate) {
        switch pairing.stage {
        case "waiting": pairingStep = .waiting(computerId: pairing.uuid, pin: pairing.pin ?? "")
        case "paired": pairingStep = .paired(computerId: pairing.uuid)
        default: pairingStep = .failed(computerId: pairing.uuid, error: pairing.error ?? String(localized: "L'appairage a échoué."))
        }
    }

    func addHost(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !addingHost else { return }
        addingHost = true
        addHostError = nil
        sendAction?(["action": "addHost", "address": trimmed])
    }

    func update(addHost result: MVAddHostResult) {
        addingHost = false
        if !result.success {
            addHostError = result.portBlocking
                ? String(localized: "PC injoignable : ton réseau semble bloquer la connexion.")
                : String(localized: "PC introuvable à cette adresse. Vérifie qu'il est allumé et que Sunshine tourne.")
        }
    }

    func finishPairing() {
        if case .paired(let computerId) = pairingStep {
            selectedComputerId = computerId
            selectedAppId = nil
        }
        showPairing = false
        pairingStep = .search
    }

    func delete(_ computer: MVComputer) {
        if selectedComputerId == computer.id { selectedComputerId = nil }
        recents.removeAll { $0.computerId == computer.id }
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
        stopWaking(computer.id)
        setWakeOptions(MVWakeOptions(), for: computer)
        setAddressLabels([:], for: computer)
        appSettings = appSettings.filter { !$0.key.hasPrefix("\(computer.id):") }
        saveAppSettings()
        setAppOrder(nil, of: computer.id)
        sendAction?(["action": "deleteHost", "uuid": computer.uuid])
    }

    func cancelLaunch() {
        guard busy, cancellable else { return }
        sendAction?(["action": "cancel"])
    }

    // MARK: App order

    /// Puts the dragged app in another one's place on Home.
    func moveApp(_ appId: Int, to targetId: Int, on computer: MVComputer) {
        guard appId != targetId,
              var ids = computers.first(where: { $0.id == computer.id })?.apps.map(\.id),
              let from = ids.firstIndex(of: appId), let to = ids.firstIndex(of: targetId) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        setAppOrder(ids, of: computer.id)
    }

    func hasCustomAppOrder(_ computer: MVComputer) -> Bool {
        appOrder[computer.id] != nil
    }

    /// Back to the order the PC lists its apps in.
    func resetAppOrder(of computer: MVComputer) {
        setAppOrder(nil, of: computer.id)
    }

    private func setAppOrder(_ ids: [Int]?, of computerId: String) {
        appOrder[computerId] = ids
        UserDefaults.standard.set(appOrder, forKey: Self.appOrderKey)
        computers = ordered(hostComputers)
    }

    /// The user's order first; apps added since then follow, as the PC lists them.
    private func ordered(_ computers: [MVComputer]) -> [MVComputer] {
        computers.map { computer in
            guard let order = appOrder[computer.id] else { return computer }
            var rank: [Int: Int] = [:]
            for (index, id) in order.enumerated() where rank[id] == nil {
                rank[id] = index
            }
            var sorted = computer
            sorted.apps = computer.apps.enumerated().sorted { a, b in
                (rank[a.element.id] ?? Int.max, a.offset) < (rank[b.element.id] ?? Int.max, b.offset)
            }.map(\.element)
            return sorted
        }
    }

    // MARK: Adding an app

    func openAddApp(on computer: MVComputer) {
        addAppComputerId = computer.id
    }

    /// Waits for the game to show up on the PC, to give it its settings and poster.
    func watchForApp(named name: String, settings: MVAppSettings, command: String?, detached: Bool,
                     knownAppIds: Set<Int>, on computer: MVComputer) {
        pendingApp = MVPendingApp(computerId: computer.id, name: name, settings: settings, command: command,
                                  detached: detached, knownAppIds: knownAppIds)
        matchPendingApp()
    }

    /// Streams the PC's desktop with the guide's steps on screen, so the game's path can be
    /// found and copied on the PC. The game's name goes to this Mac's clipboard, which
    /// ⌃⌥⇧V types into the stream.
    func addFromPC(using desktop: MVApp, on computer: MVComputer) {
        guard let pending = pendingApp else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pending.name, forType: .string)
        streamGuide = MVStreamGuide(appName: pending.name, computerName: computer.name, desktopName: desktop.name)
        closeAddApp()
        requestLaunch(desktop, on: computer)
    }

    func stopWatchingForApp() {
        pendingApp = nil
    }

    /// Asks the PC for its apps now: Moonvibe otherwise checks every 30 seconds or so.
    func refreshApps(on computer: MVComputer) {
        sendAction?(["action": "refreshApps", "uuid": computer.uuid])
    }

    /// Closes the guide. A game that showed up gets selected and bursts out of its tile.
    func closeAddApp() {
        addAppComputerId = nil
        guard let pending = pendingApp, let appId = pending.foundAppId else { return }
        pendingApp = nil
        celebrateArrival(MVAppRef(computerId: pending.computerId, appId: appId))
    }

    /// The added game: the one named as in the guide, else the only new one (renamed on the PC).
    private func matchPendingApp() {
        guard var pending = pendingApp, pending.foundAppId == nil,
              let computer = computers.first(where: { $0.id == pending.computerId }) else { return }
        let newApps = computer.apps.filter { !pending.knownAppIds.contains($0.id) }
        let name = pending.name.trimmingCharacters(in: .whitespaces)
        guard let app = newApps.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) ?? (newApps.count == 1 ? newApps.first : nil) else { return }

        var settings = self.settings(of: app, on: computer)
        settings.poster = pending.settings.poster ?? settings.poster
        settings.symbol = pending.settings.symbol ?? settings.symbol
        settings.color = pending.settings.color ?? settings.color
        setSettings(settings, of: app, on: computer)

        pending.foundAppId = app.id
        if addAppComputerId == computer.id {
            // The guide shows it, and celebrates once closed
            pendingApp = pending
        } else {
            pendingApp = nil
            celebrateArrival(MVAppRef(computerId: computer.id, appId: app.id))
        }
    }

    private func celebrateArrival(_ ref: MVAppRef) {
        selectedComputerId = ref.computerId
        selectedAppId = ref.appId
        Task {
            // Once the sheet is out of the way
            try? await Task.sleep(for: .milliseconds(350))
            arrivals[ref, default: 0] += 1
        }
    }

    // MARK: App settings

    func settings(of app: MVApp, on computer: MVComputer) -> MVAppSettings {
        appSettings["\(computer.id):\(app.id)"] ?? MVAppSettings()
    }

    func setSettings(_ settings: MVAppSettings, of app: MVApp, on computer: MVComputer) {
        appSettings["\(computer.id):\(app.id)"] = settings.isEmpty ? nil : settings
        saveAppSettings()
    }

    private func saveAppSettings() {
        if let data = try? JSONEncoder().encode(appSettings) {
            UserDefaults.standard.set(data, forKey: Self.appSettingsKey)
        }
    }

    /// Opens the Mac apps an app's stream needs. Apps already running are left alone,
    /// before and after the stream.
    private func openAppsBeforeStream(_ settings: MVAppSettings) {
        if appsToQuitAfterStream == nil {
            appsToQuitAfterStream = []
        }
        for path in settings.openApps {
            let url = URL(fileURLWithPath: path)
            guard let bundleId = Bundle(url: url)?.bundleIdentifier,
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
            else { continue }

            // Tracked by bundle ID, not by process: some apps restart themselves, like
            // VirtualHere, which comes back as root once given the admin password
            if settings.quitOpenedApps {
                appsToQuitAfterStream?.insert(bundleId)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// The stream window went away: quit the apps opened for it.
    func streamWindowClosed() {
        streamGuide = nil
        let bundleIds = appsToQuitAfterStream ?? []
        appsToQuitAfterStream = nil
        bundleIds.forEach(Self.quitApp(bundleIdentifier:))
        linkMonitor?.refresh()
    }

    /// The host's report on the stream that just ended, shown on Home and kept in the history.
    func show(report: MVStreamReport) {
        guard report.durationSecs >= MVStreamSummary.minimumDuration else { return }
        let computer = computers.first { $0.id == report.computerId }
        let address = computer?.addresses.first { $0.address == report.address }
        // The user's label for an added address, else what kind of address it is
        let route = address.map { address in
            computer.flatMap { addressLabel(address.text, of: $0) } ?? address.kindLabel
        }
        let summary = MVStreamSummary(report: report, link: linkAtLaunch ?? link,
                                      route: route, localRoute: address?.kind == "local")
        lastReport = summary
        MVStreamHistory.append(MVStreamRecord(summary: summary, computerName: computer?.name ?? "",
                                              routeKind: address?.kind))
    }

    /// Asks every instance of an app to quit. A standard quit event also reaches an
    /// instance running as root, which terminate() can't, and needs no admin rights.
    private static func quitApp(bundleIdentifier: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }

        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEQuitApplication),
                                           targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 3)
    }

    /// The values the host streams an app with when it has its own quality.
    private func qualityOverrides(for preset: MVPreset?) -> [String: Any]? {
        guard let preset else { return nil }
        if preset == .custom {
            guard let custom = customPreset else { return nil }
            return ["resolutionMode": custom.resolutionMode.rawValue, "width": custom.width,
                    "height": custom.height, "fps": custom.fps, "bitrateKbps": custom.bitrateKbps]
        }
        return ["resolutionMode": preset.resolutionMode.rawValue, "fps": display.maxFps,
                "bitrateKbps": preset.bitrateKbps]
    }

    // MARK: Computer settings

    func rename(_ computer: MVComputer, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != computer.name else { return }
        sendAction?(["action": "rename", "uuid": computer.uuid, "name": trimmed])
    }

    /// Replaces the addresses added by hand. The host normalizes them and drops invalid ones.
    func setUserAddresses(_ texts: [String], for computer: MVComputer) {
        sendAction?(["action": "setAddresses", "uuid": computer.uuid, "addresses": texts])
    }

    func addressLabel(_ text: String, of computer: MVComputer) -> String? {
        addressLabels[computer.id]?[text]
    }

    /// Keeps the labels of the given addresses only, dropping empty ones.
    func setAddressLabels(_ labels: [String: String], for computer: MVComputer) {
        let kept = labels.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        addressLabels[computer.id] = kept.isEmpty ? nil : kept
        if let data = try? JSONEncoder().encode(addressLabels) {
            UserDefaults.standard.set(data, forKey: Self.addressLabelsKey)
        }
    }

    /// Checks that an address answers with this PC's ID.
    func testAddress(_ text: String, on computer: MVComputer) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        addressTests[computer.id, default: [:]][trimmed] = .testing
        sendAction?(["action": "testAddress", "uuid": computer.uuid, "address": trimmed])
    }

    func addressTest(_ text: String, of computer: MVComputer) -> MVAddressTest? {
        addressTests[computer.id]?[text.trimmingCharacters(in: .whitespaces)]
    }

    func update(addressTest: MVAddressTestResult) {
        let result: MVAddressTest
        switch addressTest.result {
        case "ok": result = .ok
        case "other": result = .otherComputer
        case "unreachable": result = .unreachable
        default: result = .invalid
        }
        addressTests[addressTest.uuid, default: [:]][addressTest.address] = result
    }

    // MARK: Wake-on-LAN

    /// Sends magic packets until the PC answers or `wakeTimeout` runs out, then optionally
    /// launches an app on it. Waking a PC already waking only changes the app.
    func wake(_ computer: MVComputer, thenLaunch app: MVApp? = nil) {
        guard canWake(computer) else { return }
        launchAfterWake[computer.id] = app?.id
        guard !isWaking(computer) else { return }

        let computerId = computer.id
        wakeStates[computerId] = .waking(since: Date())
        wakeTasks[computerId] = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now + Self.wakeTimeout
            while clock.now < deadline {
                guard let self, !Task.isCancelled else { return }
                self.sendWakePacket(to: computerId)
                try? await Task.sleep(for: Self.wakeResendInterval)
            }
            guard let self, !Task.isCancelled else { return }
            self.stopWaking(computerId)
            self.wakeStates[computerId] = .noAnswer
        }
    }

    func cancelWake(_ computer: MVComputer) {
        stopWaking(computer.id)
    }

    private func stopWaking(_ computerId: String) {
        wakeTasks.removeValue(forKey: computerId)?.cancel()
        wakeStates[computerId] = nil
        launchAfterWake[computerId] = nil
    }

    private func sendWakePacket(to computerId: String) {
        wakePackets[computerId, default: 0] += 1
        var action: [String: Any] = ["action": "wake", "uuid": computerId]
        let options = wakeOptions[computerId] ?? MVWakeOptions()
        if let mac = MVWakeOptions.normalizedMac(options.mac) {
            action["mac"] = mac
        }
        if !options.address.isEmpty {
            action["address"] = options.address
            action["port"] = options.port
        }
        sendAction?(action)
    }

    func update(wakeResult: MVWakeResult) {
        guard !wakeResult.sent, case .waking = wakeStates[wakeResult.uuid] else { return }
        stopWaking(wakeResult.uuid)
        wakeStates[wakeResult.uuid] = .failed
    }

    /// Saves wake options, dropping a MAC override equal to the reported address.
    func setWakeOptions(_ options: MVWakeOptions, for computer: MVComputer) {
        var options = options
        options.mac = MVWakeOptions.normalizedMac(options.mac) ?? ""
        if options.mac == computer.mac { options.mac = "" }
        options.address = options.address.trimmingCharacters(in: .whitespaces)
        if options.address.isEmpty { options.port = MVWakeOptions().port }

        wakeOptions[computer.id] = options.isEmpty ? nil : options
        if let data = try? JSONEncoder().encode(wakeOptions) {
            UserDefaults.standard.set(data, forKey: Self.wakeOptionsKey)
        }
    }

    func quitRunningApp(on computer: MVComputer) {
        confirmQuitComputerId = nil
        status = String(localized: "Fermeture de l'app en cours sur \(computer.name)…")
        sendAction?(["action": "quitApp", "uuid": computer.uuid])
    }

    func moveSelection(by offset: Int, in computer: MVComputer) {
        let apps = visibleApps(of: computer)
        guard !apps.isEmpty else { return }
        let current = apps.firstIndex { $0.id == selectedApp(of: computer)?.id } ?? 0
        let next = min(max(current + offset, 0), apps.count - 1)
        selectedAppId = apps[next].id
    }

    private func rememberRecent(_ app: MVApp, on computer: MVComputer) {
        let recent = MVRecent(computerId: computer.id, computerName: computer.name,
                              appId: app.id, appName: app.name, date: Date())
        recents.removeAll { $0.id == recent.id }
        recents.insert(recent, at: 0)
        recents = Array(recents.prefix(5))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }
}
