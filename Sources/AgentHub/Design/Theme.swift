import AgentHubCore
import SwiftUI

/// Colors, type, and surfaces for Agent Hub's dark, neon-on-glass look.
enum Theme {
    // Backgrounds
    static let void = Color(red: 0.027, green: 0.031, blue: 0.059)        // #07080F
    static let deep = Color(red: 0.051, green: 0.063, blue: 0.125)        // #0D1020
    static let surface = Color.white.opacity(0.045)
    static let surfaceRaised = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.09)
    static let strokeStrong = Color.white.opacity(0.16)

    // Text
    static let textPrimary = Color(red: 0.91, green: 0.93, blue: 0.97)
    static let textSecondary = Color(red: 0.56, green: 0.59, blue: 0.69)
    static let textTertiary = Color(red: 0.38, green: 0.41, blue: 0.50)

    // Accents
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)           // #22D3EE
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)         // #8B5CF6
    static let magenta = Color(red: 0.93, green: 0.28, blue: 0.60)        // #EC4899
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let emerald = Color(red: 0.20, green: 0.83, blue: 0.60)
    static let rose = Color(red: 0.96, green: 0.25, blue: 0.37)

    static let accent = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
    static let accentWide = LinearGradient(colors: [cyan, violet, magenta], startPoint: .topLeading, endPoint: .bottomTrailing)

    // Type
    static func display(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static let title = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13.5)
    static let mono = Font.system(size: 12, design: .monospaced)
    /// Small uppercase HUD-style labels.
    static let label = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static let radius: CGFloat = 14
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .running: return Theme.cyan
        case .needsInput: return Theme.amber
        case .done: return Theme.emerald
        case .failed: return Theme.rose
        }
    }
}

/// A color identity per agent, so avatars and cards are recognizable at a glance.
enum AgentColors {
    static func color(for agent: AgentDefinition) -> Color { color(id: agent.id, handle: agent.handle) }

    static func color(id: UUID, handle: String = "") -> Color {
        switch id {
        case AgentPresets.claudeCode.id, AgentPresets.claudeAPI.id: return Color(red: 0.85, green: 0.47, blue: 0.34) // coral
        case AgentPresets.codex.id, AgentPresets.openAI.id: return Color(red: 0.06, green: 0.73, blue: 0.51)       // green
        case AgentPresets.gemini.id: return Color(red: 0.31, green: 0.55, blue: 1.0)                               // blue
        case AgentPresets.aider.id: return Color(red: 0.98, green: 0.80, blue: 0.08)                               // yellow
        case AgentPresets.shell.id: return Color(red: 0.62, green: 0.65, blue: 0.75)                               // steel
        default:
            // Stable hue from the id for user-defined agents.
            let hash = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            return Color(hue: Double(hash % 360) / 360, saturation: 0.65, brightness: 0.95)
        }
    }
}

// MARK: - Surfaces

/// Frosted glass card with a hairline border.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.radius
    var tint: Color? = nil
    var glow: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.55)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [(tint ?? .white).opacity(0.10), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [(tint ?? .white).opacity(glow ? 0.55 : 0.18), Theme.stroke], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: (tint ?? .clear).opacity(glow ? 0.35 : 0), radius: 18)
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.radius, tint: Color? = nil, glow: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, tint: tint, glow: glow))
    }

    /// Fills text or shapes with the accent gradient.
    func accentGradient() -> some View {
        overlay(Theme.accent).mask(self)
    }

    func hudLabel() -> some View {
        font(Theme.label).tracking(1.4).textCase(.uppercase).foregroundStyle(Theme.textTertiary)
    }
}

/// Slowly drifting aurora behind the whole window.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 14
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    LinearGradient(colors: [Theme.void, Theme.deep], startPoint: .top, endPoint: .bottom)
                    blob(Theme.violet, size: max(w, h) * 0.75)
                        .position(x: w * (0.25 + 0.08 * sin(t)), y: h * (0.15 + 0.06 * cos(t * 0.8)))
                    blob(Theme.cyan, size: max(w, h) * 0.6)
                        .position(x: w * (0.85 + 0.06 * cos(t * 1.1)), y: h * (0.75 + 0.07 * sin(t * 0.9)))
                    blob(Theme.magenta, size: max(w, h) * 0.45)
                        .position(x: w * (0.6 + 0.1 * sin(t * 0.6)), y: h * (0.05 + 0.05 * sin(t * 1.3)))
                        .opacity(0.6)
                    GridPattern().opacity(0.5)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.22), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: 40)
    }
}

/// Faint dot grid for a "HUD" texture.
struct GridPattern: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(path, with: .color(.white.opacity(0.05)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Components

/// Round agent avatar with the agent's color and symbol.
struct AgentAvatar: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var active = false

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(active ? 0.8 : 0.35), radius: active ? 10 : 4)
        .overlay {
            if active { PulseRing(color: color).frame(width: size + 8, height: size + 8) }
        }
    }
}

struct PulseRing: View {
    let color: Color
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(color.opacity(animate ? 0 : 0.7), lineWidth: 1.5)
            .scaleEffect(animate ? 1.25 : 0.9)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

/// Glowing status dot + label.
struct StatusBadge: View {
    let status: SessionStatus
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                .shadow(color: status.color, radius: status == .running ? 4 : 2)
            if !compact {
                Text(status.title).font(Theme.label).tracking(1).textCase(.uppercase)
            }
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, compact ? 0 : 7)
        .padding(.vertical, compact ? 0 : 3)
        .background {
            if !compact { Capsule().fill(status.color.opacity(0.12)) }
        }
    }
}

/// Primary call-to-action style: gradient fill with glow.
struct NeonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.accent))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .shadow(color: Theme.violet.opacity(configuration.isPressed ? 0.2 : 0.5), radius: 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet glass button for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(configuration.isPressed ? Theme.surfaceRaised : Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}

/// Icon-only glass button.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

enum Formatters {
    /// 1234 → "1.2K", 3_400_000 → "3.4M".
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
}
