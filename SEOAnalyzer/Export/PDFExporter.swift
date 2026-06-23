import Foundation
import AppKit
import CoreText
import SwiftUI

/// Формирует аккуратный многостраничный PDF-отчёт с оформлением:
/// брендовая шапка, итоговый балл, сводка по категориям и детальные проверки.
enum PDFExporter {

    private static let pageSize = CGSize(width: 595, height: 842) // A4
    private static let margin: CGFloat = 44

    // Палитра
    private static let brand   = NSColor(calibratedRed: 0.227, green: 0.286, blue: 0.710, alpha: 1) // индиго
    private static let brand2  = NSColor(calibratedRed: 0.137, green: 0.486, blue: 0.898, alpha: 1) // голубой
    private static let ink     = NSColor(calibratedWhite: 0.13, alpha: 1)
    private static let subtle  = NSColor(calibratedWhite: 0.45, alpha: 1)
    private static let hairline = NSColor(calibratedWhite: 0.88, alpha: 1)
    private static let panelBG = NSColor(calibratedWhite: 0.965, alpha: 1)

    static func makePDF(from report: AnalysisReport) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        let r = Renderer(ctx: ctx, pageSize: pageSize, margin: margin)
        r.beginPage()

        drawHeader(r, report: report)
        drawSummary(r, report: report)
        drawKeyMetrics(r, report: report)
        for category in report.categories {
            drawCategory(r, result: category)
        }

        r.endPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: - Блоки

    private static func drawHeader(_ r: Renderer, report: AnalysisReport) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"

        let bandH: CGFloat = 104
        let rect = CGRect(x: margin, y: r.top(bandH), width: r.contentW, height: bandH)
        r.fillRoundedGradient(rect, radius: 16, from: brand, to: brand2)

        let pad: CGFloat = 18
        r.drawText(attr("SEO / AEO / GEO — аудит сайта", 12, .semibold, .white.withAlphaComponent(0.85)),
                   x: rect.minX + pad, topY: r.cursorY + 16, width: rect.width - 150)
        r.drawText(attr(report.finalURL, 17, .bold, .white),
                   x: rect.minX + pad, topY: r.cursorY + 36, width: rect.width - 150)
        r.drawText(attr("Дата анализа: \(df.string(from: report.date))", 10.5, .regular, .white.withAlphaComponent(0.85)),
                   x: rect.minX + pad, topY: r.cursorY + 64, width: rect.width - 150)

        // Бейдж итоговой оценки справа
        let badge = CGRect(x: rect.maxX - pad - 92, y: rect.minY + 14, width: 92, height: bandH - 28)
        r.fillRounded(badge, radius: 12, color: .white)
        let g = report.overallGrade
        r.drawTextCentered(attr(g.rawValue, 34, .heavy, nsColor(g.color)), in:
            CGRect(x: badge.minX, y: badge.minY + 30, width: badge.width, height: 40))
        r.drawTextCentered(attr("\(report.overallScore)/100", 11, .semibold, subtle), in:
            CGRect(x: badge.minX, y: badge.minY + 12, width: badge.width, height: 16))

