import SwiftUI

extension Notification.Name {
    static let showDownloadedMusic = Notification.Name("Kumone.showDownloadedMusic")
}

private struct OpenLoginKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (Destination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLogin: () -> Void {
        get { self[OpenLoginKey.self] }
        set { self[OpenLoginKey.self] = newValue }
    }

    var openDestination: (Destination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

private struct PlayerChromeClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = Theme.Layout.playerChromeClearance
}

extension EnvironmentValues {
    var playerChromeClearance: CGFloat {
        get { self[PlayerChromeClearanceKey.self] }
        set { self[PlayerChromeClearanceKey.self] = newValue }
    }
}

enum SidebarItem: Hashable {
    case downloaded
    case home
    case explore
    case fm
    case search
    case likedSongs
    case daily
    case recents
    case collections
    case cloud
    case playlist(Int)
}

enum Destination: Hashable {
    case downloaded, downloadTasks
    case playlist(Int)
    case radarPlaylist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case toplists
    case recents
    case collections
    case cloud
    case search(String)
}

extension Array where Element == Destination {
    mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}

/// Shared destination leaf; window-level controls are never created here.
struct DestinationContent: View {
    let destination: Destination
    @ViewBuilder var body: some View {
        switch destination {
        case .downloaded: DownloadedMusicView()
        case .downloadTasks: DownloadTasksView()
        case .playlist(let id): PlaylistDetailView(playlistID: id)
        case .radarPlaylist(let id): PlaylistDetailView(playlistID: id, recommendationContext: .radar)
        case .album(let id): AlbumDetailView(albumID: id)
        case .artist(let id): ArtistDetailView(artistID: id)
        case .daily: DailySongsView()
        case .toplists: ToplistsView()
        case .recents: RecentsView()
        case .collections: CollectionsView()
        case .cloud: CloudView()
        case .search(let query): SearchView(query: query)
        }
    }
}

struct DestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { DestinationContent(destination: $0) }
    }
}

extension View {
    func appDestinations() -> some View {
        modifier(DestinationsModifier())
    }
}

/// Trailing spacer for scrollable pages so the last row clears the
/// floating player bar.
struct PlayerClearanceSpacer: View {
    @Environment(\.playerChromeClearance) private var clearance

    var body: some View {
        Color.clear.frame(
            height: clearance + Theme.Layout.scrollBreathingMargin
        )
    }
}
