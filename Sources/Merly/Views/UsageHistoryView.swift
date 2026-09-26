import Charts
import SwiftUI

struct UsageHistoryView: View {
    @ObservedObject var engine: UsageEngine
    let providerID: String
    let onBack: () -> Void
    var embedded = false

    @State private var range: UsageHistoryRange = .hours24
    @State private var selectedWindowID = "primary"
    @Environment(\.theme) private var theme

    private var providerConfig: ProviderConfig? {
        engine.appConfig.providers.first { $0.id == providerID }
    }

    private var currentSnapshot: ProviderSnapshot? {
        guard let identity else { return nil }
        return engine.snapshots.first {
            $0.id == providerID && HistoryIdentity(config: $0.config) == identity
        }
    }

    private var identity: HistoryIdentity? {
        providerConfig.map(HistoryIdentity.init(config:))
    }

    private var availableWindows: [UsageHistoryWindow] {
        guard let identity else { return [] }
        var windows: [String: UsageHistoryWindow] = [:]
        for sample in engine.historySamples where sample.identity == identity {
            for window in sample.windows { windows[window.id] = window }
        }
        return windows.values.sorted {
            if $0.id == $1.id { return false }
            if $0.id == "primary" { return true }
            if $1.id == "primary" { return false }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    private var selectedWindow: UsageHistoryWindow? {
        availableWindows.first { $0.id == selectedWindowID } ?? availableWindows.first
    }

    var body: some View {
        Group {
            if let providerConfig {
                historyContent(providerConfig)
            } else {
                missingProvider
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyContent(_ config: ProviderConfig) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            historyContent(config, now: context.date)
        }
    }

    private func historyContent(_ config: ProviderConfig, now: Date) -> some View {
        let selected = selectedWindow
        let series: UsageHistorySeries? = {
            guard let identity, let selected else { return nil }
            return UsageHistorySeries.query(
                samples: engine.historySamples,
                identity: identity,
                windowID: selected.id,
                range: range,
                now: now,
                refreshSeconds: TimeInterval(engine.appConfig.refreshSeconds)
            )
        }()
        let account = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountSubtitle = account.isEmpty ? config.name : "\(config.name) · \(account)"

        return VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                header(account: accountSubtitle)
            }

            Picker("Period", selection: $range) {
                ForEach(UsageHistoryRange.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("History period")

            if !availableWindows.isEmpty {
                Picker("Window", selection: Binding(
                    get: { selectedWindow?.id ?? "" },
                    set: { selectedWindowID = $0 }
                )) {
                    ForEach(availableWindows) { window in
                        Text(window.label).tag(window.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Quota window")
            }

            if liveReadingUnavailable {
                Text("Live readings are unavailable. Saved history is still shown.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let historyError = engine.historyError {
                Text(historyError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if availableWindows.isEmpty {
                Text("History starts with your next live reading.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
            } else if let series, series.readingCount > 0 {
                chart(series, range: range, now: now)
                statistics(series)
                if range != .hours24 {
                    Text("Longer views show sampled readings; peak uses all saved readings.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No readings in this period.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
            }

            Text("Quota percentages recorded while Merly is running. Keeps 30 days; offline estimates are excluded.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveReadingUnavailable: Bool {
        guard let currentSnapshot else { return true }
        return currentSnapshot.failure != nil || currentSnapshot.isEstimated || currentSnapshot.isStale
    }

    private var missingProvider: some View {
        VStack(alignment: .leading, spacing: 14) {
            backButton
            Text("This provider is no longer configured.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(account: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            backButton
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage history")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(account)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Label("Back", systemImage: "chevron.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.text2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to providers")
    }

    private func chart(
        _ series: UsageHistorySeries,
        range: UsageHistoryRange,
        now: Date
    ) -> some View {
        Chart {
            ForEach(series.segments) { segment in
                if segment.points.count == 1, let point = segment.points.first {
                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Quota used", point.pct)
                    )
                    .foregroundStyle(Theme.accent)
                    .symbolSize(30)
                } else {
                    ForEach(segment.points) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Quota used", point.pct),
                            series: .value("Reading segment", point.segmentID)
                        )
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-range.durationSeconds)...now)
        .chartYScale(domain: 0.0...100.0)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(theme.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date, range: range))
                            .font(.system(size: 8.5))
                            .foregroundStyle(theme.text3)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 50.0, 100.0]) { value in
                AxisGridLine().foregroundStyle(theme.hairline)
                AxisValueLabel {
                    if let pct = value.as(Double.self) {
                        Text("\(Int(pct))%")
                            .font(.system(size: 8.5))
                            .foregroundStyle(theme.text3)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.trailing, 4)
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Quota usage history chart")
    }

    private func statistics(_ series: UsageHistorySeries) -> some View {
        HStack(spacing: 8) {
            statistic("Last recorded", pct: series.latestObservedPct)
            statistic("Observed peak", pct: series.peakObservedPct)
        }
        .overlay(alignment: .bottomLeading) {
            if let lastObservedAt = series.lastObservedAt {
                HStack {
                    Text(lastObservedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer(minLength: 4)
                    Text("\(series.readingCount) saved readings")
                }
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(theme.text3)
                .offset(y: 16)
            }
        }
        .padding(.bottom, 16)
    }

    private func statistic(_ label: String, pct: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.text3)
            Text(pct.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "No data")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 9))
    }

    private func axisLabel(_ date: Date, range: UsageHistoryRange) -> String {
        switch range {
        case .hours24: date.formatted(date: .omitted, time: .shortened)
        case .days7: date.formatted(.dateTime.weekday(.abbreviated))
        case .days30: date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
