// PointerCursor.swift — "this is clickable" feedback for the pointer.
//
// SwiftUI has no cursor API on macOS 14, so every interactive view in the panel
// leaves the pointer as a plain arrow — nothing distinguishes a provider card
// from the background it sits on. This bridges to AppKit's cursor stack.

import AppKit
import SwiftUI

/// Swaps the pointer while it's inside the view.
///
/// `NSCursor.push()`/`pop()` must stay balanced or the cursor sticks app-wide, so
/// the modifier tracks whether *it* pushed and pops on every way out: leaving the
/// view, the modifier going inactive, and disappearing — a card deleted or
/// reordered out from under the pointer would otherwise strand a hand cursor.
private struct PointerCursorModifier: ViewModifier {
    let cursor: NSCursor
    let active: Bool

    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && active { push() } else { pop() }
            }
            .onChange(of: active) { _, isActive in
                if !isActive { pop() }
            }
            .onChange(of: cursor) { _, _ in
                // Mid-hover swap (open hand → closed hand as a drag starts):
                // restack so the new cursor is the one on top.
                if pushed {
                    pop()
                    push()
                }
            }
            .onDisappear { pop() }
    }

    private func push() {
        guard !pushed else { return }
        pushed = true
        cursor.push()
    }

    private func pop() {
        guard pushed else { return }
        pushed = false
        NSCursor.pop()
    }
}

extension View {
    /// Shows `cursor` while the pointer is over this view. `active: false` leaves
    /// the arrow alone (a control that isn't clickable right now shouldn't claim
    /// to be).
    func pointerCursor(_ cursor: NSCursor = .pointingHand, active: Bool = true) -> some View {
        modifier(PointerCursorModifier(cursor: cursor, active: active))
    }
}
