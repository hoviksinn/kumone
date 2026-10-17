import SwiftUI

// MARK: - Queue panel

struct QueuePanel: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let current = player.currentTrack {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        sectionLabel("正在播放")
                        QueueRow(track: current, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            sectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(Array(player.upcomingTracks.prefix(100).enumerated()),
                                    id: \.offset) { index, track in
                                QueueRow(track: track, isCurrent: false, upcomingIndex: index)
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                EmptyStateView(icon: "list.bullet", title: "播放队列是空的",
                               subtitle: "播放一些音乐吧")
            }
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack {
            Text("播放队列")
                .font(.headline)
            Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                player.activePanel = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    var upcomingIndex: Int? = nil

    @EnvironmentObject private var player: PlayerService
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                guard !isCurrent else { return }
                if let upcomingIndex { player.jumpToUpcoming(at: upcomingIndex, matching: track.id) }
                else { player.jumpTo(track) }
            } label: {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(isCurrent ? Theme.accent : .primary)
                            .lineLimit(1)
                        Text(track.artistNames)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            TrackDownloadButton(track: track, isVisible: isHovering)

            ZStack {
                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else if isHovering {
                    Button {
                        if let upcomingIndex { player.removeUpcoming(at: upcomingIndex, matching: track.id) }
                        else { player.removeFromUpcoming(track) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("移除")
                    .help("移除")
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(width: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(isHovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.standard))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
