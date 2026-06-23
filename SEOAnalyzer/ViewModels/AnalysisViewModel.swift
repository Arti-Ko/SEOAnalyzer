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

    private let analyzer = Analyzer()

    var canAnalyze: Bool {
        !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAnalyzing
    }

    func runAnalysis() {
        let input = urlInput
        errorMessage = nil
        isAnalyzing = true
        report = nil

        Task {
            do {
                let result = try await analyzer.analyze(urlString: input)
                self.report = result
            } catch {
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            self.isAnalyzing = false
        }
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
