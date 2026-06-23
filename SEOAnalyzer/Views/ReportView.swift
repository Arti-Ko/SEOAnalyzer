import SwiftUI

struct ReportView: View {
    let report: AnalysisReport
    let onExportPDF: () -> Void
    let onExportMarkdown: () -> Void

    @State private var selected: SEOCategory = .seo

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
            detail
                .frame(minWidth: 480)
        }
    }

    // MARK: - Боковая панель: общая оценка и категории

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 18) {
                GradeGauge(grade: report.overallGrade, score: report.overallScore)
                    .padding(.top, 22)

                VStack(spacing: 3) {
                    Text(report.overallGrade.summary)
                        .font(.system(size: 16, weight: .bold))
                    Text(report.finalURL)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal)

                VStack(spacing: 8) {
                    ForEach(report.categories) { result in
                        Button {
                            selected = result.category
                        } label: {
                            CategoryCard(result: result, isSelected: selected == result.category)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)

                exportButtons
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var exportButtons: some View {
        VStack(spacing: 8) {
            Divider().padding(.vertical, 4)
            Text("Экспорт отчёта")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onExportPDF) {
                Label("Сохранить PDF", systemImage: "doc.richtext")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button(action: onExportMarkdown) {
                Label("Сохранить Markdown", systemImage: "doc.plaintext")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Детальная панель

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                keyMetrics

                if let result = report.result(for: selected) {
                    HStack(spacing: 10) {
                        Image(systemName: selected.iconName)
                            .font(.system(size: 20))
                            .foregroundStyle(result.grade.color)
                        Text(selected.rawValue)
                            .font(.system(size: 20, weight: .bold))
                        GradeBadge(grade: result.grade)
                        Spacer()
                        statusSummary(result)
                    }
                    .padding(.top, 4)

                    ForEach(result.checks) { check in
                        CheckRow(check: check)
                    }
                }
            }
            .padding(20)
        }
    }

    private func statusSummary(_ result: CategoryResult) -> some View {
        HStack(spacing: 12) {
            countLabel(result.passedCount, color: .green, icon: "checkmark.circle.fill")
            countLabel(result.warningCount, color: .orange, icon: "exclamationmark.triangle.fill")
            countLabel(result.failedCount, color: .red, icon: "xmark.circle.fill")
        }
    }

    private func countLabel(_ count: Int, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text("\(count)").font(.system(size: 13, weight: .semibold))
        }
    }

    private var keyMetrics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ключевые показатели")
                .font(.system(size: 15, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 10) {
                metricTile("Время ответа", "\(report.responseTimeMs) мс", "speedometer")
                metricTile("Размер HTML", "\(report.pageSizeBytes / 1024) КБ", "doc")
                metricTile("Слов на странице", "\(report.wordCount)", "text.alignleft")
                metricTile("Заголовков H1", "\(report.h1Texts.count)", "textformat.size")
                metricTile("Title", report.pageTitle == nil ? "нет" : "есть", "character.cursor.ibeam")
                metricTile("Описание", report.metaDescription == nil ? "нет" : "есть", "text.quote")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.05)))
    }

    private func metricTile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
