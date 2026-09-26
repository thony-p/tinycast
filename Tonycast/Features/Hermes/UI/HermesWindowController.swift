import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Hosts the Hermes conversation. A floating panel rather than an ordinary window: a chat that
/// streams for minutes must not slide behind the next app clicked, and Escape is the only key that
/// files it away.
@MainActor
final class HermesWindowController: NSObject, NSWindowDelegate {
    private unowned let session: ACPSessionManager
    private let settings: HermesSettings
    private var window: HermesPanel?

    init(session: ACPSessionManager, settings: HermesSettings) {
        self.session = session
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = ensureWindow()
        window.makeKeyAndOrderFront(nil)
        // Connecting is slow (process start + handshake), so it happens after the window is up.
        Task { await session.connect() }
    }

    /// Escape and the close button are the only two things that file the window away.
    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - NSWindowDelegate

    /// Closing hides rather than destroys: the process and transcript stay warm.
    func windowWillClose(_ notification: Notification) {
        hide()
    }

    /// Coming forward re-reads the store: Hermes' own app can create a session in a project while
    /// this window sits hidden, and nothing on the wire announces it.
    func windowDidBecomeKey(_ notification: Notification) {
        Task { await session.refreshSidebar() }
    }

    // MARK: - Private

    private func ensureWindow() -> HermesPanel {
        if let window { return window }
        let hosting = NSHostingController(rootView: HermesView(session: session, settings: settings))
        let window = HermesPanel(contentViewController: hosting)
        window.onEscape = { [weak self] in self?.hide() }
        window.title = "Hermes"
        window.setContentSize(HermesWindowController.defaultSize)
        window.contentMinSize = HermesWindowController.minimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Centred by hand, never restored from an autosaved frame: that frame outlives a change to
        // the window's shape, so an older, smaller one would beat `defaultSize` on each launch.
        // `center()` is avoided because it deliberately seats a window above the middle.
        window.centerInVisibleScreen()
        self.window = window
        return window
    }

    /// Wider and taller than the conversation needs alone: the sidebar takes 220 of the width, and
    /// a
    /// transcript of prose and tables is the thing being read, so it gets the room.
    static let defaultSize = CGSize(width: 1180, height: 860)
    /// The conversation alone still fits at this width, which is what a collapsed-looking window
    /// would be — the sidebar is a fixed column and does not shrink.
    static let minimumSize = CGSize(width: 700, height: 380)
}

/// Floating, so another app's window never covers it. Escape is read here because whichever view
/// holds focus decides whether the key reaches a text field's own handler instead.
final class HermesPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: .zero,
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        // Focus leaving is never a reason to hide; only Escape and the close button are.
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        self.contentViewController = contentViewController
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, Int(event.keyCode) == kVK_Escape, !event.isARepeat else {
            super.sendEvent(event)
            return
        }
        // An input method mid-composition owns Escape: it cancels the marked text, not the window.
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() {
            super.sendEvent(event)
            return
        }
        onEscape?()
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// Seats the window on the middle of the visible screen, and keeps it there when it will not
    /// fit.
    ///
    /// The screen under the pointer wins, which is the display the user is looking at.
    /// `visibleFrame`
    /// excludes the menu bar and the Dock, so the window cannot land under either.
    func centerInVisibleScreen() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        // A window larger than the screen is anchored at the visible frame's top-left: centred, it
        // would hang off both sides and the close button would leave the screen entirely.
        let x = size.width >= visible.width ? visible.minX : visible.minX + (visible.width - size.width) / 2
        let y = size.height >= visible.height
            ? visible.maxY - size.height : visible.minY + (visible.height - size.height) / 2
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
