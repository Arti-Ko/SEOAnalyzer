import SwiftUI

extension View {
    /// «Жидкое стекло» macOS 26+ с откатом на материал для прежних систем.
    @ViewBuilder
    func softSurface(_ shape: some Shape, material: Material = .regularMaterial) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(material, in: shape)
        }
    }

    /// Материал для крупных панелей (фон сайдбара).
    func panelSurface() -> some View {
        self.background(.regularMaterial)
    }
}

extension Grade {
    var color: Color {
        switch self {
        case .aPlus, .a: return .green
        case .b:         return Color(red: 0.4, green: 0.7, blue: 0.2)
        case .c:         return .yellow
        case .d:         return .orange
        case .e:         return Color(red: 0.95, green: 0.45, blue: 0.1)
        case .f:         return .red
        }
    }
}

extension CheckStatus {
    var color: Color {
        switch self {
        case .passed:  return .green
        case .warning: return .orange
        case .failed:  return .red
        case .info:    return .gray
        }
    }

    var iconName: String {
        switch self {
        case .passed:  return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed:  return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }
}

/// Большой круговой индикатор итоговой оценки.
struct GradeGauge: View {
    let grade: Grade
    let score: Int
    var size: CGFloat = 160

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: size * 0.085)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(
                    AngularGradient(colors: [grade.color.opacity(0.7), grade.color],
                                    center: .center),
                    style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: grade.color.opacity(0.35), radius: size * 0.04, y: 1)
                .animation(.smooth(duration: 0.8), value: score)
            VStack(spacing: 1) {
                Text(grade.rawValue)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(grade.color)
                    .contentTransition(.numericText())
                Text("\(score) / 100")
                    .font(.system(size: size * 0.105, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Компактный бейдж с буквенной оценкой.
struct GradeBadge: View {
    let grade: Grade
    var body: some View {
        Text(grade.rawValue)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 38, height: 30)
            .background(grade.color, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Карточка категории в боковой сводке.
struct CategoryCard: View {
    let result: CategoryResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: result.category.iconName)
                .font(.system(size: 16))
                .foregroundStyle(result.grade.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.category.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(result.score)/100")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            GradeBadge(grade: result.grade)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(isSelected ? AnyShapeStyle(result.grade.color.opacity(0.14))
                                 : AnyShapeStyle(.quaternary.opacity(0.5)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isSelected ? result.grade.color.opacity(0.55) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// Строка отдельной проверки.
struct CheckRow: View {
    let check: CheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.status.iconName)
                .foregroundStyle(check.status.color)
                .font(.system(size: 16))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(check.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rec = check.recommendation {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(rec)
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.4))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(check.status.color)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
    }
}
