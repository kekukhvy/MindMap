import SwiftUI

/// One map on the Welcome screen: thumbnail (lock for locked maps), name,
/// location and modified date. Click / tap opens it.
struct WelcomeMapRow: View {
    let url: URL
    let title: String
    let detail: String
    let location: String
    let isLocked: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MapThumbnailView(url: url, isLocked: isLocked)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
        .accessibilityLabel("\(title), \(location), \(detail)")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            WelcomeDebug.rowFrames[LaunchEnvironment.key(url)] = frame
        }
        #endif
    }
}

/// Thumbnail of a map (rendered once per change, `MapThumbnails`).
struct MapThumbnailView: View {
    let url: URL
    let isLocked: Bool
    @State private var image: CGImage?

    private static let size = CGSize(width: 66, height: 42)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(isLocked ? Color.orange.opacity(0.12) : Color.white)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
            } else if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .task(id: url) {
            guard !isLocked else { return }
            image = MapThumbnails.shared.cached(for: url)
            if image == nil { image = await MapThumbnails.shared.thumbnail(for: url) }
        }
    }
}

#if DEBUG
/// Row frames (window coordinates, top-left origin) for the event tests.
@MainActor
enum WelcomeDebug {
    static var rowFrames: [String: CGRect] = [:]
}
#endif
