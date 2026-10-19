import SwiftUI

/// One stable window shell owns the player and inspector. NavigationStack
/// replaces only the middle leaf; it can never replace the floating player.
struct MainWindow: View {
    private let externalPath: Binding<[Destination]>?
    private let testing: MainWindowTestConfiguration?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var toasts: ToastCenter
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @StateObject private var panels: WindowPanelCoordinator
    @State private var selection: SidebarItem = .home
    @State private var localPath: [Destination] = []
    @State private var showLogin = false
    @State private var middleFrame: CGRect = .zero
    @State private var localColumnVisibility: NavigationSplitViewVisibility
    @State private var topChromeVisible = true
    @State private var topChromeHovering = false
    @State private var searchFocused = false
    @State private var topPopoverOpen = false
    @State private var menuTracking = false
    @FocusState private var topControlsFocused: Bool
    @State private var chromeTask: Task<Void, Never>?

    init(path: Binding<[Destination]>? = nil, testing: MainWindowTestConfiguration? = nil) {
        externalPath = path
        self.testing = testing
        _panels = StateObject(wrappedValue: testing?.panelCoordinator ?? WindowPanelCoordinator())
        _localColumnVisibility = State(initialValue: testing?.initialColumnVisibility ?? .all)
    }

    private var path: [Destination] {
        get { externalPath?.wrappedValue ?? localPath }
        nonmutating set {
            if let externalPath { externalPath.wrappedValue = newValue }
            else { localPath = newValue }
        }
    }
    private var pathBinding: Binding<[Destination]> { externalPath ?? $localPath }
    private var columnVisibility: NavigationSplitViewVisibility {
        get { testing?.liveColumnVisibility?.wrappedValue ?? localColumnVisibility }
        nonmutating set {
            if let binding = testing?.liveColumnVisibility { binding.wrappedValue = newValue }
            else { localColumnVisibility = newValue }
        }
    }
    private var sidebarCollapsed: Bool { columnVisibility == .detailOnly }
    private var hidesTopChrome: Bool { player.showNowPlaying || sidebarCollapsed }

