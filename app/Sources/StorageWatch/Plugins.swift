import SwiftUI

/// A pluggable feature module shown in the app's "工具" section.
/// Future modules (e.g. cache cleanup, duplicate finder, large-file sweeper)
/// conform to this protocol and register in `PluginRegistry.all`.
protocol FeaturePlugin: Identifiable {
    var id: String { get }
    var title: String { get }
    var subtitle: String { get }
    var systemImage: String { get }
    var isAvailable: Bool { get }
    @MainActor @ViewBuilder func makeView() -> AnyView
}

enum PluginRegistry {
    /// Registered feature modules. Add new entries here as modules ship.
    static let all: [AnyFeaturePlugin] = [
        AnyFeaturePlugin(ComingSoonPlugin(
            id: "cache-cleaner",
            title: "缓存清理",
            subtitle: "定位并安全清理应用缓存（开发中）",
            systemImage: "trash.slash"
        )),
        AnyFeaturePlugin(ComingSoonPlugin(
            id: "large-files",
            title: "大文件速览",
            subtitle: "按大小列出最近的大文件（开发中）",
            systemImage: "doc.zipper"
        )),
    ]
}

struct AnyFeaturePlugin: FeaturePlugin {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let isAvailable: Bool
    private let viewBuilder: @MainActor () -> AnyView

    init<P: FeaturePlugin>(_ base: P) {
        id = base.id
        title = base.title
        subtitle = base.subtitle
        systemImage = base.systemImage
        isAvailable = base.isAvailable
        viewBuilder = { base.makeView() }
    }

    @MainActor func makeView() -> AnyView { viewBuilder() }
}

private struct ComingSoonPlugin: FeaturePlugin {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    var isAvailable: Bool { false }
    @MainActor func makeView() -> AnyView { AnyView(EmptyView()) }
}
