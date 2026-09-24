import AppKit
import SwiftUI

/// Hosts the Hermes conversation. A titled, resizable window rather than the launcher's floating
/// panel: a chat that streams for minutes should not vanish when focus moves.
@MainActor
final class HermesWindowController: NSObject, NSWindowDelegate {
    private unowned let session: ACPSessionManager
    private let settings: HermesSettings
    private var window: NSWindow?

    init(session: ACPSessionManager, settings: HermesSettings) {
        self.session = session
        self.settings = settings
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = ensureWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Connecting is slow (process start + handshake), so it happens after the window is up.
        Task { await session.connect() }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing hides rather than destroys: the process and transcript stay warm.
        window?.orderOut(nil)
    }

    // MARK: - Private

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let root = HermesView(session: session, settings: settings)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Hermes"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(HermesWindowController.defaultSize)
        window.contentMinSize = HermesWindowController.minimumSize
        window.setFrameAutosaveName("Hermes Window")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    static let defaultSize = CGSize(width: 760, height: 620)
    static let minimumSize = CGSize(width: 460, height: 360)
}
