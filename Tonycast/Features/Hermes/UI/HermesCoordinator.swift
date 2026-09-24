import AppKit
import SwiftUI

/// Owns the Hermes window and the session behind it, and exposes the one entry point the launcher
/// command calls. Mirrors the shape of the other feature coordinators so wiring stays uniform.
@MainActor
final class HermesCoordinator {
    private let settings: HermesSettings
    private let session: ACPSessionManager
    private lazy var window = HermesWindowController(session: session, settings: settings)

    init(settings: HermesSettings, session: ACPSessionManager) {
        self.settings = settings
        self.session = session
    }

    /// Opens the window, or brings it forward if it is already up.
    func show() {
        window.show()
    }

    func toggle() {
        window.toggle()
    }

    var isVisible: Bool { window.isVisible }
}
