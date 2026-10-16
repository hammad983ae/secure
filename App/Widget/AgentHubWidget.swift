import AgentHubCore
import SwiftUI
import WidgetKit

// Desktop / Notification Center widget: today's tokens and cost, the last
// seven days, running agents, and budgets. Data comes from the summary file
// the app writes (see WidgetSnapshot).

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPlaceholder: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let snapshot = WidgetSnapshot.load()
        completion(UsageEntry(date: Date(), snapshot: snapshot ?? .placeholder, isPlaceholder: snapshot == nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let entry = UsageEntry(date: Date(), snapshot: snapshot ?? WidgetSnapshot(), isPlaceholder: false)
        // The app asks for a reload whenever its numbers change; this is a fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

@main
struct AgentHubWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AgentHubUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        LinearGradient(colors: [W.void, W.deep], startPoint: .top, endPoint: .bottom)
                        RadialGradient(colors: [W.violet.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                        RadialGradient(colors: [W.cyan.opacity(0.22), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 200)
                    }
                }
        }
        .configurationDisplayName("Agent Hub")
        .description("Today's tokens and cost, running agents, and budgets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Widget palette (matches the app's theme).
private enum W {
    static let void = Color(red: 0.027, green: 0.031, blue: 0.059)
    static let deep = Color(red: 0.051, green: 0.063, blue: 0.125)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let emerald = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let rose = Color(red: 0.96, green: 0.25, blue: 0.37)
    static let text = Color(red: 0.91, green: 0.93, blue: 0.97)
    static let secondary = Color(red: 0.56, green: 0.59, blue: 0.69)
    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)

    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return "\(count)"
        }
    }

    static func cost(_ dollars: Double) -> String {
        dollars < 0.01 && dollars > 0 ? "<$0.01" : String(format: "$%.2f", dollars)
    }

    static func color(_ status: SessionStatus) -> Color {
        switch status {
        case .running: return cyan
        case .needsInput: return amber
        case .done: return emerald
        case .failed: return rose
        }
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch family {
            case .systemSmall:
                stats(compact: true)
                Spacer(minLength: 0)
                bars.frame(height: 30)
            case .systemMedium:
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        stats(compact: true)
                        Spacer(minLength: 0)
                        bars.frame(height: 30)
                    }
                    .frame(maxWidth: .infinity)
                    runs(limit: 3)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            default:
                stats(compact: false)
                bars.frame(height: 60)
                runs(limit: 4)
                budgets
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(W.text)
        .redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: snapshot.runs.isEmpty ? "sparkle" : "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(W.accent)
            Text("AGENT HUB")
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.5)
            Spacer()
            if !snapshot.runs.isEmpty {
                Text("\(snapshot.runs.count) live")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(W.cyan)
            }
        }
    }

    private func stats(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TODAY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(W.secondary)
            Text(W.tokens(snapshot.todayTokens))
                .font(.system(size: compact ? 26 : 32, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(LinearGradient(colors: [W.text, W.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 6) {
                Text(W.cost(snapshot.todayCost)).foregroundStyle(W.amber)
                Text("· week \(W.tokens(snapshot.weekTokens))").foregroundStyle(W.secondary)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private var bars: some View {
        let values = snapshot.lastSevenDays
        let peak = max(values.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index == values.count - 1 ? AnyShapeStyle(W.accent) : AnyShapeStyle(W.violet.opacity(0.5)))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(value) / CGFloat(peak) * 60))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private func runs(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.runs.isEmpty {
                Text("No agents running")
                    .font(.system(size: 11))
                    .foregroundStyle(W.secondary)
            }
            ForEach(Array(snapshot.runs.prefix(limit).enumerated()), id: \.offset) { _, run in
                HStack(spacing: 6) {
                    Circle().fill(W.color(run.status)).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(run.agent).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        Text(run.title).font(.system(size: 10)).foregroundStyle(W.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var budgets: some View {
        if !snapshot.budgets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(snapshot.budgets.enumerated()), id: \.offset) { _, gauge in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(gauge.name).font(.system(size: 10.5, weight: .medium))
                            Spacer()
                            Text("\(Int(gauge.fraction * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(W.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(gauge.fraction >= 1 ? W.rose : gauge.fraction >= 0.8 ? W.amber : W.cyan)
                                    .frame(width: geo.size.width * min(max(gauge.fraction, 0), 1))
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}
