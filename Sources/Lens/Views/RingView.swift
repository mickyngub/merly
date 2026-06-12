// RingView.swift — the 50px session-usage ring: track + animated progress arc,
// percent in the middle, "used" caption tucked under.

import SwiftUI

struct RingView: View {
    let pct: Double
    let accent: Color
    /// Locally-estimated figures get an "≈" so they don't read as official.
    var estimated: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        let stroke = Theme.usageColor(pct: pct, accent: accent)
        ZStack {
            Circle()
                .stroke(theme.track, lineWidth: 4.5)
            Circle()
                .trim(from: 0, to: pct / 100)
                .stroke(stroke, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.snappy(0.55), value: pct)
                .opacity(pct > 0 ? 1 : 0)

            (Text("\(Int(pct.rounded()))")
                .font(.system(size: 13, weight: .bold))
                + Text("%")
                .font(.system(size: 8, weight: .semibold)))
                .foregroundStyle(stroke)
                .monospacedDigit()
        }
        .frame(width: 38, height: 38)
        .padding(6)
        .overlay(alignment: .bottom) {
            Text(estimated ? "≈ used" : "used")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text2)
                .offset(y: 7)
        }
    }
}
