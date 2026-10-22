import AppKit
import SwiftUI

/// Owns the single dashboard window. A MenuBarExtra-only app has no natural
/// main window, so we create one on demand with AppKit.
@MainActor
final class WindowController {
    static let shared = WindowController()
    private var window: NSWindow?
    private var closedObserver: NSObjectProtocol?

    func show() {
        if let window, window.isVisible || window.isMiniaturized {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        window = nil
        let root = MainWindowView()
            .environmentObject(Engine.shared)
            .environmentObject(Store.shared)
            .frame(minWidth: 820, minHeight: 580)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Storage Watch"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: root)
        self.window = window
        closedObserver.map(NotificationCenter.default.removeObserver)
        closedObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.window = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
