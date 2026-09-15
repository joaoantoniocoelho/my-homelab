import SwiftUI

enum Theme {
    static let background = Color(red: 0.047, green: 0.059, blue: 0.075)
    static let sidebar = Color(red: 0.062, green: 0.078, blue: 0.094)
    static let card = Color(red: 0.073, green: 0.09, blue: 0.11)
    static let accent = Color(red: 0.40, green: 0.89, blue: 0.71)
    static let secondary = Color(red: 0.63, green: 0.69, blue: 0.74)
    static let muted = Color(red: 0.45, green: 0.52, blue: 0.58)
    static let line = Color.white.opacity(0.075)
    static let purple = Color(red: 0.67, green: 0.60, blue: 0.94)
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Theme.muted) }
}

func metric(_ value: Double?, suffix: String = "", decimals: Int = 0) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(decimals))) + suffix
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var color: Color = Theme.accent
    var fraction: Double? = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary); Spacer(); Image(systemName: icon).foregroundStyle(color) }
                Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
                if let fraction {
                    GeometryReader { geo in
                        Capsule().fill(color.opacity(0.1))
                        Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
                    }.frame(height: 4)
                } else { Color.clear.frame(height: 4) }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }
}
