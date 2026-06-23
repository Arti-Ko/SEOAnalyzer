import Foundation

/// Формирует Markdown-отчёт по результатам анализа.
enum MarkdownExporter {

    static func makeMarkdown(from report: AnalysisReport) -> String {
        var md = ""

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"

        md += "# SEO-отчёт\n\n"
        md += "**Адрес сайта:** \(report.finalURL)\n\n"
        md += "**Дата анализа:** \(df.string(from: report.date))\n\n"
        md += "**Итоговая оценка:** \(report.overallGrade.rawValue) — \(report.overallGrade.summary) "
        md += "(\(report.overallScore)/100)\n\n"

        md += "---\n\n"

        // Сводка по категориям
        md += "## Сводка по категориям\n\n"
        md += "| Категория | Оценка | Балл |\n"
        md += "|-----------|:------:|:----:|\n"
        for c in report.categories {
            md += "| \(c.category.rawValue) | \(c.grade.rawValue) | \(c.score)/100 |\n"
        }
        md += "\n"

        // Ключевые показатели
        md += "## Ключевые показатели\n\n"
        md += "- **Заголовок (Title):** \(report.pageTitle ?? "не задан")\n"
        md += "- **Мета-описание:** \(report.metaDescription ?? "не задано")\n"
        md += "- **Заголовков H1:** \(report.h1Texts.count)\n"
        md += "- **Объём контента:** ~\(report.wordCount) слов\n"
        md += "- **Размер HTML:** \(report.pageSizeBytes / 1024) КБ\n"
        md += "- **Время ответа:** \(report.responseTimeMs) мс\n"
        if let server = report.serverHeader {
            md += "- **Сервер:** \(server)\n"
        }
        md += "\n---\n\n"

        // Детализация по категориям
        for c in report.categories {
            md += "## \(c.category.rawValue) — \(c.grade.rawValue) (\(c.score)/100)\n\n"
            md += "Пройдено: \(c.passedCount) · Замечаний: \(c.warningCount) · Ошибок: \(c.failedCount)\n\n"
            for check in c.checks {
                md += "### \(check.status.symbol) \(check.title) — \(check.status.label)\n\n"
                md += "\(check.detail)\n\n"
                if let rec = check.recommendation {
                    md += "> 💡 **Рекомендация:** \(rec)\n\n"
                }
            }
            md += "---\n\n"
        }

        md += "_Отчёт сгенерирован приложением SEO-Анализатор._\n"
        return md
    }
}
