import SwiftUI

struct AlbumDetailView: View {
    let albumID: Int

    @State private var album: AlbumDetail?
    @State private var tracks: [Track] = []
    @State private var otherAlbums: [AlbumSummary] = []
    @State private var isSubscribed = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showFullDescription = false
    @State private var loadGeneration = 0
    @ObservedObject private var downloads = DownloadManager.shared

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore

    /// Only a collection with songs to show may replace the online page,
    /// otherwise an empty list would hide the error and its retry button.
    private var savedCollectionID: String? {
        let id = "album:\(albumID)"
        return downloads.downloadedSongs(in: id).isEmpty ? nil : id
    }

    var body: some View {
        Group {
            if let savedCollectionID, !downloads.network.connected || errorMessage != nil {
                DownloadedMusicView(collectionID: savedCollectionID)
            } else { onlineContent }
        }
        .task(id: "\(albumID):\(downloads.network.connected)") {
            if downloads.network.connected || savedCollectionID == nil { await load() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if errorMessage != nil, downloads.network.connected, album != nil || savedCollectionID != nil {
                HStack {
                    Spacer()
                    Button { Task { await load() } } label: { Label("重试", systemImage: "arrow.clockwise") }
                        .buttonStyle(.plain).padding(10)
                }
                .background(.regularMaterial)
            }
        }
    }

    private var onlineContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let album {
                    regularHeader(album)
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, 16)

                    TrackListView(
                        tracks: tracks,
                        source: .album(albumID),
                        context: .album(id: albumID, name: album.name)
                    )
                    .padding(.horizontal, Theme.Layout.contentInset - 10)

                    if !otherAlbums.isEmpty {
                        SectionHeader(title: "该歌手的其他专辑")
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 12)

                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                                ForEach(otherAlbums) { item in
                                    NavigationLink(value: Destination.album(item.id)) {
                                        CoverCardBody(
                                            coverURL: item.picUrl?.resizedImageURL(384),
                                            title: item.name,
                                            subtitle: Formatters.date(fromMS: item.publishTime)
                                        )
                                    }
                                    .buttonStyle(.interactiveCard)
                                    .navigationCardLink()
                                }
                                Spacer().frame(width: (Theme.Layout.contentInset) - 16)
                            }
                        }
                        .scrollIndicators(.never, axes: .horizontal)
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) {
                        Task { await load() }
                    }
                    .frame(minHeight: 400)
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle(album?.name ?? String(localized: "专辑"))
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let response = try await NeteaseAPI.album(id: albumID)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            album = response.album
            tracks = response.songs
            isLoading = false
            if let dynamic = try? await NeteaseAPI.albumDynamic(id: albumID) {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                isSubscribed = dynamic.isSub ?? false
            }
            if let artistID = response.album.artist?.id,
               let albums = try? await NeteaseAPI.artistAlbums(id: artistID, limit: 12) {
                guard generation == loadGeneration, !Task.isCancelled else { return }
                otherAlbums = albums.hotAlbums.filter { $0.id != albumID }
            }
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Regular Header

    private func regularHeader(_ album: AlbumDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: album.picUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(album.subType?.isEmpty == false ? album.subType! : String(localized: "专辑"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(album.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let artist = album.artist {
                    NavigationLink(value: Destination.artist(artist.id)) {
                        Text(artist.name)
                            .font(.system(size: 14, weight: .medium))
                    }
                    .navigationTextLink(color: Theme.accent)
                }

                Text("\(tracks.count) 首 · \(totalDuration) · \(Formatters.date(fromMS: album.publishTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = album.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .navigationTextLink()
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: tracks, source: .album(albumID),
                                context: .album(id: albumID, name: album.name))
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)

                    DownloadCollectionButton(tracks: tracks, owner: "album:\(albumID)", name: album.name)

                    if account.isLoggedIn {
                        Button {
                            toggleSubscribe()
                        } label: {
                            Label(isSubscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                                  systemImage: isSubscribed ? "checkmark" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private var totalDuration: String {
        let totalMS = tracks.reduce(into: 0) { $0 += $1.durationMS }
        return Formatters.longDuration(TimeInterval(totalMS) / 1000)
    }

    private func toggleSubscribe() {
        Task {
            do {
                try await NeteaseAPI.subscribeAlbum(id: albumID, subscribe: !isSubscribed)
                isSubscribed.toggle()
                ToastCenter.shared.show(isSubscribed ? String(localized: "已收藏专辑") : String(localized: "已取消收藏"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            SkeletonView(cornerRadius: Theme.Radius.large)
                .frame(width: 200, height: 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 16)
    }
}
