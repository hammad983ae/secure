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

/// Glass-style card: a translucent tinted fill with a hairline border.
///
/// Deliberately not a system material: materials re-blur everything behind
/// them on every frame, which gets expensive with dozens of cards on screen.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.radius
    var tint: Color? = nil
    var glow: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(
                shape.fill(LinearGradient(
                    colors: [(tint ?? .white).opacity(0.09), Color.white.opacity(0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [(tint ?? .white).opacity(glow ? 0.6 : 0.18), Theme.stroke], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            )
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

/// Static aurora behind the whole window: soft color glows and a dot grid,
/// drawn once (and again only on resize). No animation, no blur filters.
struct AuroraBackground: View {
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Theme.void, Theme.deep]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            let glows: [(Color, CGPoint, CGFloat, Double)] = [
                (Theme.violet, CGPoint(x: size.width * 0.25, y: size.height * 0.15), max(size.width, size.height) * 0.45, 0.20),
                (Theme.cyan, CGPoint(x: size.width * 0.85, y: size.height * 0.78), max(size.width, size.height) * 0.38, 0.16),
                (Theme.magenta, CGPoint(x: size.width * 0.62, y: size.height * 0.02), max(size.width, size.height) * 0.28, 0.12),
            ]
            for (color, center, radius, strength) in glows {
                context.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius
                ))
            }
            // Dot grid
            let spacing: CGFloat = 28
            var dots = Path()
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    dots.addRect(CGRect(x: x, y: y, width: 1.2, height: 1.2))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(.white.opacity(0.03)))
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
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
        .shadow(color: color.opacity(active ? 0.7 : 0), radius: active ? 6 : 0)
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
