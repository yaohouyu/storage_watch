import SwiftUI
import AppKit

@main
struct StorageWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = Engine.shared
    @StateObject private var store = Store.shared
    @AppStorage("menuBarStyle") private var menuBarStyle = MenuBarStyle.iconAndFree.rawValue

    init() {
        Engine.shared.start()
        DispatchQueue.main.async { Store.shared.beginPolling() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(engine)
                .environmentObject(store)
        } label: {
            MenuBarLabel(style: MenuBarStyle(rawValue: menuBarStyle) ?? .iconAndFree)
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Double-clicking the app should always surface the dashboard; the
        // menu bar icon remains for quick checks after the window is closed.
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            WindowController.shared.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.stop()
    }

}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconOnly, iconAndFree, iconAndDelta
    var id: String { rawValue }
    var label: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .iconAndFree: return "图标 + 可用空间"
        case .iconAndDelta: return "图标 + 今日变化"
        }
    }
}

struct MenuBarLabel: View {
    let style: MenuBarStyle
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 4) {
            MenuBarGlyph()
            switch style {
            case .iconOnly:
                EmptyView()
            case .iconAndFree:
                Text(freeText).monospacedDigit()
            case .iconAndDelta:
                Text(deltaText).monospacedDigit()
            }
        }
    }

    private var freeText: String {
        guard let free = store.status?.disk.free else { return "" }
        return formatBytes(free, unit: false) + "G"
    }

    private var deltaText: String {
        guard let delta = store.usedDelta else { return "" }
        let gb = Double(delta) / 1e9
        return String(format: "%+.1fG", -gb) // negative free-delta means growth; show used change
    }
}

/// Template image so macOS recolors it for light/dark menu bars.
private struct MenuBarGlyph: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        view.image = image
        view.imageScaling = .scaleProportionallyDown
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