        r.cursorY += bandH + 18
    }

    private static func drawSummary(_ r: Renderer, report: AnalysisReport) {
        r.section("Сводка по категориям")
        let rowH: CGFloat = 26
        for c in report.categories {
            r.ensure(rowH + 4)
            let y = r.cursorY
            // Название
            r.drawText(attr(c.category.rawValue, 11.5, .semibold, ink),
                       x: margin, topY: y + 5, width: 150)
            // Шкала
            let barX = margin + 160, barW = r.contentW - 160 - 120
            let barRect = CGRect(x: barX, y: r.nativeY(y + 17), width: barW, height: 9)
            r.fillRounded(barRect, radius: 4.5, color: hairline)
            let fillW = max(6, barW * CGFloat(c.score) / 100)
            r.fillRounded(CGRect(x: barX, y: barRect.minY, width: fillW, height: 9), radius: 4.5, color: nsColor(c.grade.color))
            // Балл
            r.drawText(attr("\(c.score)/100", 10.5, .regular, subtle),
                       x: barX + barW + 10, topY: y + 5, width: 56)
            // Чип оценки
            r.drawGradeChip(c.grade, x: margin + r.contentW - 38, topY: y + 1)
            r.cursorY += rowH
        }
        r.cursorY += 10
    }

    private static func drawKeyMetrics(_ r: Renderer, report: AnalysisReport) {
        r.section("Ключевые показатели")
        let metrics: [(String, String)] = [
            ("Время ответа", "\(report.responseTimeMs) мс"),
            ("Размер HTML", "\(report.pageSizeBytes / 1024) КБ"),
            ("Слов на странице", "\(report.wordCount)"),
            ("Заголовков H1", "\(report.h1Texts.count)"),
            ("Title", report.pageTitle == nil ? "нет" : "есть"),
            ("Описание", report.metaDescription == nil ? "нет" : "есть")
        ]
        let cols = 3
        let gap: CGFloat = 10
        let tileW = (r.contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let tileH: CGFloat = 46
        var i = 0
        while i < metrics.count {
            r.ensure(tileH + gap)
            let rowY = r.cursorY
            for col in 0..<cols where i < metrics.count {
                let (k, v) = metrics[i]
                let x = margin + CGFloat(col) * (tileW + gap)
                let tile = CGRect(x: x, y: r.nativeY(rowY + tileH), width: tileW, height: tileH)
                r.fillRounded(tile, radius: 9, color: panelBG)
                r.drawText(attr(k, 9.5, .regular, subtle), x: x + 10, topY: rowY + 9, width: tileW - 20)
                r.drawText(attr(v, 15, .bold, ink), x: x + 10, topY: rowY + 23, width: tileW - 20)
                i += 1
            }
            r.cursorY += tileH + gap
        }
        r.cursorY += 6
    }

    private static func drawCategory(_ r: Renderer, result: CategoryResult) {
        // Заголовок категории — цветная плашка
        r.ensure(40)
        let barH: CGFloat = 30
        let bar = CGRect(x: margin, y: r.top(barH), width: r.contentW, height: barH)
        r.fillRounded(bar, radius: 8, color: nsColor(result.grade.color).withAlphaComponent(0.14))
        r.fillRounded(CGRect(x: bar.minX, y: bar.minY, width: 4, height: barH), radius: 2, color: nsColor(result.grade.color))
        r.drawText(attr(result.category.fullName, 13, .bold, ink), x: bar.minX + 14, topY: r.cursorY + 8, width: bar.width - 130)
        r.drawText(attr("Пройдено \(result.passedCount) · Замечаний \(result.warningCount) · Ошибок \(result.failedCount)",
                        8.5, .regular, subtle), x: bar.minX + 14, topY: r.cursorY + 22, width: bar.width - 130)
        r.drawGradeChip(result.grade, x: bar.maxX - 80, topY: r.cursorY + 2)
        r.drawText(attr("\(result.score)/100", 11, .semibold, subtle), x: bar.maxX - 44, topY: r.cursorY + 8, width: 44)
        r.cursorY += barH + 10

        for check in result.checks {
            drawCheck(r, check: check)
        }
        r.cursorY += 8
    }

    private static func drawCheck(_ r: Renderer, check: CheckItem) {
        let dotColor = nsColor(check.status.color)
        let textW = r.contentW - 26

        let titleA = attr("\(check.title)", 11, .semibold, ink)
        let detailA = attr(check.detail, 10, .regular, NSColor(calibratedWhite: 0.3, alpha: 1))

        var blockH = r.height(titleA, width: textW) + r.height(detailA, width: textW) + 8
        var recA: NSAttributedString?
        if let rec = check.recommendation {
            let a = attr("→ \(rec)", 10, .regular, orangeDark)
            recA = a
            blockH += r.height(a, width: textW) + 4
        }
        r.ensure(blockH + 10)

        let startY = r.cursorY
        // Цветная точка статуса
        r.fillCircle(centerX: margin + 5, topY: startY + 4, diameter: 9, color: dotColor)

        var y = startY
        r.drawText(titleA, x: margin + 22, topY: y, width: textW); y += r.height(titleA, width: textW) + 2
        r.drawText(detailA, x: margin + 22, topY: y, width: textW); y += r.height(detailA, width: textW) + 2
        if let recA {
            r.drawText(recA, x: margin + 22, topY: y, width: textW); y += r.height(recA, width: textW) + 2
        }
        r.cursorY = y + 8
        // Тонкий разделитель
        r.hairlineSeparator()
    }

    // MARK: - Атрибутированный текст

    private static func attr(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                             _ color: NSColor, _ align: NSTextAlignment = .left) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 1.5
        p.alignment = align
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: p
        ])
    }

    private static func nsColor(_ c: Color) -> NSColor { NSColor(c) }

    private static let orangeDark = NSColor(calibratedRed: 0.78, green: 0.45, blue: 0.05, alpha: 1)
}