    var body: some View {
        chromeObservedWindow
            .onDisappear { chromeTask?.cancel() }
            .sheet(isPresented: $showLogin) { LoginSheet() }
            .alert("窗口空间不足", isPresented: $panels.insufficientSpace) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("完整单排播放栏与右侧面板需要更多空间。请放大窗口，或手动收起左侧导航栏后再打开歌词或播放队列。")
            }
            .overlay(alignment: .top) {
                if let toast = toasts.current {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 12)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 1), value: panels.insideReveal)
            .animation(reduceMotion ? nil : AppAnimation.smooth, value: player.showNowPlaying)
            .animation(reduceMotion ? nil : AppAnimation.quick, value: topChromeVisible)
    }

    /// Opaque, statically typed stages keep the compiler's inference local.
    /// State and the unique player remain owned by this same MainWindow.
    private var windowLayout: some View {
        GeometryReader { geometry in
            let outside = panels.mode == .expandedOutside
            let reveal = outside
                ? min(panels.addedWidth, max(0, geometry.size.width - panels.baseContentWidth))
                : panels.insideReveal
            let navigationWidth = outside ? panels.baseContentWidth : max(0, geometry.size.width - reveal)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    navigationColumns
                        .frame(width: navigationWidth)
                    panelRegion(reveal: reveal, outside: outside)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)

                // Deliberately OUTSIDE the entire navigation split. This
                // single instance survives every destination push and pop.
                PlayerBar()
                    .frame(width: PlayerLayoutMetrics.barWidth(in: middleFrame.width))
                    .position(x: middleFrame.midX,
                              y: geometry.size.height - PlayerLayoutMetrics.barBottomMargin - PlayerLayoutMetrics.barHeight / 2)
                    .opacity(player.showNowPlaying ? 0 : 1)
                    .allowsHitTesting(!player.showNowPlaying)
                    .accessibilityHidden(player.showNowPlaying)

                if player.showNowPlaying {
                    immersiveContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                        .zIndex(2)
                }
            }
            .coordinateSpace(name: "mainWindow")
            .onContinuousHover { phase in
                if case .active(let point) = phase {
                    if player.showNowPlaying || (sidebarCollapsed && point.y < 56) { revealChrome() }
                }
            }
        }
    }

    private var configuredWindow: some View {
        windowLayout
        .scrollIndicators(.automatic)
        .toolbar(.hidden, for: .windowToolbar)
        .background(MainWindowConfigurator(
            ambientConfiguration: MainWindowAmbientConfiguration(
                showsAmbientBackground: settings.showMainWindowAmbientBackground,
                showsTitlebarAmbientBackground: !player.showNowPlaying,
                showsNowPlaying: player.showNowPlaying,
                colors: artworkStore.colors,
                mainColumnLeadingInset: middleFrame.minX,
                intensity: settings.mainWindowAmbientBackgroundIntensity,
                isDark: isDarkAppearance),
            panels: panels, registersApplicationWindow: testing == nil))
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }))
        .modifier(MeteredDownloadAlert())
        .environment(\.openLogin, { showLogin = true })
        .environment(\.openDestination, openDestination)
        .environmentObject(artworkStore)
    }

    private var panelObservedWindow: some View {
        configuredWindow
        .onReceive(NotificationCenter.default.publisher(for: .showDownloadedMusic)) { _ in
            guard SongDownloadUI.isAvailable else { return }
            player.showNowPlaying = false
            selection = .downloaded
            path = []
        }
        .task {
            panels.reduceMotion = reduceMotion
            guard testing == nil else { return }
            AppDelegate.shared?.openMainWindow = { openWindow(id: "main") }
            artworkStore.setArtworkNeeded(needsCurrentArtwork)
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
            await DownloadManager.shared.start()
            if KumonePaths.isOfflineUITest, SongDownloadUI.isAvailable { selection = .downloaded }
            await account.bootstrap()
        }
        .onChange(of: player.activePanel) { _, panel in
            let accepted = panels.request(panel, mainWidth: middleFrame.width)
            if !accepted { player.activePanel = nil }
        }
        .onChange(of: panels.mode) { _, mode in
            if mode == .closed, player.activePanel != nil { player.activePanel = nil }
        }
        .onChange(of: panels.insufficientSpace) { _, insufficient in
            if insufficient { player.activePanel = nil }
        }
        .onChange(of: reduceMotion) { _, value in panels.reduceMotion = value }
    }

    private var artworkObservedWindow: some View {
        panelObservedWindow
        .onChange(of: voiceOverEnabled) { _, _ in revealChrome() }
        .onChange(of: settings.showDesktopLyrics) { _, _ in
            guard testing == nil else { return }
            DesktopLyricsController.shared.sync(with: settings.showDesktopLyrics)
        }
        .onChange(of: settings.showMainWindowAmbientBackground) { _, _ in
            if testing == nil { artworkStore.setArtworkNeeded(needsCurrentArtwork) }
        }
        .onChange(of: player.hasCurrentTrack) { _, _ in
            if testing == nil { artworkStore.setArtworkNeeded(needsCurrentArtwork) }
        }
        .onChange(of: player.showNowPlaying) { _, _ in
            if testing == nil { artworkStore.setArtworkNeeded(needsCurrentArtwork) }
            // Focus belongs to the visible page. A search field underneath
            // the immersive overlay must not consume keys or pin its header.
            searchFocused = false
            topControlsFocused = false
            topChromeHovering = false
            if player.showNowPlaying { panels.window?.makeFirstResponder(nil) }
            revealChrome()
        }
    }

    private var chromeObservedWindow: some View {
        artworkObservedWindow
        .onChange(of: columnVisibility) { _, _ in revealChrome() }
        .onChange(of: searchFocused) { _, _ in revealChrome() }
        .onChange(of: topControlsFocused) { _, _ in revealChrome() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuTracking = true
            revealChrome()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuTracking = false
            revealChrome()
        }
        .onKeyPress(phases: .down) { (_: KeyPress) -> KeyPress.Result in
            if hidesTopChrome { revealChrome() }
            return KeyPress.Result.ignored
        }
    }

    private var navigationColumns: some View {
        // NavigationSplitView can promote a nested stack's destination to
        // replace its whole detail column, including sibling chrome. A native
        // split without navigation ownership keeps this middle shell stable.
        HSplitView {
            if !sidebarCollapsed {
                SidebarView(selection: $selection, showLogin: $showLogin)
                    .frame(minWidth: 200, idealWidth: Theme.Layout.sidebarWidth, maxWidth: 280)
            }
            middleColumn
        }
    }

    private var middleColumn: some View {
        VStack(spacing: 0) {
            middleHeader
                .frame(height: 44)
                .background(WindowChromeProbe(identifier: "QieTing.MainHeader"))
            detailStack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: PlayerLayoutMetrics.minimumMainWidth)
        .background(WindowChromeProbe(identifier: "QieTing.MainColumn"))
        .background {
            if settings.showMainWindowAmbientBackground {
                MainWindowAmbientBackground(colors: artworkStore.colors,
                                            intensity: settings.mainWindowAmbientBackgroundIntensity)
            }
        }
        .environment(\.playerChromeClearance, PlayerLayoutMetrics.barClearance)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("mainWindow")) } action: { middleFrame = $0 }
    }

    private var middleHeader: some View {
        HStack(spacing: 10) {
            Button {
                columnVisibility = sidebarCollapsed ? .all : .detailOnly
            } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.plain).frame(width: 28, height: 28).focused($topControlsFocused).help("显示或隐藏侧边栏")
            Button { if !path.isEmpty { path.removeLast() } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).frame(width: 28, height: 28).focused($topControlsFocused).disabled(path.isEmpty).help("返回")
            Spacer(minLength: 8)
            SearchFieldView(isActive: !player.showNowPlaying, loadDefaultKeyword: testing == nil,
                            onFocusChanged: { searchFocused = $0 }) { query in
                path.append(.search(query))
            }
        }
        .padding(.horizontal, 12)
        .opacity(!sidebarCollapsed || topChromeVisible ? 1 : 0)
        .allowsHitTesting(!sidebarCollapsed || topChromeVisible)
        .accessibilityHidden(sidebarCollapsed && !topChromeVisible)
        .onHover { topChromeHovering = $0; revealChrome() }
    }

    @ViewBuilder private func panelRegion(reveal: CGFloat, outside: Bool) -> some View {
        if panels.hasPanel {
            HStack(spacing: 0) {
                Rectangle().fill(.primary.opacity(0.08)).frame(width: PlayerLayoutMetrics.dividerWidth)
                Group {
                    if !player.showNowPlaying, let panel = panels.panel {
                        switch panel {
                        case .lyrics: LyricsPanel()
                        case .queue: QueuePanel()
                        }
                    } else { Color.clear }
                }
                .frame(width: panels.panelWidth)
                .background(.regularMaterial)
            }
            .frame(width: panels.addedWidth)
            .offset(x: outside ? reveal - panels.addedWidth : 0)
            .frame(width: max(0, reveal), alignment: .leading)
            .clipped()
            .background(WindowChromeProbe(identifier: "QieTing.RightPanel"))
        }
    }

    private var immersiveContent: some View {
        NowPlayingView(onOpenDestination: openDestination)
            .background(WindowChromeProbe(identifier: "QieTing.Immersive"))
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 48) }
            .background(ArrowCursorOverride())
            .overlay(alignment: .top) {
                HStack {
                    Button { player.showNowPlaying = false } label: {
                        Image(systemName: "chevron.down").frame(width: 30, height: 30)
                    }.buttonStyle(.pressable).focused($topControlsFocused).help("返回主界面")
                    Button { panels.window?.toggleFullScreen(nil) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 30)
                    }.buttonStyle(.pressable).focused($topControlsFocused).help("进入或退出全屏（⌃⌘F）")
                    Spacer()
                    VolumeControl(onPopoverChanged: { topPopoverOpen = $0; revealChrome() })
                        .focused($topControlsFocused)
                }
                .padding(.horizontal, 20).frame(height: 48)
                .opacity(topChromeVisible ? 1 : 0)
                .allowsHitTesting(topChromeVisible)
                .accessibilityHidden(!topChromeVisible)
                .onHover { topChromeHovering = $0; revealChrome() }
            }
    }

    private func revealChrome() {
        topChromeVisible = true
        chromeTask?.cancel()
        guard hidesTopChrome else { return }
        chromeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !topChromeHovering, !searchFocused, !topControlsFocused, !topPopoverOpen, !menuTracking, !voiceOverEnabled,
                  panels.window?.attachedSheet == nil else { return }
            topChromeVisible = false
        }
    }

    private var detailStack: some View {
        NavigationStack(path: pathBinding) {
            Group {
                if let testing { testing.leaf(nil) }
                else { rootView }
            }
            .navigationDestination(for: Destination.self) { destination in
                if let testing { testing.leaf(destination) }
                else { DestinationContent(destination: destination) }
            }
        }
        // This stack owns pages, while the window shell owns navigation
        // controls. Suppress the stack's implicit native back toolbar too.
        .toolbar(.hidden, for: .windowToolbar)
        .onChange(of: selection) { _, _ in path = [] }
    }

    private func openDestination(_ destination: Destination) {
        if !SongDownloadUI.isAvailable, destination == .downloaded || destination == .downloadTasks { return }
        guard player.showNowPlaying else { path.appendIfNotCurrent(destination); return }
        withAnimation(reduceMotion ? nil : AppAnimation.smooth, completionCriteria: .removed) {
            player.showNowPlaying = false
        } completion: { path.appendIfNotCurrent(destination) }
    }

    @ViewBuilder
    private var rootView: some View {
        switch selection {
        case .downloaded:
            DownloadedMusicView()
        case .home:
            HomeView()
        case .explore:
            ExploreView()
        case .fm:
            FMView()
        case .search:
            SearchView(query: "")
        case .likedSongs:
            if let playlist = account.likedSongsPlaylist {
                PlaylistDetailView(playlistID: playlist.id, isLikedList: true)
                    .id(playlist.id)
            } else {
                loginPrompt
            }
        case .daily:
            DailySongsView()
        case .recents:
            RecentsView()
        case .collections:
            CollectionsView()
        case .cloud:
            CloudView()
        case .playlist(let id):
            PlaylistDetailView(playlistID: id)
                .id(id)
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("登录后查看你喜欢的音乐")
                .font(.headline)
            Button("登录") { showLogin = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var needsCurrentArtwork: Bool {
        settings.showMainWindowAmbientBackground || player.hasCurrentTrack
    }

    private var isDarkAppearance: Bool {
        (settings.appearance.colorScheme ?? colorScheme) == .dark
    }
}

// MARK: - Cursor override

/// Claims the arrow cursor over the whole now-playing page. AppKit cursor
/// rects ignore hit-testing, so without this the split-view divider's resize
/// cursor leaks through the full-window overlay wherever the divider sits (#6).
struct ArrowCursorOverride: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorOverrideView { CursorOverrideView() }

    func updateNSView(_ nsView: CursorOverrideView, context: Context) {}

    final class CursorOverrideView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

// MARK: - Main window configurator

/// Grabs the single main `NSWindow` once it exists and installs a close
/// interceptor: Cmd+W / the red button *hide* the window (`orderOut`) instead
/// of destroying the single-instance `Window` scene. Destroying the scene left
/// the app running with no way to reopen it (#60/#66/#70); hiding keeps the
/// SwiftUI scene fully alive so `AppDelegate.applicationShouldHandleReopen`
/// can front it again on a Dock click. Every other window-delegate callback is
/// forwarded untouched to SwiftUI's own delegate.
struct MainWindowConfigurator: NSViewRepresentable {
    let ambientConfiguration: MainWindowAmbientConfiguration
    let panels: WindowPanelCoordinator
    var registersApplicationWindow = true

    func makeCoordinator() -> Coordinator { Coordinator(panels: panels, registersApplicationWindow: registersApplicationWindow) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.configure(from: view, ambient: ambientConfiguration) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.configure(from: nsView, ambient: ambientConfiguration) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var forwardee: NSWindowDelegate?
        private let ambientAppearance = MainWindowAmbientAppearanceController()
        private let panels: WindowPanelCoordinator
        private let registersApplicationWindow: Bool
        init(panels: WindowPanelCoordinator, registersApplicationWindow: Bool) {
            self.panels = panels
            self.registersApplicationWindow = registersApplicationWindow
        }
        func configure(from view: NSView, ambient: MainWindowAmbientConfiguration) {
            guard let window = view.window else { return }
            if self.window !== window {
                detach()
                self.window = window
                window.isReleasedWhenClosed = false
                forwardee = window.delegate
                window.delegate = self
                // Automatic style changes from page navigation otherwise
                // switch between compact and expanded titlebar heights and
                // resize the same content-minimum window by 20 points.
                window.toolbarStyle = .unifiedCompact
                panels.attach(to: window)
                if registersApplicationWindow { AppDelegate.shared?.mainWindow = window }
            }
            // Native traffic lights and their accessibility remain intact.
            // Never alpha-hide the titlebar or replace system window buttons.
            ambientAppearance.configure(ambient, in: window)
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = forwardee }
            panels.detach()
            self.window = nil
        }
        func windowDidUpdate(_ notification: Notification) {
            forwardee?.windowDidUpdate?(notification)
            panels.refreshMinimum()
            if let window { ambientAppearance.updateLayout(in: window) }
        }
        func windowDidResize(_ notification: Notification) {
            forwardee?.windowDidResize?(notification)
            if let window { ambientAppearance.updateLayout(in: window) }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if registersApplicationWindow { sender.orderOut(nil); return false }
            return true
        }
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardee?.responds(to: aSelector) == true { return forwardee }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

// MARK: - Search field

struct SearchFieldView: View {
    var isActive = true
    var loadDefaultKeyword = true
    var onFocusChanged: (Bool) -> Void = { _ in }
    let onSubmit: (String) -> Void

    @State private var text = ""
    @State private var placeholder = "搜索音乐、歌手、专辑"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
                .frame(width: 168)
                .onSubmit {
                    let query = text.trimmingCharacters(in: .whitespaces)
                    let effective = query.isEmpty ? placeholderQuery : query
                    guard !effective.isEmpty else { return }
                    onSubmit(effective)
                    focused = false
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.18 : 0.08), lineWidth: 1))
        // Keep the capsule off the window's rounded top-right corner (#88).
        .padding(.trailing, 8)
        .animation(AppAnimation.quick, value: focused)
        .onChange(of: focused) { _, value in onFocusChanged(value) }
        .onChange(of: isActive) { _, active in
            if !active { focused = false }
        }
        .task {
            guard loadDefaultKeyword else { return }
            if let keyword = try? await NeteaseAPI.searchDefaultKeyword(), !keyword.isEmpty {
                placeholder = keyword
                placeholderQuery = keyword
            }
        }
    }

    @State private var placeholderQuery = ""
}

// MARK: - Toast

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .compatGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
