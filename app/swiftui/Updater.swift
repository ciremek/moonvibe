// Updates through Sparkle. Info.plist's SUFeedURL points at the appcast published with each
// GitHub release: Sparkle checks it twice a day, checks the EdDSA signatures of the appcast
// and of the DMG against SUPublicEDKey, then installs the new version and relaunches Moonvibe.
//
// Sparkle never opens a window on its own: a scheduled check that finds an update only shows
// the badge in Home's sidebar, and Sparkle's window opens when the badge is clicked. Nothing
// pops up over a stream.

import Sparkle

@MainActor
final class MVUpdater: NSObject {
    /// The on/off setting of the update check before Sparkle (0.4), carried over once.
    private static let legacyEnabledKey = "MoonvibeCheckForUpdates"

    private weak var model: MVModel?
    private var controller: SPUStandardUpdaterController!

    init(model: MVModel) {
        self.model = model
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        if let enabled = UserDefaults.standard.object(forKey: Self.legacyEnabledKey) as? Bool {
            if !enabled {
                controller.updater.automaticallyChecksForUpdates = false
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyEnabledKey)
        }
        controller.startUpdater()
    }

    /// Stored by Sparkle in UserDefaults as SUEnableAutomaticChecks, on by default (Info.plist).
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Opens Sparkle's window on the update the badge shows, or checks for one.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension MVUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Even right after launch: the badge is enough, and a stream may start any second.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        model?.availableUpdate = update.displayVersionString
    }

    /// Installed, postponed or skipped: the badge goes until the next check finds it again.
    func standardUserDriverWillFinishUpdateSession() {
        model?.availableUpdate = nil
    }

    /// The notes cover every version since 0.5.0 (scripts/make-appcast.py): only the ones
    /// newer than this copy stay.
    func standardUserDriverWillShowReleaseNotesText(_ releaseNotes: NSAttributedString, forUpdate update: SUAppcastItem,
                                                   withBundleDisplayVersion bundleDisplayVersion: String,
                                                   bundleVersion: String) -> NSAttributedString? {
        let text = releaseNotes.string as NSString
        var cut: Int?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { paragraph, range, _, stop in
            // Version headings read "0.6.0 · Check-up · November 9, 2026"
            guard let version = paragraph?.components(separatedBy: " · ").first,
                  version.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil else { return }
            if SUStandardVersionComparator.default.compareVersion(version, toVersion: bundleVersion) != .orderedDescending {
                cut = range.location
                stop.pointee = true
            }
        }
        guard let cut else { return nil }
        return releaseNotes.attributedSubstring(from: NSRange(location: 0, length: cut))
    }
}