// MARK: - Низкоуровневый рендерер с ручной пагинацией

private final class Renderer {
    let ctx: CGContext
    let pageSize: CGSize
    let margin: CGFloat
    var cursorY: CGFloat = 0       // отсчёт сверху страницы
    private var pageNum = 0

    var contentW: CGFloat { pageSize.width - margin * 2 }
    private var bottomLimit: CGFloat { pageSize.height - margin }

    init(ctx: CGContext, pageSize: CGSize, margin: CGFloat) {
        self.ctx = ctx; self.pageSize = pageSize; self.margin = margin
    }

    /// Переводит y «сверху» в нативную (нижнюю) систему координат PDF.
    func nativeY(_ topY: CGFloat) -> CGFloat { pageSize.height - topY }
    /// Нативный нижний y для прямоугольника высотой h, верх которого на cursorY.
    func top(_ h: CGFloat) -> CGFloat { pageSize.height - cursorY - h }

    func beginPage() {
        ctx.beginPDFPage(nil)
        ctx.textMatrix = .identity
        pageNum += 1
        cursorY = margin
        drawFooter()
    }

    func endPage() { ctx.endPDFPage() }

    private func newPage() { endPage(); beginPage() }

    /// Гарантирует, что на странице есть `h` свободного места, иначе — новая страница.
    func ensure(_ h: CGFloat) {
        if cursorY + h > bottomLimit { newPage() }
    }

    private func drawFooter() {
        let a = NSAttributedString(string: "SEO-Анализатор · стр. \(pageNum)", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)
        ])
        drawTextCentered(a, in: CGRect(x: margin, y: 22, width: contentW, height: 12))
    }

    // MARK: текст

    func height(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(a)
        var fit = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), &fit)
        return ceil(size.height)
    }

    /// Рисует текст с верхним левым углом (x, topY) шириной width.
    func drawText(_ a: NSAttributedString, x: CGFloat, topY: CGFloat, width: CGFloat) {
        let h = height(a, width: width)
        let rect = CGRect(x: x, y: pageSize.height - topY - h, width: width, height: h)
        let fs = CTFramesetterCreateWithAttributedString(a)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                             CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    func drawTextCentered(_ a: NSAttributedString, in rect: CGRect) {
        let m = NSMutableAttributedString(attributedString: a)
        let p = NSMutableParagraphStyle(); p.alignment = .center
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        let fs = CTFramesetterCreateWithAttributedString(m)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0),
                                             CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }

    func section(_ title: String) {
        ensure(26)
        let a = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1)
        ])
        drawText(a, x: margin, topY: cursorY, width: contentW)
        cursorY += 22
    }

    func hairlineSeparator() {
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.91, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        let y = nativeY(cursorY - 4)
        ctx.move(to: CGPoint(x: margin, y: y))
        ctx.addLine(to: CGPoint(x: margin + contentW, y: y))
        ctx.strokePath()
    }

    // MARK: фигуры

    func fillRounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    func fillRoundedGradient(_ rect: CGRect, radius: CGFloat, from: NSColor, to: NSColor) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let colors = [from.cgColor, to.cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
        }
        ctx.restoreGState()
    }

    func fillCircle(centerX: CGFloat, topY: CGFloat, diameter: CGFloat, color: NSColor) {
        let rect = CGRect(x: centerX - diameter / 2, y: nativeY(topY + diameter), width: diameter, height: diameter)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: rect)
    }

    /// Рисует чип с буквенной оценкой (верхний левый угол x, topY).
    func drawGradeChip(_ grade: Grade, x: CGFloat, topY: CGFloat) {
        let w: CGFloat = 34, h: CGFloat = 20
        let rect = CGRect(x: x, y: nativeY(topY + h), width: w, height: h)
        fillRounded(rect, radius: 6, color: NSColor(grade.color))
        let a = NSAttributedString(string: grade.rawValue, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
            .foregroundColor: NSColor.white
        ])
        drawTextCentered(a, in: CGRect(x: x, y: rect.minY + 3, width: w, height: 15))
    }
}

import SwiftUI
