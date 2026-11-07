import SwiftUI

extension View {
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5).allowsHitTesting(false) }
        }
    }

    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent) }
    }

    @ViewBuilder func darkGlassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            background(Color.black.opacity(0.55), in: shape)
                .glassEffect(interactive ? .regular.tint(.black.opacity(0.45)).interactive() : .regular.tint(.black.opacity(0.45)),
                             in: shape)
        } else {
            background(Color.black.opacity(0.55), in: shape).background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) }
        else { self }
    }

    @ViewBuilder func softTopScrollBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { content().background(.bar) }
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) }
        else { buttonStyle(.bordered) }
    }

    @ViewBuilder func extraLargeControl() -> some View {
        if #available(macOS 26, *) { controlSize(.extraLarge) }
        else { controlSize(.large) }
    }
}

struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer { content() } }
        else { content() }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder func independentToolbarBackground(_ independent: Bool = true) -> some ToolbarContent {
        if #available(macOS 26, *) { sharedBackgroundVisibility(independent ? .hidden : .visible) }
        else { self }
    }
}

struct FixedToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
    }
}
