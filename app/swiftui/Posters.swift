// Poster tiles: the 3:4 cover each app gets on Home. A poster picked on this Mac comes
// first, then the cover the PC serves (unless Moonvibe's own posters are preferred), then
// one drawn from the tile's icon and color. Sunshine and Apollo serve a small grey
// placeholder (130×180) for an app without a cover, which counts as none.

import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// How Home draws the apps' tiles.
enum MVTileStyle: String, CaseIterable, Identifiable {
    /// The covers the PC serves, else Moonvibe's posters.
    case covers
    /// Moonvibe's posters, drawn from each tile's icon and color.
    case drawn
    /// 4:3 tiles with an icon.
    case icons

    static let key = "MoonvibeTileStyle"

    var id: String { rawValue }
    var posters: Bool { self != .icons }

    var label: String {
        switch self {
        case .covers: return String(localized: "Jaquettes du PC")
        case .drawn: return String(localized: "Affiches Moonvibe")
        case .icons: return String(localized: "Icônes")
        }
    }
}

enum MVPosters {
    /// Posters picked on this Mac: ~/Library/Application Support/Moonvibe/Posters.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvibe/Posters", isDirectory: true)
    }

    /// Covers served by PCs narrower than this are placeholders.
    static let placeholderMaxWidth = 200

    /// Copies an image into the posters folder, scaled down to what a tile needs, under a
    /// new name: the sheet that picked it keeps the previous poster until it's saved.
    static func importImage(at url: URL, for computer: MVComputer) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try importImage(from: source, for: computer)
    }

    /// The same, for an image downloaded rather than picked.
    static func importImage(data: Data, for computer: MVComputer) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return try importImage(from: source, for: computer)
    }

    private static func importImage(from source: CGImageSource, for computer: MVComputer) throws -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(computer.id)-\(UUID().uuidString.prefix(8)).png"
        let destinationURL = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return name
    }

    /// Deletes the posters no app uses anymore: replaced, removed, or of a deleted PC.
    static func prune(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

/// A decoded poster, and the color of the light it casts.
struct MVPosterImage {
    let image: NSImage
    let glow: Color
}

/// Decodes each poster file once per version.
@MainActor
final class MVPosterCache {
    static let shared = MVPosterCache()

    private var entries: [String: (stamp: Double, poster: MVPosterImage?)] = [:]
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// The poster at this path, decoded again when its stamp changes. Nil when it can't be
    /// read or is narrower than minWidth.
    func poster(atPath path: String, stamp: Double, minWidth: Int = 0) -> MVPosterImage? {
        if let entry = entries[path], entry.stamp == stamp {
            return entry.poster
        }
        let poster = load(path, minWidth: minWidth)
        entries[path] = (stamp, poster)
        return poster
    }

    private func load(_ path: String, minWidth: Int) -> MVPosterImage? {
        guard let image = NSImage(contentsOfFile: path),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > minWidth else { return nil }
        return MVPosterImage(image: image, glow: glow(of: cgImage))
    }

    /// The poster's average color, livened up: an average tends to come out muddy.
    private func glow(of cgImage: CGImage) -> Color {
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return mvAccent }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        return Color(hue: average.hueComponent,
                     saturation: min(1, average.saturationComponent * 1.4),
                     brightness: max(0.6, average.brightnessComponent))
    }
}

extension MVModel {
    /// The image on an app's poster: picked on this Mac, else the cover the PC serves when
    /// the style shows them. Nil for a drawn poster.
    func poster(of app: MVApp, on computer: MVComputer, settings: MVAppSettings? = nil,
                style: MVTileStyle) -> MVPosterImage? {
        guard style.posters else { return nil }
        let settings = settings ?? self.settings(of: app, on: computer)
        // Picked posters get a new name each time, so their stamp never needs to change
        if let name = settings.poster,
           let poster = MVPosterCache.shared.poster(atPath: MVPosters.directory.appendingPathComponent(name).path, stamp: 0) {
            return poster
        }
        guard style == .covers, let path = app.boxArt else { return nil }
        return MVPosterCache.shared.poster(atPath: path, stamp: app.boxArtDate ?? 0,
                                           minWidth: MVPosters.placeholderMaxWidth)
    }
}

/// An app's 3:4 poster: its cover, or one drawn from its icon and color.
struct MVPoster: View {
    let app: MVApp
    let settings: MVAppSettings
    let poster: MVPosterImage?
    var launching = false

    static let cornerRadius: CGFloat = 16

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let poster {
                    Image(nsImage: poster.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .modifier(MVLaunchBreath(active: launching))
                } else {
                    drawn
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                // A hairline keeps dark covers from melting into a dark window
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
    }

    /// A night sky in the tile's color, its icon, and the name in capitals.
    private var drawn: some View {
        ZStack {
            if let tint = settings.color?.color {
                Color.black
                LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(hex: 0x4F5BD5), Color(hex: 0x1B1E33)], startPoint: .top, endPoint: .bottom)
            }
            // Moonlight from the top corner
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 180)

            VStack(spacing: 12) {
                Image(systemName: settings.symbol ?? app.symbolName)
                    .font(.system(size: 36, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: .repeating, isActive: launching)
                Text(app.name.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.5)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
    }
}

/// While its stream starts, a cover breathes, as an icon pulses.
private struct MVLaunchBreath: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([1.0, 0.65]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        } else {
            content
        }
    }
}
