// Quick launch: the recent games in the Dock icon's menu and, when turned on in Settings,
// in a menu bar icon. Picking one launches it as Home would, waking the PC first if needed.

import AppKit

@MainActor
final class MVQuickLaunch: NSObject, NSMenuDelegate {
    /// UserDefaults key of the menu bar icon, off by default: notched MacBooks run out
    /// of menu bar room quickly, and the Dock menu is always there.
    static let menuBarIconKey = "MoonvibeMenuBarIcon"
    /// UserDefaults key: no Dock icon while Moonvibe sits in the menu bar.
    static let hideDockIconKey = "MoonvibeHideDockIcon"

    private weak var model: MVModel?
    private let dockMenu = NSMenu()
    private var statusItem: NSStatusItem?
    private var streaming = false

    init(model: MVModel) {
        self.model = model
        super.init()
        dockMenu.delegate = self
        dockMenu.autoenablesItems = false
        // Qt's application delegate hands its dockMenu property to the Dock, and calls the
        // menu delegate's menuWillOpen: itself since the Dock doesn't
        let setDockMenu = NSSelectorFromString("setDockMenu:")
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: setDockMenu) {
            delegate.perform(setDockMenu, with: dockMenu)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        updateMenuBarIcon()
    }

    /// Opening Moonvibe again (Finder, Spotlight) while it only shows in the menu bar
    /// brings Home back, unless another window of it is already up.
    @objc private func appBecameActive() {
        guard livesInMenuBar, !streaming, let home = model?.window, !home.isVisible,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        home.makeKeyAndOrderFront(nil)
    }

    /// Shows or hides the menu bar icon, following the setting.
    func updateMenuBarIcon() {
        let visible = UserDefaults.standard.bool(forKey: Self.menuBarIconKey)
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: "Moonvibe")
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        updateDockIcon()
    }

    /// Hides the Dock icon when the setting asks for it and the menu bar icon is there to
    /// reach Moonvibe, except during a stream: without a Dock icon, ⌘⇥ couldn't bring the
    /// stream back, and macOS Game Mode only applies to regular apps.
    /// Menu bar icon and no Dock icon: Moonvibe is a menu bar app, which closing Home
    /// doesn't quit.
    var livesInMenuBar: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: Self.menuBarIconKey) && defaults.bool(forKey: Self.hideDockIconKey)
    }

    func updateDockIcon() {
        let hidden = livesInMenuBar && !streaming
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Leaving the Dock deactivates the app: keep its windows in front
        if hidden {
            NSApp.activate()
        }
    }

    /// Home hides when a stream starts and comes back when it ends.
    func setStreaming(_ streaming: Bool) {
        self.streaming = streaming
        updateDockIcon()
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // The Dock menu only gets this one, from Qt
        if menu === dockMenu {
            rebuild(menu)
        }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }

        menu.addItem(.sectionHeader(title: String(localized: "Récents")))
        // Nothing launches while a stream starts or runs
        let streaming = model.busy || self.streaming
        let recents = model.recents.prefix(5)
        if recents.isEmpty {
            let empty = NSMenuItem(title: String(localized: "Aucun jeu récent"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for recent in recents {
            menu.addItem(item(for: recent, in: model, streaming: streaming))
        }

        // The Dock already offers to show and quit the app
        if menu !== dockMenu {
            menu.addItem(.separator())
            let open = NSMenuItem(title: String(localized: "Ouvrir Moonvibe"), action: #selector(showHome), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let quit = NSMenuItem(title: String(localized: "Quitter Moonvibe"), action: #selector(quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
        }
    }

    private func item(for recent: MVRecent, in model: MVModel, streaming: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: recent.appName, action: #selector(launchRecent(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = recent.id

        let computer = model.computers.first { $0.id == recent.computerId }
        let app = computer?.apps.first { $0.id == recent.appId }
        if let computer, let app {
            let symbol = model.settings(of: app, on: computer).symbol ?? app.symbolName
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        let name = computer?.name ?? recent.computerName
        let canWake = computer.map { model.canWake($0) } ?? false
        if computer?.online == true {
            item.subtitle = name
        } else if canWake {
            item.subtitle = String(localized: "\(name) · réveil puis lancement")
        } else {
            item.subtitle = String(localized: "\(name) · hors ligne")
        }
        item.isEnabled = !streaming && computer?.paired == true && (computer?.online == true || canWake)
        return item
    }

    // MARK: Actions

    @objc private func launchRecent(_ sender: NSMenuItem) {
        guard let model, let id = sender.representedObject as? String,
              let recent = model.recents.first(where: { $0.id == id }) else { return }
        // Home shows the launch, or the PC waking up
        showHome()
        model.launch(recent)
    }

    @objc private func showHome() {
        NSApp.activate()
        model?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        model?.sendAction?(["action": "quit"])
    }
}
