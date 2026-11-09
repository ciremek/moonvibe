# Changelog

Moonvibe versions, newest first. Each one builds on [Moonlight PC](https://github.com/moonlight-stream/moonlight-qt): version 6.2 up to Moonvibe 0.5.4, then Moonlight's code of November 5, 2026.

## 0.5.5 · Fresh engine · November 9, 2026

### Improved
- **Moonlight's latest fixes**, up to November 5: a timeout on requests to the PC so a silent PC can't hold Moonvibe up, sturdier video renderers and frame pacing, and safer pairing.
- **The latest streaming engine** (November 3): mouse movements are no longer held back when a lot of input is sent at once, network messages are checked more strictly, and replayed control messages are rejected.

## 0.5.4 · Steady · November 8, 2026

### Fixed
- Moonvibe no longer crashes when a stream starts while a display is going to sleep, waking up or changing setup: the stream keeps the saved resolution instead.

## 0.5.3 · Your call · November 7, 2026

### Improved
- **macOS Game Mode tip** in Settings, Advanced: what Game Mode changes while you stream, and where to turn it off for Moonvibe if the mouse or sound stutters. macOS remembers your choice.

## 0.5.2 · Every detail · October 21, 2026

### New
- **Live latency trace** in the connection test: one bar per measure as it comes in, red for a lost one, so the variation shows at a glance.
- **Pairing celebrates**: once a PC is paired, the check draws itself and stars burst out behind it.

### Improved
- Pairing steps slide in, the PIN digits drop into place, and the search shows the same radio waves as a PC waking up.
- Address tests pop their result, and the app settings' icon and color highlights glide to your pick.
- The quality popover's highlight glides between presets, and the toolbar button rolls its numbers.

## 0.5.1 · Stardust · October 21, 2026

### New
- **Launches burst into stars**: when a stream starts, its tile throws out stars, moons and sparkles in its color.
- **Wake & Go comes alive**: radio waves sweep each time a magic packet goes out, the PC's dot ripples in the sidebar and pops green when it answers, then the tiles light back up one after the other.

### Improved
- The selection outline glides from tile to tile, banners slide in and out, switching PCs fades, and a tile presses in when you launch it.
- With Reduce Motion on, movements turn into fades.

## 0.5.0 · Always up to date · October 21, 2026

### New
- **Automatic updates**: when a new version is out, a badge in the sidebar shows it. Click it to see what's new, and Moonvibe downloads the update, installs it and relaunches. It checks twice a day and never opens a window on its own, so nothing pops up over a stream. **Check Now…** in Settings, Advanced checks right away.
- **Signed updates**: Moonvibe installs an update only if it carries the signature of Moonvibe's key, and macOS no longer asks you to confirm the new version's first launch.
- **A styled DMG**: a background with an arrow to Applications, and bigger icons.

### Coming from 0.4
Download 0.5.0 by hand one last time: from then on, Moonvibe updates itself.

## 0.4.1 · Stay in the loop · October 21, 2026

### New
- **Connection test** in the PC settings: latency, variation (jitter) and loss over about ten seconds, the link this Mac uses (Ethernet, or the Wi-Fi band and channel), and a clear verdict. It works even when the PC's firewall drops pings.
- **Update check**: Moonvibe tells you in the sidebar when a newer version is out, and links to it. It checks GitHub at launch and twice a day, and can be turned off in Settings, Advanced.

## 0.4.0 · Make it yours · October 21, 2026

### New
- **In English**: the interface follows the Mac's language, French or English.
- **PC settings** (right-click a PC): rename it, see its detected addresses, and add several of your own, like Tailscale and WireGuard side by side, each with a test that checks the right PC answers. The wake options moved here.
- **App settings** (right-click an app): a tile icon and color, a quality of its own, and Mac apps to open when its stream starts and quit when it ends.
- Apps that restart themselves with admin rights, like VirtualHere, are quit too.

### Improved
- A quieter interface: settings explanations moved into tooltips, repeated subtitles are gone.
- Dark mode: red and indigo text and outlines, and the "running" badge, now reach at least 5:1 contrast.
- VoiceOver: app tiles launch from VoiceOver, unnamed controls got names, nothing reads twice.

## 0.3.0 · Wake & Go · October 18, 2026

### New
- **Wake & Go**: launching an app on a PC that's off or asleep wakes it up, then launches the app as soon as it answers. The Wake-on-LAN packet goes out again every 10 seconds for 2 minutes, with a timer and a Cancel button on Home.
- **Per-PC wake options**: an editable MAC address and an external target (IP or DDNS name + port) to wake the PC from outside your home network.
- **LAN at home, Tailscale on the go**: Moonvibe uses the PC's local address as soon as the Mac is on its network, and a VPN address no longer replaces the local one.

### Fixed
- Home comes back right away after a stream, instead of waiting up to 30 seconds when the PC stopped answering.
- A PC that falls asleep during a stream shows as offline as soon as you quit, instead of staying online.
- Quitting the app on the PC is skipped when the PC no longer answers.
- Launching a stream while the previous one is still closing shows a message, instead of getting stuck on "Connexion…".

## 0.2.0 · Liquid Glass interface · October 18, 2026

### New
- **SwiftUI interface** on top of the Moonlight engine: Home with your PCs, their apps and recent sessions, search and keyboard shortcuts.
- **Guided pairing** with the PIN to type into Sunshine.
- **Liquid Glass in-stream panels**: a bar with the PC and the app, a live stats card, and a shortcut reminder while the mouse is captured.
- **Settings** in their own window, with a **Perso** (custom) preset saved as soon as you leave the built-in presets.
- **Moonvibe icon** in light and dark.

### Fixed and hardened
- The AWDL rule install is protected against swapped temporary files, and logs are private in `~/Library/Logs/Moonvibe`.
- No more PC polling during streams, or after 5 minutes in the background.
- Presets follow the refresh rate of the display the stream opens on.
- Confirmation before quitting the app running on the PC to launch another one.
- Discord status off by default. macOS 14.4 minimum.
- Upstream fix: the mouse polling rate is no longer reduced.

## 0.1.0 · First steps · October 17, 2026

- **Moonvibe** becomes its own app: separate name, identifier and settings, so it runs alongside the official Moonlight.
- **Auto resolution**: the stream uses the native resolution of the display it opens on.
- **AWDL off while streaming**, optional, to avoid Wi-Fi latency spikes.
