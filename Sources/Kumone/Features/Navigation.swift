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

struct PlayerChromeModifier: ViewModifier {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let metrics = PlayerLayoutMetrics(
                detailWidth: proxy.size.width,
                showsPanel: player.activePanel != nil
            )
            HStack(spacing: 0) {
                content
                    .environment(\.playerChromeClearance, metrics.barClearance)
                    .frame(width: metrics.mainWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        PlayerBar(layout: metrics.barLayout)
                            .frame(width: metrics.barWidth)
                            .padding(.bottom, PlayerLayoutMetrics.barBottomMargin)
                    }
                    .clipped()

                if player.activePanel != nil {
                    trailingPanel
                        .frame(width: metrics.panelWidth)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.primary.opacity(0.08))
                                .frame(width: PlayerLayoutMetrics.dividerWidth)
                        }
                        .padding(.leading, PlayerLayoutMetrics.dividerWidth)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            // Only opening/closing changes the column geometry. Switching
            // lyrics ↔ queue keeps the exact same main-column and bar widths.
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9),
                       value: player.activePanel != nil)
        }
    }

    @ViewBuilder
    private var trailingPanel: some View {
        if let panel = player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel()
                case .queue:
                    QueuePanel()
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: panel)
        }
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

/// Registers all shared navigation destinations on a stack.
struct DestinationsModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Destination.self) { destination in
            Group {
                switch destination {
                case .downloaded:
                    DownloadedMusicView()
                case .downloadTasks:
                    DownloadTasksView()
                case .playlist(let id):
                    PlaylistDetailView(playlistID: id)
                case .radarPlaylist(let id):
                    PlaylistDetailView(playlistID: id, recommendationContext: .radar)
                case .album(let id):
                    AlbumDetailView(albumID: id)
                case .artist(let id):
                    ArtistDetailView(artistID: id)
                case .daily:
                    DailySongsView()
                case .toplists:
                    ToplistsView()
                case .recents:
                    RecentsView()
                case .collections:
                    CollectionsView()
                case .cloud:
                    CloudView()
                case .search(let query):
                    SearchView(query: query)
                }
            }
        }
    }
}

extension View {
    func playerChrome() -> some View {
        modifier(PlayerChromeModifier())
    }

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
