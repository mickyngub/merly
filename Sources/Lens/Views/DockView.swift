// DockView.swift — the docked panel content: header, provider card list with
// staggered entrance, and the add-provider affordance. Also the collapsed rail.

import SwiftUI

struct DockView: View {
    @ObservedObject var engine: UsageEngine
    /// Bumped every time the panel opens, retriggering the entrance stagger.
    let openGeneration: Int

    @State private var refreshSpin = 0.0
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    ForEach(Array(engine.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        ProviderCardView(snapshot: snapshot)
                            .entrance(index: index, generation: openGeneration)
                    }
                    AddProviderCard()
                        .entrance(index: engine.snapshots.count, generation: openGeneration)
                }
                .padding(EdgeInsets(top: 2, leading: 12, bottom: 12, trailing: 12))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text("\(engine.snapshots.count) providers · \(engine.updatedText)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.text2)
                }
            }
            Spacer()
            IconButton(systemName: "arrow.clockwise") {
                withAnimation(.easeInOut(duration: 0.6)) { refreshSpin += 360 }
                engine.refresh()
            }
            .rotationEffect(.degrees(refreshSpin))
        }
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 11, trailing: 12))
    }
}

struct IconButton: View {
    let systemName: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? theme.text : theme.text2)
                .frame(width: 28, height: 28)
                .background(hovering ? theme.chip : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct AddProviderCard: View {
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            NSWorkspace.shared.open(AppPaths.configFile)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text2.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(theme.chip, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add a provider")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(hovering ? theme.text : theme.text2)
                    Text("Point it at a config folder")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 13, leading: 12, bottom: 13, trailing: 12))
            .background(hovering ? theme.chip : .clear, in: RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        hovering ? theme.text3 : theme.cardBorder,
                        style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Opens providers.json — add an entry and it appears on the next refresh")
    }
}

struct RailView: View {
    @ObservedObject var engine: UsageEngine
    let onExpand: () -> Void

    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text2)
                .padding(.bottom, 2)
            ForEach(engine.snapshots) { snapshot in
                MascotView(
                    style: snapshot.config.resolvedStyle,
                    palette: snapshot.config.resolvedPalette,
                    mood: snapshot.mood,
                    px: 32,
                    bob: false,
                    hopsOnHover: false,
                    spriteName: snapshot.config.resolvedSprite
                )
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.2), value: hovering)
            }
            Spacer()
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
        .onHover { hovering = $0 }
        .help("Open usage")
    }
}

/// Staggered slide-up entrance (translate-only — resting state is always visible,
/// a lesson learned in the prototype).
private struct EntranceEffect: ViewModifier {
    let index: Int
    let generation: Int

    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: settled || reduceMotion ? 0 : 10)
            .onAppear { animateIn() }
            .onChange(of: generation) { _, _ in
                settled = false
                animateIn()
            }
    }

    private func animateIn() {
        withAnimation(Theme.snappy(0.5).delay(Double(index) * 0.06)) {
            settled = true
        }
    }
}

extension View {
    func entrance(index: Int, generation: Int) -> some View {
        modifier(EntranceEffect(index: index, generation: generation))
    }
}
