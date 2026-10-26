import AppKit
import SwiftUI

/// Content for the window's shared trailing region. Its parent owns the
/// width/material and animated expansion, so queue/lyrics exchange in place.
struct QueuePanel: View {
    @EnvironmentObject private var player: PlayerService
    @State private var selectedID: QueuePanelEntry.ID?
    @State private var currentSelected = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if let current = player.currentTrack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        sectionLabel("正在播放")
                        QueueRow(track: current, isCurrent: true, isSelected: currentSelected,
                                 select: { selectedID = nil; currentSelected = true }, activate: {}, remove: nil)

                        if !player.upcomingQueueEntries.isEmpty {
                            sectionLabel("即将播放")
                                .padding(.top, 16)
                            ForEach(player.upcomingQueueEntries.prefix(100)) { entry in
                                QueueRow(track: entry.track, isCurrent: false, isSelected: selectedID == entry.id,
                                         select: { selectedID = entry.id; currentSelected = false },
                                         activate: { player.jumpToQueueEntry(entry) },
                                         remove: { player.removeQueueEntry(entry) })
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
            } else {
                EmptyStateView(icon: "list.bullet", title: "播放队列是空的",
                               subtitle: "播放一些音乐吧")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: player.queueRevision) {
            // A changed queue retires its selection instead of accidentally
            // highlighting the following duplicate at the same array offset.
            selectedID = nil
            currentSelected = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("播放队列").font(.headline)
            Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    let isSelected: Bool
    let select: () -> Void
    let activate: () -> Void
    let remove: (() -> Void)?

    @EnvironmentObject private var player: PlayerService
    @State private var hovering = false
    @State private var keyboardFocused = false

    var body: some View {
        HStack(spacing: 5) {
            // Only the song body receives AppKit clicks. Its sibling download
            // and delete buttons cannot bubble a click into row playback.
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
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
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Rectangle())
            .overlay {
                QueueRowMouseTarget(label: "\(track.name)，\(track.artistNames)",
                                    select: select, activate: isCurrent ? {} : activate,
                                    focusChanged: { keyboardFocused = $0 })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(track.name)，\(track.artistNames)")
            .accessibilityValue(isCurrent ? "正在播放" : (isSelected ? "已选中" : ""))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction { select() }
            .accessibilityAction(named: "播放") { if !isCurrent { activate() } }

            TrackDownloadButton(track: track, isVisible: hovering || isSelected)

            if isCurrent {
                PlayingIndicator(animating: player.isPlaying).frame(width: 36)
            } else if let remove {
                QueueRemoveButton(action: remove, isVisible: hovering || isSelected,
                                  duration: Formatters.duration(track.duration))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.15) : Color.primary.opacity(hovering ? 0.055 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                .strokeBorder(Theme.accent.opacity(keyboardFocused ? 0.8 : (isSelected ? 0.35 : 0)), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onHover { hovering = $0 }
    }
}

private struct QueueRemoveButton: View {
    let action: () -> Void
    let isVisible: Bool
    let duration: String
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(duration)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .opacity(isVisible || hovering || focused ? 0 : 1)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering || focused ? .primary : .secondary)
                    .opacity(isVisible || hovering || focused ? 1 : 0)
            }
            .frame(width: 36, height: 36)
            .background(.primary.opacity(hovering || focused ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .focused($focused)
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("从队列移除")
        .help("从队列移除")
    }
}

/// Uses AppKit's native clickCount instead of competing single/double tap
/// recognizers. The first click selects immediately, the second activates
/// exactly once; triple clicks do not issue another play command.
struct QueueRowMouseTarget: NSViewRepresentable {
    let label: String
    let select: () -> Void
    let activate: () -> Void
    var focusChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ClickView { ClickView() }

    func updateNSView(_ view: ClickView, context: Context) {
        view.select = select
        view.activate = activate
        view.focusChanged = focusChanged
        view.setAccessibilityLabel(label)
    }

    final class ClickView: NSView {
        var select: () -> Void = {}
        var activate: () -> Void = {}
        var focusChanged: (Bool) -> Void = { _ in }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { focusChanged(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { focusChanged(false) }
            return accepted
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            switch QueueRowClickAction.action(clickCount: event.clickCount) {
            case .select: select()
            case .activate: activate()
            case .none: break
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { activate() }
            else if event.keyCode == 49 { select() }
            else { super.keyDown(with: event) }
        }
    }
}
