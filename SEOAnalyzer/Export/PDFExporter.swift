import Foundation
import AppKit
import CoreText

/// Формирует многостраничный PDF-отчёт на основе результатов анализа.
/// Используется CoreText framesetter для корректной разбивки текста по страницам.
enum PDFExporter {

    private static let pageSize = CGSize(width: 595, height: 842) // A4 в точках
    private static let margin: CGFloat = 48

    static func makePDF(from report: AnalysisReport) -> Data {
        let attributed = makeAttributedString(from: report)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return Data()
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let textRect = CGRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )
        let path = CGPath(rect: textRect, transform: nil)

        var currentRange = CFRange(location: 0, length: 0)
        let totalLength = attributed.length

        // PDF-контекст CGContext и CoreText используют одну систему координат
        // (начало внизу слева), поэтому переворачивать оси не нужно: текст
        // заполняет фрейм сверху вниз и отображается в правильной ориентации.
        repeat {
            context.beginPDFPage(nil)
            context.textMatrix = .identity

            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, context)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()

            // Защита от зацикливания, если очередной фрагмент не помещается.
            if visibleRange.length <= 0 { break }
            currentRange.location += visibleRange.length
        } while currentRange.location < totalLength

        context.closePDF()
        return data as Data
    }

    // MARK: - Построение оформленного текста

    private static func makeAttributedString(from report: AnalysisReport) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"

        // Заголовок документа
        result.append(styled("SEO-отчёт\n", size: 26, weight: .bold, color: .black))
        result.append(styled("\(report.finalURL)\n", size: 12, weight: .regular, color: .systemBlue))
        result.append(styled("Дата анализа: \(df.string(from: report.date))\n\n",
                             size: 11, weight: .regular, color: .darkGray))

        // Итоговая оценка
        result.append(styled("Итоговая оценка: \(report.overallGrade.rawValue) — \(report.overallGrade.summary) (\(report.overallScore)/100)\n\n",
                             size: 16, weight: .semibold, color: gradeColor(report.overallGrade)))

        // Сводка
        result.append(styled("Сводка по категориям\n", size: 18, weight: .bold, color: .black))
        for c in report.categories {
            let line = "•  \(c.category.rawValue): \(c.grade.rawValue) (\(c.score)/100)\n"
            result.append(styled(line, size: 12, weight: .regular, color: .black))
        }
        result.append(styled("\n", size: 8, weight: .regular, color: .black))

        // Ключевые показатели
        result.append(styled("Ключевые показатели\n", size: 18, weight: .bold, color: .black))
        let metrics: [(String, String)] = [
            ("Заголовок (Title)", report.pageTitle ?? "не задан"),
            ("Мета-описание", report.metaDescription ?? "не задано"),
            ("Заголовков H1", "\(report.h1Texts.count)"),
            ("Объём контента", "~\(report.wordCount) слов"),
            ("Размер HTML", "\(report.pageSizeBytes / 1024) КБ"),
            ("Время ответа", "\(report.responseTimeMs) мс")
        ]
        for (k, v) in metrics {
            result.append(styled("\(k): ", size: 12, weight: .semibold, color: .black))
            result.append(styled("\(v)\n", size: 12, weight: .regular, color: .darkGray))
        }
        result.append(styled("\n", size: 8, weight: .regular, color: .black))

        // Детализация
        for c in report.categories {
            result.append(styled("\(c.category.rawValue) — \(c.grade.rawValue) (\(c.score)/100)\n",
                                 size: 17, weight: .bold, color: gradeColor(c.grade)))
            result.append(styled("Пройдено: \(c.passedCount)  ·  Замечаний: \(c.warningCount)  ·  Ошибок: \(c.failedCount)\n\n",
                                 size: 10, weight: .regular, color: .darkGray))

            for check in c.checks {
                let symbol = check.status.symbol
                result.append(styled("\(symbol) \(check.title)\n",
                                     size: 13, weight: .semibold, color: statusColor(check.status)))
                result.append(styled("\(check.detail)\n", size: 11, weight: .regular, color: .black))
                if let rec = check.recommendation {
                    result.append(styled("Рекомендация: \(rec)\n", size: 11, weight: .regular, color: .systemOrange))
                }
                result.append(styled("\n", size: 5, weight: .regular, color: .black))
            }
            result.append(styled("\n", size: 8, weight: .regular, color: .black))
        }

        result.append(styled("Отчёт сгенерирован приложением SEO-Анализатор.\n",
                             size: 9, weight: .regular, color: .gray))
        return result
    }

    private static func styled(_ text: String, size: CGFloat,
                               weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    private static func gradeColor(_ grade: Grade) -> NSColor {
        switch grade {
        case .aPlus, .a: return .systemGreen
        case .b, .c:     return .systemBlue
        case .d, .e:     return .systemOrange
        case .f:         return .systemRed
        }
    }

    private static func statusColor(_ status: CheckStatus) -> NSColor {
        switch status {
        case .passed:  return .systemGreen
        case .warning: return .systemOrange
        case .failed:  return .systemRed
        case .info:    return .systemGray
        }
    }
}
