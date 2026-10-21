import AppKit
import SwiftUI

/// AppKit creates and lays out the standard sidebar item. Only its action is
/// adapted to the existing, navigation-independent HSplitView state.
@MainActor
final class MainWindowNativeToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    static let identifier: NSToolbar.Identifier = "QieTing.MainWindow.NativeToolbar"
    static let backIdentifier = NSToolbarItem.Identifier(rawValue: "QieTing.MainWindow.Back")
    static let searchIdentifier = NSToolbarItem.Identifier(rawValue: "QieTing.MainWindow.Search")
    static let trailingInsetIdentifier = NSToolbarItem.Identifier(rawValue: "QieTing.MainWindow.PanelInset")
    private static let owners = NSMapTable<NSWindow, MainWindowNativeToolbar>.weakToWeakObjects()
    private final class SavedToolbar: NSObject {
        let toolbar: NSToolbar?
        init(_ toolbar: NSToolbar?) { self.toolbar = toolbar }
    }
    private static let originals = NSMapTable<NSToolbar, SavedToolbar>.weakToStrongObjects()

    private weak var window: NSWindow?
    private var previousToolbar: NSToolbar?
    private(set) var toolbar: NSToolbar?
    private var onToggleSidebar: (@MainActor () -> Void)?
    private var onBack: (@MainActor () -> Void)?
    private var sidebarCollapsed = false
    private var available = false
    private var controlsVisible = true
    private var backAvailable = false
    private var searchHost: NSHostingView<SearchFieldView>?
    private var searchItem: NSToolbarItem?
    private var backItem: NSToolbarItem?
    private var trailingInsetItem: NSToolbarItem?
    private var trailingInsetWidth: NSLayoutConstraint?
    private var onTitlebarHover: (@MainActor (Bool) -> Void)?
    private var titlebarHovered = false
    private var mouseMonitor: Any?
    private var applicationInactiveObserver: NSObjectProtocol?
    private weak var trackedView: NSView?
    private var trackingArea: NSTrackingArea?
    private var previousAcceptsMouseMovedEvents: Bool?
    private var windowUpdateObserver: NSObjectProtocol?
    private var reconcileQueued = false
    private var generation: UInt64 = 0

    func configure(window: NSWindow, onToggleSidebar: @escaping @MainActor () -> Void,
                   sidebarCollapsed: Bool, available: Bool, controlsVisible: Bool, backAvailable: Bool,
                   onBack: @escaping @MainActor () -> Void, searchView: SearchFieldView,
                   trailingInset: CGFloat, onTitlebarHover: @escaping @MainActor (Bool) -> Void) {
        if self.window !== window {
            detach()
            // A replacement SwiftUI shell can attach before the old shell's
            // teardown finishes. Preserve the original toolbar, not another
            // short-lived instance of this adapter.
            if let current = window.toolbar, let saved = Self.originals.object(forKey: current) {
                previousToolbar = saved.toolbar
            } else {
                previousToolbar = window.toolbar
            }
            self.window = window
            previousAcceptsMouseMovedEvents = Self.owners.object(forKey: window)?.previousAcceptsMouseMovedEvents
                ?? window.acceptsMouseMovedEvents
            if !window.acceptsMouseMovedEvents { window.acceptsMouseMovedEvents = true }
            let nativeToolbar = NSToolbar(identifier: Self.identifier)
            nativeToolbar.delegate = self
            nativeToolbar.displayMode = .iconOnly
            nativeToolbar.allowsUserCustomization = false
            nativeToolbar.autosavesConfiguration = false
            Self.originals.setObject(SavedToolbar(previousToolbar), forKey: nativeToolbar)
            toolbar = nativeToolbar
            Self.owners.setObject(self, forKey: window)
            observeUpdates(in: window)
            observePointer(in: window)
        }
        self.onToggleSidebar = onToggleSidebar
        self.sidebarCollapsed = sidebarCollapsed
        self.available = available
        self.controlsVisible = controlsVisible
        self.backAvailable = backAvailable
        self.onBack = onBack
        self.onTitlebarHover = onTitlebarHover
        configureTrackingArea(in: window)
        configureCustomItems(searchView: searchView, trailingInset: trailingInset)
        reconcile()
    }

    func detach() {
        generation &+= 1
        reconcileQueued = false
        if let windowUpdateObserver {
            NotificationCenter.default.removeObserver(windowUpdateObserver)
            self.windowUpdateObserver = nil
        }
        let oldWindow = window
        let oldToolbar = toolbar
        let restoreToolbar = previousToolbar
        if let oldWindow, Self.owners.object(forKey: oldWindow) === self {
            if let previousAcceptsMouseMovedEvents,
               oldWindow.acceptsMouseMovedEvents != previousAcceptsMouseMovedEvents {
                oldWindow.acceptsMouseMovedEvents = previousAcceptsMouseMovedEvents
            }
            Self.owners.removeObject(forKey: oldWindow)
        }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let applicationInactiveObserver {
            NotificationCenter.default.removeObserver(applicationInactiveObserver)
            self.applicationInactiveObserver = nil
        }
        if let trackingArea { trackedView?.removeTrackingArea(trackingArea); self.trackingArea = nil }
        trackedView = nil
        previousAcceptsMouseMovedEvents = nil
        window = nil
        toolbar = nil
        previousToolbar = nil
        onToggleSidebar = nil
        onBack = nil
        available = false
        controlsVisible = false
        backAvailable = false
        searchHost = nil
        searchItem = nil
        backItem = nil
        trailingInsetItem = nil
        trailingInsetWidth = nil
        onTitlebarHover = nil
        titlebarHovered = false
        // Do not change native layout while SwiftUI is dismantling its graph.
        // New attachments get a new instance, so this cannot replace their
        // toolbar or a toolbar supplied by another window owner.
        if let oldToolbar {
            DispatchQueue.main.async { [weak oldWindow] in
                if let oldWindow, oldWindow.toolbar === oldToolbar {
                    oldWindow.toolbar = restoreToolbar
                }
                Self.originals.removeObject(forKey: oldToolbar)
            }
        }
    }

    @discardableResult
    static func performSidebarToggle(in window: NSWindow?) -> Bool {
        guard let window, let owner = owners.object(forKey: window) else { return false }
        return owner.invokeToggle()
    }

    @discardableResult
    static func performBack(in window: NSWindow?) -> Bool {
        guard let window, let owner = owners.object(forKey: window) else { return false }
        return owner.invokeBack()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.toggleSidebar]
        if available && controlsVisible && backAvailable { identifiers.append(Self.backIdentifier) }
        identifiers.append(.flexibleSpace)
        identifiers += [Self.searchIdentifier, Self.trailingInsetIdentifier]
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.backIdentifier, .flexibleSpace, Self.searchIdentifier, Self.trailingInsetIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.backIdentifier: return backItem
        case Self.searchIdentifier: return searchItem
        case Self.trailingInsetIdentifier: return trailingInsetItem
        default:
            // AppKit creates the standard sidebar and spacing items itself.
            // In particular, never substitute an image or custom sidebar view.
            return nil
        }
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem else { return }
        if item.itemIdentifier == .toggleSidebar { configureStandardItem(item) }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .toggleSidebar: return window != nil && available && onToggleSidebar != nil
        case Self.backIdentifier:
            return window != nil && available && controlsVisible && backAvailable && onBack != nil
        default: return true
        }
    }

    @objc private func toggleSidebar(_ sender: Any?) { _ = invokeToggle() }
    @objc private func goBack(_ sender: Any?) { _ = invokeBack() }

    private func invokeToggle() -> Bool {
        guard let window, Self.owners.object(forKey: window) === self,
              available, let onToggleSidebar else { return false }
        onToggleSidebar()
        return true
    }

    private func invokeBack() -> Bool {
        guard let window, Self.owners.object(forKey: window) === self,
              available, controlsVisible, backAvailable, let onBack else { return false }
        onBack()
        return true
    }

    private func configureCustomItems(searchView: SearchFieldView, trailingInset: CGFloat) {
        if let searchHost {
            // Keep the same host and TextField graph while navigation changes.
            searchHost.rootView = searchView
        } else {
            let host = NSHostingView(rootView: searchView)
            // This toolbar host must not establish another set of window
            // minimum/maximum constraints or own the window's toolbar scene.
            host.sizingOptions = [.intrinsicContentSize]
            host.sceneBridgingOptions = []
            host.setContentHuggingPriority(.required, for: .horizontal)
            host.setContentCompressionResistancePriority(.required, for: .horizontal)
            host.setContentCompressionResistancePriority(.required, for: .vertical)
            host.setFrameSize(host.fittingSize)
            searchHost = host
            let item = NSToolbarItem(itemIdentifier: Self.searchIdentifier)
            item.label = String(localized: "全局搜索")
            item.paletteLabel = item.label
            item.view = host
            item.isBordered = false
            item.visibilityPriority = .high
            searchItem = item
        }
        if backItem == nil {
            let item = NSToolbarItem(itemIdentifier: Self.backIdentifier)
            item.label = String(localized: "返回")
            item.paletteLabel = item.label
            item.toolTip = String(localized: "返回（⌘[）")
            item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: item.label)
            item.isNavigational = true
            item.target = self
            item.action = #selector(goBack(_:))
            item.visibilityPriority = .high
            backItem = item
        }
        if trailingInsetItem == nil {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            let width = spacer.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([width, spacer.heightAnchor.constraint(equalToConstant: 1)])
            trailingInsetWidth = width
            let item = NSToolbarItem(itemIdentifier: Self.trailingInsetIdentifier)
            item.label = ""
            item.view = spacer
            item.isBordered = false
            item.visibilityPriority = .high
            trailingInsetItem = item
        }
        let width = trailingInset.isFinite ? max(0, trailingInset) : 0
        if trailingInsetWidth?.constant != width { trailingInsetWidth?.constant = width }
        let searchHidden = !available || !controlsVisible
        if searchHost?.isHidden != searchHidden { searchHost?.isHidden = searchHidden }
        if let backItem {
            let enabled = available && backAvailable && onBack != nil
            if backItem.isEnabled != enabled { backItem.isEnabled = enabled }
        }
    }

    private func configureStandardItem(_ item: NSToolbarItem) {
        if item.target !== self { item.target = self }
        let action = #selector(toggleSidebar(_:))
        if item.action != action { item.action = action }
        let enabled = window != nil && available && onToggleSidebar != nil
        if item.isEnabled != enabled { item.isEnabled = enabled }
        let tooltip = sidebarCollapsed
            ? String(localized: "显示侧边栏（⌥⌘S）")
            : String(localized: "隐藏侧边栏（⌥⌘S）")
        if item.toolTip != tooltip { item.toolTip = tooltip }
    }

    private func reconcile() {
        guard let window, let toolbar, Self.owners.object(forKey: window) === self else { return }
        if window.toolbar !== toolbar { window.toolbar = toolbar }
        if !toolbar.isVisible { toolbar.isVisible = true }
        synchronizeItem(Self.backIdentifier, present: available && controlsVisible && backAvailable, at: 1)
        // Keep the same intrinsic toolbar height and native input host when
        // the collapsed-sidebar chrome temporarily hides or immersive starts.
        synchronizeItem(Self.searchIdentifier, present: true, at: toolbar.items.count)
        synchronizeItem(Self.trailingInsetIdentifier, present: true, at: toolbar.items.count)
        for item in toolbar.items where item.itemIdentifier == .toggleSidebar {
            configureStandardItem(item)
        }
    }

    private func synchronizeItem(_ identifier: NSToolbarItem.Identifier, present: Bool, at index: Int) {
        guard let toolbar else { return }
        let existing = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier })
        if present, existing == nil {
            toolbar.insertItem(withItemIdentifier: identifier, at: min(index, toolbar.items.count))
        } else if !present, let existing {
            toolbar.removeItem(at: existing)
        }
    }

    private func observeUpdates(in window: NSWindow) {
        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconciliation() }
        }
    }

    private func observePointer(in window: NSWindow) {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.updateTitlebarHover(from: event) }
            return event
        }
        applicationInactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setTitlebarHovered(false) }
        }
    }

    private func configureTrackingArea(in window: NSWindow) {
        guard let view = window.contentView, trackedView !== view else { return }
        if let trackingArea { trackedView?.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.inVisibleRect, .mouseEnteredAndExited, .activeInActiveApp],
                                  owner: self, userInfo: nil)
        view.addTrackingArea(area)
        trackedView = view
        trackingArea = area
    }

    @objc private func mouseEntered(_ event: NSEvent) { updateTitlebarHover(from: event) }
    @objc private func mouseExited(_ event: NSEvent) { setTitlebarHovered(false) }

    private func updateTitlebarHover(from event: NSEvent) {
        guard let window, event.window === window else { setTitlebarHovered(false); return }
        let point = event.locationInWindow
        let top = window.contentLayoutRect.maxY
        let contentWidth = window.contentView?.frame.width ?? window.frame.width
        setTitlebarHovered(point.x >= 0 && point.x <= contentWidth && point.y >= top)
    }

    private func setTitlebarHovered(_ hovered: Bool) {
        guard titlebarHovered != hovered else { return }
        titlebarHovered = hovered
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket, self.titlebarHovered == hovered else { return }
            self.onTitlebarHover?(hovered)
        }
    }

    private func scheduleReconciliation() {
        guard !reconcileQueued, window != nil else { return }
        reconcileQueued = true
        let ticket = generation
        // SwiftUI can commit its own toolbar after a navigation transaction.
        // Reconcile once outside that native layout/notification stack, and
        // write only if ownership or state actually changed.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.reconcileQueued = false
            self.reconcile()
        }
    }

    deinit {
        if let windowUpdateObserver { NotificationCenter.default.removeObserver(windowUpdateObserver) }
        if let applicationInactiveObserver { NotificationCenter.default.removeObserver(applicationInactiveObserver) }
        let oldMonitor = mouseMonitor
        let oldTrackingArea = trackingArea
        let oldTrackedView = trackedView
        DispatchQueue.main.async { [weak oldTrackedView] in
            if let oldMonitor { NSEvent.removeMonitor(oldMonitor) }
            if let oldTrackingArea { oldTrackedView?.removeTrackingArea(oldTrackingArea) }
        }
    }
}
