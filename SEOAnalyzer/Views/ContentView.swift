import SwiftUI

struct ContentView: View {
    @StateObject private var vm = AnalysisViewModel()
    @ObservedObject private var updater = UpdateService.shared
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if vm.isAnalyzing {
                loadingView
            } else if let report = vm.report {
                ReportView(report: report,
                           onExportPDF: vm.exportPDF,
                           onExportMarkdown: vm.exportMarkdown)
            } else {
                welcomeView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $updater.showSheet) {
            UpdatePromptView()
        }
        .task {
            // Тихая проверка обновлений при запуске (если включено в настройках).
            if autoCheckUpdates {
                await updater.check(silent: true)
            }
        }
    }

    // MARK: - Шапка с полем ввода

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)

            Text("SEO-Анализатор")
                .font(.system(size: 16, weight: .bold))

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("Введите адрес сайта, например example.com", text: $vm.urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { if vm.canAnalyze { vm.runAnalysis() } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.1)))
            .frame(maxWidth: 420)

            Button(action: vm.runAnalysis) {
                Text("Анализировать")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!vm.canAnalyze)
            .keyboardShortcut(.return, modifiers: [])

            Button {
                Task { await updater.check(silent: false) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
            }
            .help("Проверить обновления")
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Состояния

    private var loadingView: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
            Text("Анализируем сайт…")
                .font(.system(size: 15, weight: .medium))
            Text("Загружаем страницу, заголовки, robots.txt и карту сайта.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tint.opacity(0.8))
            Text("Комплексный SEO-аудит сайта")
                .font(.system(size: 20, weight: .bold))
            Text("Введите адрес сайта вверху и нажмите «Анализировать».\nПриложение проверит SEO, производительность, удобство, соцсети и безопасность,\nа затем позволит выгрузить отчёт в PDF или Markdown.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = vm.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                    .padding(.top, 8)
            }

            categoriesLegend
                .padding(.top, 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var categoriesLegend: some View {
        HStack(spacing: 14) {
            ForEach(SEOCategory.allCases) { cat in
                VStack(spacing: 6) {
                    Image(systemName: cat.iconName)
                        .font(.system(size: 20))
                        .foregroundStyle(.tint)
                    Text(cat.rawValue)
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(width: 92, height: 64)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            }
        }
    }
}
