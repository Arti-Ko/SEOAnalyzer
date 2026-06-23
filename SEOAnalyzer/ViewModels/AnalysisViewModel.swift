import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AnalysisViewModel: ObservableObject {

    @Published var urlInput: String = ""
    @Published var isAnalyzing: Bool = false
    @Published var report: AnalysisReport?
    @Published var errorMessage: String?
    @Published var pagesScanned: Int = 0
    @Published var pagesTotal: Int = 0
    @Published var scanEstimatedSecondsRemaining: Double?

    private let analyzer = Analyzer()
    private var currentTask: Task<Void, Never>?

    var canAnalyze: Bool {
        !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnalyzing
    }

    func runAnalysis() {
        let input = urlInput
        errorMessage = nil
        isAnalyzing = true
        report = nil
        pagesScanned = 0
        pagesTotal = max(1, UserDefaults.standard.object(forKey: "crawlLimit") as? Int ?? 50)
        scanEstimatedSecondsRemaining = nil

        let limit = pagesTotal
        let startDate = Date()
        currentTask = Task {
            do {
                let result = try await analyzer.analyze(urlString: input, crawlLimit: limit) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self else { return }
                        self.pagesScanned = done
                        self.pagesTotal = total
                        // Оценка по средней скорости сканирования с начала обхода.
                        let elapsed = Date().timeIntervalSince(startDate)
                        if done >= 2, total > done {
                            let perPage = elapsed / Double(done)
                            self.scanEstimatedSecondsRemaining = perPage * Double(total - done)
                        } else {
                            self.scanEstimatedSecondsRemaining = nil
                        }
                    }
                }
                self.report = result
            } catch {
                // Отмену пользователем не показываем как ошибку.
                if !Task.isCancelled {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            self.isAnalyzing = false
            self.currentTask = nil
        }
    }

    /// Прерывает текущий анализ. Дочерние сетевые запросы (URLSession, TaskGroup
    /// в SiteCrawler) отменяются автоматически — отмена структурированно
    /// распространяется на все вложенные задачи.
    func cancelAnalysis() {
        currentTask?.cancel()
        currentTask = nil
        isAnalyzing = false
    }

    // MARK: - Экспорт

    func exportMarkdown() {
        guard let report else { return }
        let content = MarkdownExporter.makeMarkdown(from: report)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedFileName(report, ext: "md")
        panel.title = "Сохранить Markdown-отчёт"
        if panel.runModal() == .OK, let url = panel.url {
            try? content.data(using: .utf8)?.write(to: url)
        }
    }

    func exportPDF() {
        guard let report else { return }
        let data = PDFExporter.makePDF(from: report)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedFileName(report, ext: "pdf")
        panel.title = "Сохранить PDF-отчёт"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func suggestedFileName(_ report: AnalysisReport, ext: String) -> String {
        let host = URL(string: report.finalURL)?.host ?? "site"
        let safe = host.replacingOccurrences(of: ".", with: "-")
        return "seo-отчёт-\(safe).\(ext)"
    }
}
