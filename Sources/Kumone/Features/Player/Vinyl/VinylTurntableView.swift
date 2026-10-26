import SwiftUI

/// Complete interactive turntable stage combining rotating vinyl disc, tonearm,
/// continuous timeline rotation, tap-to-flip, and horizontal swipe-to-switch tracks.
public struct VinylTurntableView: View {
    public let artworkImage: PlatformImage?
    public let isPlaying: Bool
    public let trackId: Int?
    public let size: CGFloat
    public var onTap: (() -> Void)? = nil
    public var onNextTrack: (() -> Void)? = nil
    public var onPreviousTrack: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationState = RecordRotationState()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isTransitioningTrack = false
    @State private var trackChangeTask: Task<Void, Never>?

    public init(
        artworkImage: PlatformImage?,
        isPlaying: Bool,
        trackId: Int? = nil,
        size: CGFloat = 280,
        onTap: (() -> Void)? = nil,
        onNextTrack: (() -> Void)? = nil,
        onPreviousTrack: (() -> Void)? = nil
    ) {
        self.artworkImage = artworkImage
        self.isPlaying = isPlaying
        self.trackId = trackId
        self.size = size
        self.onTap = onTap
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
    }

    public var body: some View {
        let discSize = size
        let armHeight = discSize * 0.68
        let stageWidth = discSize + 48
        let stageHeight = discSize + armHeight * 0.38

        return ZStack(alignment: .top) {
            // MARK: 1. Rotating Vinyl Disc (with horizontal drag & slide transitions)
            TimelineView(.animation(paused: !isPlaying || reduceMotion || isDragging || isTransitioningTrack)) { timeline in
                let currentAngle = rotationState.currentAngle(at: timeline.date)

                VinylRecordView(artworkImage: artworkImage, size: discSize)
                    .rotationEffect(.degrees(currentAngle))
            }
            .offset(x: dragOffset)
            .padding(.top, armHeight * 0.36)
            .contentShape(Circle())
            .gesture(dragAndSwipeGesture(discSize: discSize))
            .onTapGesture {
                onTap?()
            }
            .zIndex(1)

            // MARK: 2. Tonearm (Placed at the top-center above the disc, reaching down)
            VinylTonearmView(
                isPlaying: isPlaying && !isDragging && !isTransitioningTrack,
                height: armHeight,
                reduceMotion: reduceMotion
            )
            .offset(x: discSize * 0.12, y: -armHeight * 0.08)
            .allowsHitTesting(false)
            .zIndex(2)
        }
        .frame(width: stageWidth, height: stageHeight, alignment: .top)
        .onAppear { synchronizeRotation() }
        .onChange(of: isPlaying) { _, _ in synchronizeRotation() }
        .onChange(of: reduceMotion) { _, _ in synchronizeRotation() }
        .onDisappear {
            rotationState.stop(at: Date())
            trackChangeTask?.cancel()
            isTransitioningTrack = false
        }
        .onChange(of: trackId) { _, _ in
            trackChangeTask?.cancel()
            guard !reduceMotion else { isTransitioningTrack = false; return }
            isTransitioningTrack = true
            trackChangeTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(320)) }
                catch { return }
                isTransitioningTrack = false
            }
        }
    }

    private func synchronizeRotation() {
        if isPlaying && !reduceMotion {
            rotationState.start(at: Date())
        } else {
            // Freeze the current angle; resuming Reduce Motion must not
            // accumulate an invisible wall-time rotation or reset the disc.
            rotationState.stop(at: Date())
        }
    }

    // MARK: - Gestures

    private func dragAndSwipeGesture(discSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only track horizontal gestures
                if abs(value.translation.width) > abs(value.translation.height) * 0.6 {
                    isDragging = true
                    let raw = value.translation.width
                    // Damped elastic feel
                    dragOffset = raw
                }
            }
            .onEnded { value in
                if reduceMotion {
                    if value.translation.width < -45 || value.predictedEndTranslation.width < -100 {
                        onNextTrack?()
                    } else if value.translation.width > 45 || value.predictedEndTranslation.width > 100 {
                        onPreviousTrack?()
                    }
                    dragOffset = 0
                    isDragging = false
                    return
                }
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width
                let swipeThreshold: CGFloat = 45

                if translation < -swipeThreshold || velocity < -100 {
                    // Swipe Left -> Next Track (下一首)
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                        dragOffset = -discSize * 1.25
                    }
                    onNextTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = discSize * 1.25
                        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else if translation > swipeThreshold || velocity > 100 {
                    // Swipe Right -> Previous Track (上一首)
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.20)) {
                        dragOffset = discSize * 1.25
                    }
                    onPreviousTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = -discSize * 1.25
                        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else {
                    // Reset back to center
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.76)) {
                        dragOffset = 0
                        isDragging = false
                    }
                }
            }
    }
}
