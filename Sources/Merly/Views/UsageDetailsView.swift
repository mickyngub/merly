import SwiftUI

private enum UsageDetailsPage: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case history = "History"

    var id: String { rawValue }
}

struct UsageDetailsView: View {
    @ObservedObject var engine: UsageEngine
    let providerID: String
    let onBack: () -> Void

    @State private var page: UsageDetailsPage = .activity
    @State private var range: UsageAnalyticsRange = .latest
    @State private var selectedSessionID: String?
    @State private var selectedModelID: String?
    @State private var expandedModels = false
    @State private var expandedContributors = false
    @Environment(\.theme) private var theme

    private static let allModelsID = "__all_models__"

    private var providerConfig: ProviderConfig? {
        engine.appConfig.providers.first { $0.id == providerID }
    }

    private var identity: HistoryIdentity? {
        providerConfig.map(HistoryIdentity.init(config:))
    }

    var body: some View {
        Group {
            if let providerConfig, let identity {
                details(config: providerConfig, identity: identity)
                    .task(id: identity) {
                        engine.loadUsageDetails(for: providerConfig)
                    }
                    .onChange(of: engine.lastRefresh) { _, _ in
                        if page == .activity { engine.loadUsageDetails(for: providerConfig) }
                    }
                    .onChange(of: page) { _, newPage in
                        if newPage == .activity { engine.loadUsageDetails(for: providerConfig) }
                    }
            } else {
                missingProvider
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(config: ProviderConfig, identity: HistoryIdentity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(config: config)

            Picker("Usage details page", selection: $page) {
                ForEach(UsageDetailsPage.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Usage details page")

            switch page {
            case .activity:
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    activity(config: config, identity: identity, now: context.date)
                }
            case .history:
                UsageHistoryView(
                    engine: engine,
                    providerID: providerID,
                    onBack: onBack,
                    embedded: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missingProvider: some View {
        VStack(alignment: .leading, spacing: 14) {
            backButton
            Text("This provider is no longer configured.")
                .font(.system(size: 12))
                .foregroundStyle(theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(config: ProviderConfig) -> some View {
        let account = config.account.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            backButton
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage details")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.text)
                Text(account.isEmpty ? config.name : "\(config.name) · \(account)")
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

    private func activity(config: ProviderConfig, identity: HistoryIdentity, now: Date) -> some View {
        let snapshot = engine.snapshots.first {
            $0.id == providerID && HistoryIdentity(config: $0.config) == identity
        }
        let report = engine.usageReports[identity]
        let sessions = report.map { UsageAnalytics.sessions(in: $0, now: now) } ?? []
        let visibleSessions = Array(sessions.prefix(50))
        let effectiveSessionID = visibleSessions.first(where: { $0.id == selectedSessionID })?.id
            ?? visibleSessions.first?.id
        let summary = report.map {
            UsageAnalytics.summarize(
                $0,
                range: range,
                sessionID: range == .latest ? effectiveSessionID : nil,
                now: now
            )
        }
        let loading = engine.usageLoading.contains(identity)

        return VStack(alignment: .leading, spacing: 16) {
            quotaSection(snapshot: snapshot, config: config, now: now)

            sectionRule
            analyticsHeader(loading: loading, config: config)

            Picker("Activity period", selection: $range) {
                ForEach(UsageAnalyticsRange.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Activity period")

            if range == .latest, !visibleSessions.isEmpty {
                Picker("Session", selection: Binding(
                    get: { effectiveSessionID ?? "" },
                    set: { selectedSessionID = $0 }
                )) {
                    ForEach(visibleSessions) { session in
                        Text(session.displayName).tag(session.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Root session")
                if sessions.count > visibleSessions.count {
                    Text("Showing the 50 most recent sessions.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.text3)
                }
            }

            if let report, let summary {
                if !report.warnings.isEmpty {
                    warningList(report.warnings)
                }
                if summary.requestCount == 0 && summary.tokens.total == 0 {
                    Text("No recorded usage in this period.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text2)
                        .padding(.vertical, 8)
                } else {
                    summaryTiles(summary)
                    activityFacts(summary)
                    modelSection(summary.models, accent: config.resolvedPalette.accent)
                    tokenBreakdown(summary, accent: config.resolvedPalette.accent)
                    contributorSection(summary.contributors, accent: config.resolvedPalette.accent)
                    apiValueNote(summary, kind: config.kind)
                }
            } else if loading {
                ProgressView("Reading local usage…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 14)
            } else {
                Text("No recorded usage in this period.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text2)
                    .padding(.vertical, 8)
            }

            Text("Session stats cover local CLI logs on this Mac. Quota comes from the provider account. Active time appears when reported. Line changes and cloud credits are not available from the connected readers.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaSection(snapshot: ProviderSnapshot?, config: ProviderConfig, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Quota")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)

            if let snapshot, let failure = snapshot.failure {
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.headline)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(failure.isFault ? Theme.danger : theme.text)
                    if let note = snapshot.note {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.text2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if let snapshot {
                if snapshot.isEstimated {
                    quotaSourceNote("Estimated quota")
                } else if snapshot.isStale {
                    quotaSourceNote("Last known quota")
                }
                quotaBars(snapshot, now: now)
                if let credits = snapshot.resetCredits, credits.available > 0 {
                    ResetCreditTag(credits: credits, provider: config.name)
                }
            } else {
                Text("Quota snapshot unavailable.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaSourceNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.text2)
    }

    private func quotaBars(_ snapshot: ProviderSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageBar(
                label: snapshot.hasSessionWindow ? "Current session" : "\(snapshot.primaryWindowName) usage",
                pct: snapshot.sessionPct,
                caption: snapshot.sessionResetAt.map {
                    "\(snapshot.primaryWindowName) limit · resets in \(UsageFormatting.duration(until: $0, now: now))"
                } ?? "\(snapshot.primaryWindowName) limit · no reset time reported",
                color: quotaColor(snapshot, label: snapshot.primaryWindowName, pct: snapshot.sessionPct)
            )
            ForEach(snapshot.weekly) { metric in
                UsageBar(
                    label: metric.label,
                    pct: metric.pct,
                    caption: metric.resetAt.map {
                        "Resets in \(UsageFormatting.duration(until: $0, now: now))"
                    } ?? metric.resetText,
                    color: quotaColor(snapshot, label: metric.label, pct: metric.pct)
                )
            }
        }
    }

    private func quotaColor(_ snapshot: ProviderSnapshot, label: String, pct: Double) -> Color {
        let lane = Color(hex: snapshot.config.kind.limitColorHex(rank: snapshot.laneRank(of: label)))
        return Theme.limitColor(pct: pct, lane: lane)
    }

    private func analyticsHeader(loading: Bool, config: ProviderConfig) -> some View {
        HStack(spacing: 7) {
            Text("Session activity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer(minLength: 4)
            if loading { ProgressView().controlSize(.small) }
            Button {
                engine.loadUsageDetails(for: config, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text2)
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel("Refresh local usage details")
            .help("Rescan local usage logs")
        }
    }

    private var sectionRule: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 0.5)
    }

    private func summaryTiles(_ summary: UsageAnalyticsSummary) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                statisticTile("Tokens", value: compactCount(summary.tokens.total))
                statisticTile("Usage records", value: compactCount(summary.requestCount))
            }
            HStack(spacing: 7) {
                statisticTile(
                    "Cache hit",
                    value: summary.tokens.cacheHitPct.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "Not reported"
                )
                apiValueTile(summary)
            }
        }
    }

    private func statisticTile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.text3)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 9))
    }

    private func apiValueTile(_ summary: UsageAnalyticsSummary) -> some View {
        let value: String
        let note: String?
        if let amount = summary.estimatedValueUSD {
            value = "≈\(amount.formatted(.currency(code: "USD").precision(.fractionLength(2))))"
            note = summary.unpricedRequestCount > 0 ? "Partial" : nil
        } else if summary.unpricedRequestCount > 0 {
            value = "Unpriced"
            note = nil
        } else {
            value = "Not reported"
            note = nil
        }

        return VStack(alignment: .leading, spacing: 3) {
            Text("API value")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.text3)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let note {
                Text(note)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.text2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func activityFacts(_ summary: UsageAnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Sessions", value: compactCount(summary.sessionCount))
            if let lastActivity = summary.lastActivity {
                detailRow("Last activity", value: lastActivity.formatted(date: .abbreviated, time: .shortened))
            }
            if let seconds = summary.recordedActiveSeconds {
                detailRow("Recorded active", value: duration(seconds))
            }
            if let added = summary.linesAdded, let removed = summary.linesRemoved {
                detailRow("Recorded line changes", value: "+\(compactCount(added)) / -\(compactCount(removed))")
            }
        }
        .padding(.vertical, 2)
    }

    private func detailRow(_ label: String, value: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.text2)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(theme.text3)
            }
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.text)
                .lineLimit(1)
        }
    }

    private func modelSection(_ models: [UsageBreakdown], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Models")
            ForEach(expandedModels ? models : Array(models.prefix(5))) { model in
                breakdownRow(model, accent: accent)
            }
            if models.count > 5 {
                disclosureButton(expandedModels ? "Show fewer models" : "Show all \(models.count) models") {
                    expandedModels.toggle()
                }
            }
            Text("Share of recorded tokens.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text3)
        }
    }

    private func breakdownRow(_ item: UsageBreakdown, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 3)
                Text("\(share(item.sharePct)) · \(compactCount(item.tokens.total))")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.text2)
                    .lineLimit(1)
            }
            ProgressView(value: item.sharePct, total: 100)
                .tint(accent)
                .accessibilityLabel("\(item.label), \(share(item.sharePct)) of recorded tokens")
        }
    }

    private func tokenBreakdown(_ summary: UsageAnalyticsSummary, accent: Color) -> some View {
        let model = summary.models.first { $0.id == selectedModelID }
        let tokens = model?.tokens ?? summary.tokens
        let selection = Binding<String>(
            get: { model?.id ?? Self.allModelsID },
            set: { selectedModelID = $0 == Self.allModelsID ? nil : $0 }
        )

        return VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Token breakdown")
            Picker("Model breakdown", selection: selection) {
                Text("All models").tag(Self.allModelsID)
                ForEach(summary.models) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Choose model for token breakdown")

            VStack(alignment: .leading, spacing: 6) {
                detailRow("Input (uncached)", value: compactCount(tokens.input))
                detailRow("Output", value: compactCount(tokens.output))
                detailRow("Cache read", value: compactCount(tokens.cacheRead))
                detailRow("Cache write", value: compactCount(tokens.cacheWrite))
                if tokens.cacheWrite1h > 0 {
                    detailRow("1h cache writes", value: compactCount(tokens.cacheWrite1h), note: "Included above")
                }
                if tokens.reasoningOutput > 0 {
                    detailRow("Reasoning output", value: compactCount(tokens.reasoningOutput), note: "Included above")
                }
            }
            .padding(10)
            .background(theme.chip.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        }
        .tint(accent)
    }

    private func contributorSection(_ contributors: [UsageBreakdown], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Sessions & subagents")
            ForEach(expandedContributors ? contributors : Array(contributors.prefix(5))) { item in
                breakdownRow(item, accent: accent)
            }
            if contributors.count > 5 {
                disclosureButton(expandedContributors ? "Show fewer sessions" : "Show all \(contributors.count) sessions") {
                    expandedContributors.toggle()
                }
            }
            Text("Shares are portions of recorded tokens, not quota usage.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text3)
        }
    }

    private func apiValueNote(_ summary: UsageAnalyticsSummary, kind: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("API value uses standard base rates, not subscription charges.")
                .font(.system(size: 9.5))
                .foregroundStyle(theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if summary.unpricedRequestCount > 0 {
                Text("\(summary.unpricedRequestCount) usage records have no verified price.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Pricing", destination: UsagePricing.sourceURL(for: kind))
                .font(.system(size: 10.5, weight: .medium))
                .help("Standard base rates verified \(UsagePricing.verifiedDate)")
        }
    }

    private func warningList(_ warnings: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.chip, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(theme.text)
    }

    private func disclosureButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(theme.text2)
            .accessibilityHint("Expand or collapse usage details")
    }

    private func compactCount(_ value: Int) -> String {
        if value < 1_000 { return value.formatted() }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(1)))
    }

    private func share(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0,
              let value = Int(exactly: seconds.rounded(.down))
        else { return "Not reported" }
        let hours = value / 3600
        let minutes = value % 3600 / 60
        let remainder = value % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainder)s" }
        return "\(remainder)s"
    }
}
