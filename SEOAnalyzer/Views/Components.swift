import SwiftUI

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
                .stroke(Color.gray.opacity(0.15), lineWidth: size * 0.08)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(grade.color,
                        style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: score)
            VStack(spacing: 2) {
                Text(grade.rawValue)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(grade.color)
                Text("\(score)/100")
                    .font(.system(size: size * 0.11, weight: .medium))
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
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
        )
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
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.05)))
    }
}
